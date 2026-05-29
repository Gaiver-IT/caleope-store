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

# Domaines dérivés du domaine de base depuis caleope.conf
BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" | cut -d= -f2)
ONLYOFFICE_DOMAIN="onlyoffice.${BASE_DOMAIN}"
# Domaine Authentik — utilisé dans extra_hosts du docker-compose pour contourner le hairpin NAT
AUTHENTIK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
[ -n "${AUTHENTIK_DOMAIN}" ] || AUTHENTIK_DOMAIN="authentik.${BASE_DOMAIN}"

cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << EOF
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_PASSWORD=${DB_PASS}
NEXTCLOUD_ADMIN_USER=user-caleope
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}
JWT_ENABLED=true
JWT_SECRET=${ONLYOFFICE_JWT}
ONLYOFFICE_DOMAIN=${ONLYOFFICE_DOMAIN}
AUTHENTIK_DOMAIN=${AUTHENTIK_DOMAIN}
EOF
chmod 600 "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

# ── SSO OIDC via Authentik ───────────────────────────────────────────────────
# Toutes les appels API passent par Python (requests) via docker exec
# → évite le hairpin NAT (le host ne peut pas appeler son propre domaine public)
# → évite la dépendance à curl dans le container Authentik
authentik_setup_oidc() {
    local DEBUG_LOG="/tmp/caleope_nextcloud_sso.log"
    echo "=== $(date) ===" > "${DEBUG_LOG}"
    echo "ARGS: $*" >> "${DEBUG_LOG}"

    local APP_NAME="$1" APP_SLUG="$2" REDIRECT_URI="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ ! -f "${AK_SECRETS}" ]; then
        echo "ERREUR: AK_SECRETS introuvable" >> "${DEBUG_LOG}"; return 1
    fi

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    if [ -z "${AK_DOMAIN}" ]; then
        local BASE_DOMAIN_AK
        BASE_DOMAIN_AK=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
        AK_DOMAIN="authentik.${BASE_DOMAIN_AK}"
    fi
    echo "TOKEN_SET=$([ -n "${TOKEN}" ] && echo oui || echo non)" >> "${DEBUG_LOG}"
    echo "AK_DOMAIN=${AK_DOMAIN}" >> "${DEBUG_LOG}"
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || { echo "ERREUR: TOKEN ou DOMAIN vide" >> "${DEBUG_LOG}"; return 1; }

    local AK_CONTAINER="authentik-server"

    # Helper GET : docker exec -e TOKEN → python3 requests
    ak_get() {
        local endpoint="$1"
        docker exec -e "AK_TOKEN=${TOKEN}" "${AK_CONTAINER}" python3 -c '
import os, requests, sys
r = requests.get("http://localhost:9000'"${endpoint}"'",
                  headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"]},
                  timeout=10)
sys.stderr.write("GET '"${endpoint}"' -> " + str(r.status_code) + "\n")
if not r.ok:
    sys.stderr.write(r.text[:500] + "\n")
print(r.text if r.ok else "")
' 2>>"${DEBUG_LOG}" || echo ""
    }

    # Helper POST : stdin → python3 requests (évite les problèmes d'échappement JSON)
    ak_post() {
        local endpoint="$1"
        docker exec -i -e "AK_TOKEN=${TOKEN}" "${AK_CONTAINER}" python3 -c '
import os, sys, requests, json
body = json.load(sys.stdin)
r = requests.post("http://localhost:9000'"${endpoint}"'",
                   headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"],
                            "Content-Type": "application/json"},
                   json=body, timeout=10)
sys.stderr.write("POST '"${endpoint}"' -> " + str(r.status_code) + "\n")
if not r.ok:
    sys.stderr.write(r.text[:1000] + "\n")
print(r.text if r.ok else "")
' 2>>"${DEBUG_LOG}" || echo ""
    }

    echo "  → Connexion à l'API Authentik..."
    if ! docker exec -e "AK_TOKEN=${TOKEN}" "${AK_CONTAINER}" python3 -c '
