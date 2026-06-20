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
# Nextcloud supporte OIDC natif (user_oidc). L'API Authentik n'est pas joignable
# via son URL publique depuis le serveur (hairpin NAT absent) → http://localhost:8000.
# Nextcloud accède à Authentik via extra_hosts → IP interne Traefik (caleope-public).
CALEOPE_AUTH_MIDDLEWARE=""
NC_OIDC_CLIENT_ID="" NC_OIDC_CLIENT_SECRET="" NC_OIDC_DISCOVERY_URI=""

if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -z "${AK_DOMAIN}" ]; then
            AK_DOMAIN="authentik.${BASE_DOMAIN}"
        fi

        if [ -n "${AK_TOKEN}" ] && [ -n "${AK_DOMAIN}" ]; then
            AK_PORT=$(grep "^CALEOPE_PORT_WEB=" "${CALEOPE_BASE_DIR}/apps-installed/authentik/app.env" 2>/dev/null | cut -d= -f2-)
            AK_PORT="${AK_PORT:-8000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            echo "  → Configuration OIDC Nextcloud dans Authentik..."

            AUTH_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            PROP_MAPS=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/propertymappings/scope/?managed__icontains=goauthentik.io" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join('\"'+r['pk']+'\"' for r in d.get('results',[])))" 2>/dev/null || echo "")

            # Certificat RS256 pour la signature JWT — Nextcloud user_oidc n'accepte
            # pas HS256 (symétrique). Sans signing_key, Authentik signe en HS256 par défaut.
            SIGN_KEY=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/crypto/certificatekeypairs/?has_key=true" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                NC_OIDC_SECRET=$(openssl rand -hex 16)
                PROV_BODY=$(python3 -c "
import json
d = {
    'name': 'Nextcloud',
    'authorization_flow': '${AUTH_FLOW}',
    'invalidation_flow': '${INVAL_FLOW}',
    'client_type': 'confidential',
    'client_id': 'nextcloud',
    'client_secret': '${NC_OIDC_SECRET}',
    'redirect_uris': [{'matching_mode': 'strict', 'url': 'https://${CALEOPE_DOMAIN}/apps/user_oidc/code'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
}
if '${PROP_MAPS}':
    d['property_mappings'] = [s.strip('\"') for s in '${PROP_MAPS}'.split(',')]
if '${SIGN_KEY}':
    d['signing_key'] = '${SIGN_KEY}'
print(json.dumps(d))
" 2>/dev/null)
                PROV_PK=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" -d "${PROV_BODY}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Nextcloud\",\"slug\":\"nextcloud-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Groupes Authentik par app
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-nextcloud-users\",\"is_superuser\":false}" >/dev/null 2>&1 || true
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-nextcloud-admins\",\"is_superuser\":false}" >/dev/null 2>&1 || true

                    NC_OIDC_CLIENT_ID="nextcloud"
                    NC_OIDC_CLIENT_SECRET="${NC_OIDC_SECRET}"
                    NC_OIDC_DISCOVERY_URI="https://${AK_DOMAIN}/application/o/nextcloud-sso/.well-known/openid-configuration"

                    # Ajouter extra_hosts pour que Nextcloud résolve le domaine Authentik
                    # Nextcloud → Authentik via IP interne Traefik (évite le hairpin NAT)
                    TRAEFIK_IP=$(docker inspect traefik \
                        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | \
                        awk '{print $1}')
                    TRAEFIK_CERT="${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"
                    if [ -n "${TRAEFIK_IP}" ]; then
                        # extra_hosts + entrypoint update-ca-certificates + cert mount
                        # Nextcloud (PHP) vérifie SSL → il faut lui faire confiance au cert Traefik
                        awk -v domain="${AK_DOMAIN}" -v ip="${TRAEFIK_IP}" -v cert="${TRAEFIK_CERT}" '
/^  nextcloud:$/ { in_nc=1 }
/^  [a-z]/ && !/^  nextcloud:$/ { in_nc=0 }
in_nc && /^    env_file:/ && !extra_done {
    print "    entrypoint: [\"/bin/sh\", \"-c\", \"update-ca-certificates 2>/dev/null || true; exec /entrypoint.sh apache2-foreground\"]"
    print "    extra_hosts:"
    print "      - \"" domain ":" ip "\""
    extra_done=1
}
in_nc && /^    volumes:/ && !vol_done {
    print
    print "      - \"" cert ":/usr/local/share/ca-certificates/traefik-auth.crt:ro\""
    vol_done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/nc_compose_sso.yml && \
                        mv /tmp/nc_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true
                    fi

                    cat >> "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << OIDCENV
NC_OIDC_CLIENT_ID=${NC_OIDC_CLIENT_ID}
NC_OIDC_CLIENT_SECRET=${NC_OIDC_CLIENT_SECRET}
NC_OIDC_DISCOVERY_URI=${NC_OIDC_DISCOVERY_URI}
OIDCENV
                    echo "  ✓ Nextcloud OIDC configuré dans Authentik (PK=${PROV_PK})"
                else
                    echo "  ⚠ Erreur création provider OIDC Nextcloud"
                fi
            else
                echo "  ⚠ Flows Authentik introuvables"
            fi
        fi
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

# user_oidc utilise Guzzle (HTTP client interne Nextcloud) avec son propre bundle CA,
# différent de /etc/ssl/certs. Sans cette option, le JWKS fetch échoue silencieusement
# quand Traefik présente un certificat auto-signé → "Invalid JWKS: missing 'keys' array"
occ "config:system:set user_oidc httpclient.allowselfsigned --value=true --type=boolean"

# SSO OIDC — configuré seulement si Authentik a fourni les credentials
if [ -n "${NC_OIDC_CLIENT_ID:-}" ] && [ -n "${NC_OIDC_CLIENT_SECRET:-}" ] && [ -n "${NC_OIDC_DISCOVERY_URI:-}" ]; then
    echo "→ Configuration SSO OIDC (user_oidc)..."
    # Activer l'app avant de configurer le provider
    occ "app:enable user_oidc" 2>/dev/null || occ "app:install user_oidc"
    occ "user_oidc:provider Authentik \
        --clientid=${NC_OIDC_CLIENT_ID} \
        --clientsecret=${NC_OIDC_CLIENT_SECRET} \
        --discoveryuri=${NC_OIDC_DISCOVERY_URI} \
        --mapping-uid=preferred_username"
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
