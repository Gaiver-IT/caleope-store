#!/bin/bash
set -euo pipefail
echo "→ Préparation de Nextcloud + OnlyOffice..."

mkdir -p "${CALEOPE_BASE_DIR}/app-data/nextcloud/"{html,db,redis}
mkdir -p "${CALEOPE_BASE_DIR}/app-data/nextcloud/onlyoffice/"{logs,data}
mkdir -p "${CALEOPE_BASE_DIR}/app-config/nextcloud"

# Génération des secrets
DB_PASS=$(openssl rand -hex 20)
DB_ROOT_PASS=$(openssl rand -hex 20)
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
ONLYOFFICE_JWT=$(openssl rand -hex 20)

# Domaine OnlyOffice dérivé du domaine de base depuis caleope.conf
BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" | cut -d= -f2)
ONLYOFFICE_DOMAIN="onlyoffice.${BASE_DOMAIN}"

cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << EOF
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_PASSWORD=${DB_PASS}
NEXTCLOUD_ADMIN_USER=user-caleope
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}
JWT_ENABLED=true
JWT_SECRET=${ONLYOFFICE_JWT}
ONLYOFFICE_DOMAIN=${ONLYOFFICE_DOMAIN}
EOF
chmod 600 "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

# ── SSO OIDC via Authentik ───────────────────────────────────────────────────
# Crée un OAuth2/OIDC Provider dans Authentik pour le SSO natif de Nextcloud.
# Expose les vars globales : OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_DISCOVERY_URI
authentik_setup_oidc() {
    local APP_NAME="$1" APP_SLUG="$2" REDIRECT_URI="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 1

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    if [ -z "${AK_DOMAIN}" ]; then
        local BASE_DOMAIN
        BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
        AK_DOMAIN="authentik.${BASE_DOMAIN}"
    fi
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || return 1

    local BASE="https://${AK_DOMAIN}/api/v3"
    local HA="Authorization: Bearer ${TOKEN}"
    local HJ="Content-Type: application/json"

    echo "  → Connexion à l'API Authentik (max 60s)..."
    local i=0
    until curl -sf --max-time 5 -H "${HA}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 12 ] || { echo "  ⚠ Authentik non joignable"; return 1; }
        sleep 5
    done

    # Flow d'autorisation
    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || { echo "  ⚠ Flow Authentik introuvable"; return 1; }

    # Clé de signature JWT
    local SIGNING_KEY
    SIGNING_KEY=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/crypto/certificatekeypairs/?has_key=true&ordering=name" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${SIGNING_KEY}" ] || { echo "  ⚠ Clé de signature introuvable"; return 1; }

    # Scopes OIDC standards (openid, email, profile)
    local S_OPENID S_EMAIL S_PROFILE
    S_OPENID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/propertymappings/scope/?managed=goauthentik.io%2Fproviders%2Foauth2%2Fscope-openid" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    S_EMAIL=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/propertymappings/scope/?managed=goauthentik.io%2Fproviders%2Foauth2%2Fscope-email" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    S_PROFILE=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/propertymappings/scope/?managed=goauthentik.io%2Fproviders%2Foauth2%2Fscope-profile" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${S_OPENID}" ] || { echo "  ⚠ Scopes OIDC introuvables"; return 1; }

    # Créer ou récupérer le Provider OAuth2
    local PROVIDER_RESP PROVIDER_PK
    PROVIDER_PK=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/providers/oauth2/" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = [p for p in d.get('results',[]) if p['name']==\"${APP_NAME} SSO\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -n "${PROVIDER_PK}" ]; then
        PROVIDER_RESP=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/providers/oauth2/${PROVIDER_PK}/")
    else
        PROVIDER_RESP=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
            "${BASE}/providers/oauth2/" \
            -d "{
                \"name\": \"${APP_NAME} SSO\",
                \"authorization_flow\": \"${FLOW_UUID}\",
                \"client_type\": \"confidential\",
                \"redirect_uris\": \"${REDIRECT_URI}\",
                \"sub_mode\": \"hashed_user_id\",
                \"include_claims_in_id_token\": true,
                \"signing_key\": \"${SIGNING_KEY}\",
                \"property_mappings\": [\"${S_OPENID}\", \"${S_EMAIL}\", \"${S_PROFILE}\"]
            }" 2>/dev/null || echo "")
        PROVIDER_PK=$(echo "${PROVIDER_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "  ⚠ Erreur création OAuth2 Provider"; return 1; }

    OIDC_CLIENT_ID=$(echo "${PROVIDER_RESP}"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))"     2>/dev/null || echo "")
    OIDC_CLIENT_SECRET=$(echo "${PROVIDER_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
    [ -n "${OIDC_CLIENT_ID}" ] && [ -n "${OIDC_CLIENT_SECRET}" ] || { echo "  ⚠ Client ID/Secret introuvables"; return 1; }

    OIDC_DISCOVERY_URI="https://${AK_DOMAIN}/application/o/${APP_SLUG}/.well-known/openid-configuration"

    # Créer l'Application dans Authentik
    curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
        "${BASE}/core/applications/" \
        -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROVIDER_PK}}" \
        >/dev/null 2>&1 || true

    echo "  → SSO OIDC configuré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