import os, requests
r = requests.get("http://localhost:9000/api/v3/core/applications/",
                  headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"]}, timeout=5)
exit(0 if r.ok else 1)
' 2>>"${DEBUG_LOG}"; then
        echo "ERREUR: API inaccessible (python requests)" >> "${DEBUG_LOG}"; return 1
    fi
    echo "API OK" >> "${DEBUG_LOG}"

    # Flow d'autorisation + flow d'invalidation (requis par Authentik 2024.x)
    local FLOW_UUID INVALIDATION_FLOW_UUID
    FLOW_UUID=$(ak_get "/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null || echo "")
    echo "FLOW_UUID=${FLOW_UUID}" >> "${DEBUG_LOG}"
    [ -n "${FLOW_UUID}" ] || { echo "ERREUR: Flow introuvable" >> "${DEBUG_LOG}"; return 1; }

    INVALIDATION_FLOW_UUID=$(ak_get "/api/v3/flows/instances/?slug=default-provider-invalidation-flow" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null || echo "")
    echo "INVALIDATION_FLOW_UUID=${INVALIDATION_FLOW_UUID}" >> "${DEBUG_LOG}"
    [ -n "${INVALIDATION_FLOW_UUID}" ] || { echo "ERREUR: Invalidation flow introuvable" >> "${DEBUG_LOG}"; return 1; }

    # Clé de signature JWT
    local SIGNING_KEY SIGNING_RAW
    SIGNING_RAW=$(ak_get "/api/v3/crypto/certificatekeypairs/?has_key=true&ordering=name")
    SIGNING_KEY=$(echo "${SIGNING_RAW}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null || echo "")
    echo "SIGNING_KEY=${SIGNING_KEY} RAW=${SIGNING_RAW}" >> "${DEBUG_LOG}"
    [ -n "${SIGNING_KEY}" ] || { echo "ERREUR: Clé de signature introuvable" >> "${DEBUG_LOG}"; return 1; }

    # Scopes OIDC standards — récupère tous les property mappings et filtre en Python
    local ALL_SCOPES S_OPENID S_EMAIL S_PROFILE
    ALL_SCOPES=$(ak_get "/api/v3/propertymappings/all/?ordering=name&page_size=200")
    echo "ALL_SCOPES count=$(echo "${ALL_SCOPES}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pagination',{}).get('count','?'))" 2>/dev/null)" >> "${DEBUG_LOG}"
    S_OPENID=$(echo "${ALL_SCOPES}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if 'scope-openid' in str(p.get('managed',''))]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")
    S_EMAIL=$(echo "${ALL_SCOPES}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if 'scope-email' in str(p.get('managed',''))]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")
    S_PROFILE=$(echo "${ALL_SCOPES}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if 'scope-profile' in str(p.get('managed',''))]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")
    echo "SCOPES: openid=${S_OPENID} email=${S_EMAIL} profile=${S_PROFILE}" >> "${DEBUG_LOG}"
    [ -n "${S_OPENID}" ] || { echo "ERREUR: Scopes OIDC introuvables" >> "${DEBUG_LOG}"; return 1; }

    # Provider OAuth2 — récupérer si existant, sinon créer
    local PROVIDER_RESP PROVIDER_PK
    PROVIDER_PK=$(ak_get "/api/v3/providers/oauth2/" \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if p['name']==\"${APP_NAME} SSO\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -n "${PROVIDER_PK}" ]; then
        PROVIDER_RESP=$(ak_get "/api/v3/providers/oauth2/${PROVIDER_PK}/")
    else
        local BODY
        BODY=$(python3 -c "
import json
scopes=[s for s in ['${S_OPENID}','${S_EMAIL}','${S_PROFILE}'] if s]
print(json.dumps({
    'name': '${APP_NAME} SSO',
    'authorization_flow': '${FLOW_UUID}',
    'invalidation_flow': '${INVALIDATION_FLOW_UUID}',
    'client_type': 'confidential',
    'redirect_uris': [{'url': '${REDIRECT_URI}', 'matching_mode': 'strict'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
    'signing_key': '${SIGNING_KEY}',
    'property_mappings': scopes
}))
")
        echo "POST body: ${BODY}" >> "${DEBUG_LOG}"
        PROVIDER_RESP=$(echo "${BODY}" | ak_post "/api/v3/providers/oauth2/")
        echo "Provider response: ${PROVIDER_RESP}" >> "${DEBUG_LOG}"
        PROVIDER_PK=$(echo "${PROVIDER_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "ERREUR: Erreur création OAuth2 Provider" >> "${DEBUG_LOG}"; echo "  ⚠ Erreur OAuth2 Provider (voir /tmp/caleope_nextcloud_sso.log)"; return 1; }

    OIDC_CLIENT_ID=$(echo "${PROVIDER_RESP}"     | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))"     2>/dev/null || echo "")
    OIDC_CLIENT_SECRET=$(echo "${PROVIDER_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
    echo "CLIENT_ID=${OIDC_CLIENT_ID}" >> "${DEBUG_LOG}"
    [ -n "${OIDC_CLIENT_ID}" ] && [ -n "${OIDC_CLIENT_SECRET}" ] || { echo "ERREUR: Client ID/Secret vides" >> "${DEBUG_LOG}"; return 1; }

    # URL publique : extra_hosts dans docker-compose pointe le domaine Authentik
    # vers host-gateway (bridge Docker → NPM → Traefik → authentik-server),
    # ce qui évite le hairpin NAT tout en gardant le bon hostname pour SSL/TLS.
    OIDC_DISCOVERY_URI="https://${AK_DOMAIN}/application/o/${APP_SLUG}/.well-known/openid-configuration"

    # Créer l'Application dans Authentik
    python3 -c "
import json
print(json.dumps({'name':'${APP_NAME}','slug':'${APP_SLUG}','provider':${PROVIDER_PK}}))
" | ak_post "/api/v3/core/applications/" >/dev/null || true

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
        echo "  ⚠ SSO OIDC désactivé (voir /tmp/caleope_nextcloud_sso.log)"
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

# Autoriser les requêtes vers les IPs internes Docker (protection SSRF désactivée
# pour les serveurs internes — nécessaire pour joindre authentik-server:9000)
occ "config:system:set allow_local_remote_servers --value=true --type=boolean"

# Import du certificat SSL Authentik dans le magasin de confiance Nextcloud.
# Nécessaire quand le reverse proxy utilise un certificat auto-signé : extra_hosts
# redirige le domaine Authentik vers 172.17.0.1:443 (bridge Docker → hôte),
# et si ce port présente un cert auto-signé, GuzzleHTTP refuse la connexion.
if [ -n "${AUTHENTIK_DOMAIN:-}" ]; then
    echo "→ Import du certificat SSL Authentik..."
    echo | openssl s_client -connect "${AUTHENTIK_DOMAIN}:443" \
        -servername "${AUTHENTIK_DOMAIN}" 2>/dev/null \
        | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        > /tmp/authentik-cert.pem
    if [ -s /tmp/authentik-cert.pem ]; then
        su -s /bin/bash www-data -c \
            "php /var/www/html/occ security:certificates:import /tmp/authentik-cert.pem" || true
        echo "✓ Certificat Authentik importé dans Nextcloud"
    else
        echo "  ⚠ Certificat Authentik non extrait (SSL peut être valide ou inaccessible)"
    fi
fi

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
