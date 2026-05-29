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

# ── Auto-enregistrement dans Authentik ──────────────────────────────────────
# Crée le Proxy Provider + Application + l'ajoute au Outpost via l'API REST
authentik_register_app() {
    local APP_NAME="$1" APP_SLUG="$2" APP_URL="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 1

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
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

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || { echo "  ⚠ Flow Authentik introuvable"; return 1; }

    local PROVIDER_PK
    PROVIDER_PK=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/providers/proxy/" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = [p for p in d.get('results',[]) if p['name']==\"${APP_NAME}\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -z "${PROVIDER_PK}" ]; then
        PROVIDER_PK=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
            "${BASE}/providers/proxy/" \
            -d "{\"name\":\"${APP_NAME}\",\"authorization_flow\":\"${FLOW_UUID}\",\"external_host\":\"${APP_URL}\",\"mode\":\"forward_single\"}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "  ⚠ Erreur création Provider"; return 1; }

    curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
        "${BASE}/core/applications/" \
        -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROVIDER_PK}}" \
        >/dev/null 2>&1 || true

    local OUTPOST_UUID CURRENT_PROVIDERS NEW_PROVIDERS
    OUTPOST_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

    if [ -n "${OUTPOST_UUID}" ]; then
        CURRENT_PROVIDERS=$(curl -sf --max-time 10 -H "${HA}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('providers',[])))" 2>/dev/null || echo "[]")
        NEW_PROVIDERS=$(echo "${CURRENT_PROVIDERS}" | python3 -c "
import sys, json
l = json.load(sys.stdin)
if ${PROVIDER_PK} not in l: l.append(${PROVIDER_PK})
print(json.dumps(l))
" 2>/dev/null || echo "[${PROVIDER_PK}]")
        curl -sf --max-time 10 -X PATCH -H "${HA}" -H "${HJ}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            -d "{\"providers\":${NEW_PROVIDERS}}" >/dev/null 2>&1 || true
    fi

    echo "  → ${APP_NAME} enregistré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    if authentik_register_app "Nextcloud" "nextcloud" "https://${CALEOPE_DOMAIN}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    else
        echo "  ⚠ ForwardAuth désactivé (enregistrement Authentik échoué)"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

# Script de configuration automatique du connecteur OnlyOffice
# Exécuté par le container nextcloud-bootstrap après démarrage de la stack
cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/bash
set -e

echo "→ En attente de Nextcloud..."
until curl -sf "http://nextcloud/status.php" 2>/dev/null | grep -q '"installed":true'; do
    sleep 5
done

echo "→ En attente de OnlyOffice..."
until curl -sf "http://nextcloud-onlyoffice/healthcheck" 2>/dev/null | grep -q "true"; do
    sleep 5
done

echo "→ Installation du connecteur OnlyOffice..."
su -s /bin/bash www-data -c \
    "php /var/www/html/occ app:install onlyoffice 2>/dev/null || php /var/www/html/occ app:enable onlyoffice"

echo "→ Configuration du connecteur..."
su -s /bin/bash www-data -c \
    "php /var/www/html/occ config:app:set onlyoffice DocumentServerUrl         --value='https://${ONLYOFFICE_DOMAIN}/'"
su -s /bin/bash www-data -c \
    "php /var/www/html/occ config:app:set onlyoffice DocumentServerInternalUrl --value='http://nextcloud-onlyoffice/'"
su -s /bin/bash www-data -c \
    "php /var/www/html/occ config:app:set onlyoffice StorageUrl                --value='http://nextcloud/'"
su -s /bin/bash www-data -c \
    "php /var/www/html/occ config:app:set onlyoffice jwt_secret                --value='${JWT_SECRET}'"
su -s /bin/bash www-data -c \
    "php /var/www/html/occ config:app:set onlyoffice jwt_header                --value='Authorization'"

echo "✓ OnlyOffice connecté à Nextcloud"
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