OIDC_CLIENT_ID="" OIDC_CLIENT_SECRET="" OIDC_DISCOVERY_URI=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    REDIRECT_URI="https://${CALEOPE_DOMAIN}/apps/user_oidc/code"
    if authentik_setup_oidc "Nextcloud" "nextcloud-sso" "${REDIRECT_URI}"; then
        cat >> "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << OIDCENV
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
OIDC_DISCOVERY_URI=${OIDC_DISCOVERY_URI}
OIDCENV
    else
        echo "  ⚠ SSO OIDC désactivé (configuration Authentik échouée)"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

# Script de configuration automatique du connecteur OnlyOffice
# Exécuté par le container nextcloud-bootstrap après démarrage de la stack
cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/bash
set -e

occ() { su -s /bin/bash www-data -c "php /var/www/html/occ $*"; }

echo "→ En attente de Nextcloud..."
until curl -sf "http://nextcloud/status.php" 2>/dev/null | grep -q '"installed":true'; do
    sleep 5
done

echo "→ En attente de OnlyOffice..."
until curl -sf "http://nextcloud-onlyoffice/healthcheck" 2>/dev/null | grep -q "true"; do
    sleep 5
done

echo "→ Installation du connecteur OnlyOffice..."
occ "app:install onlyoffice 2>/dev/null || php /var/www/html/occ app:enable onlyoffice"

echo "→ Configuration du connecteur OnlyOffice..."
occ "config:app:set onlyoffice DocumentServerUrl         --value='https://${ONLYOFFICE_DOMAIN}/'"
occ "config:app:set onlyoffice DocumentServerInternalUrl --value='http://nextcloud-onlyoffice/'"
occ "config:app:set onlyoffice StorageUrl                --value='http://nextcloud/'"
occ "config:app:set onlyoffice jwt_secret                --value='${JWT_SECRET}'"
occ "config:app:set onlyoffice jwt_header                --value='Authorization'"
echo "✓ OnlyOffice connecté à Nextcloud"

# SSO OIDC — configuré seulement si Authentik a fourni les credentials
if [ -n "${OIDC_CLIENT_ID:-}" ] && [ -n "${OIDC_CLIENT_SECRET:-}" ] && [ -n "${OIDC_DISCOVERY_URI:-}" ]; then
    echo "→ Configuration SSO OIDC (user_oidc)..."
    occ "app:install user_oidc 2>/dev/null || php /var/www/html/occ app:enable user_oidc"
    occ "user_oidc:provider 'Authentik' \
        --clientid='${OIDC_CLIENT_ID}' \
        --clientsecret='${OIDC_CLIENT_SECRET}' \
        --discoveryuri='${OIDC_DISCOVERY_URI}' \
        --unique-uid=0"
    echo "✓ SSO Authentik configuré dans Nextcloud"
fi
BOOTSTRAP
chmod +x "${CALEOPE_BASE_DIR}/app-config/nextcloud/bootstrap.sh"

cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────┐
  │          Nextcloud + OnlyOffice — Premiers accès             │
  ├──────────────────────────────────────────────────────────────┤
  │  ⏳  Nextcloud initialise sa base de données (3-5 min).      │
  │  ⏳  OnlyOffice démarre ensuite (2-3 min supplémentaires).   │
  │  ⏳  Le connecteur se configure automatiquement.             │
  │                                                              │
  │  Identifiants Nextcloud :                                    │
  │    Login    : user-caleope                                   │
  │    Password : ${ADMIN_PASS}                          │
  │                                                              │
  │  OnlyOffice accessible sur :                                 │
  │    https://${ONLYOFFICE_DOMAIN}                              │
  │  (ajoute ce domaine dans NPM comme les autres)               │
  │                                                              │
  │  Secrets dans : app-config/nextcloud/secrets.env             │
  └──────────────────────────────────────────────────────────────┘
EOF

echo "✓ Dossiers, secrets et bootstrap créés"
