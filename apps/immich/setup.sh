#!/bin/bash
# setup.sh — Immich (galerie photos auto-hébergée)
set -euo pipefail
echo "→ Préparation d'Immich..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/immich"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{library,db,model-cache}

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -hex 24)
ADMIN_EMAIL="admin@${CALEOPE_DOMAIN}"
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)
ADMIN_NAME="Admin"

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# PostgreSQL
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_USER=immich
POSTGRES_DB=immich

# Immich
DB_HOSTNAME=immich-db
DB_USERNAME=immich
DB_PASSWORD=${DB_PASS}
DB_DATABASE_NAME=immich
REDIS_HOSTNAME=immich-redis

# URL publique (pour les liens de partage)
IMMICH_SERVER_URL=https://${CALEOPE_DOMAIN}

# SMTP (configuré via l'interface admin Immich)
_SMTP_HOST=${SMTP_HOST}
_SMTP_PORT=${SMTP_PORT}
_SMTP_USER=${SMTP_USER}
_SMTP_PASS=${SMTP_PASS}
_SMTP_FROM=${SMTP_FROM}

# Admin auto-créé au premier démarrage
IMMICH_ADMIN_EMAIL=${ADMIN_EMAIL}
IMMICH_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── Auto-création du compte admin ────────────────────────────────────────────
# Attendre qu'Immich soit prêt, puis créer l'admin via l'API sign-up.
# L'endpoint /api/auth/admin-sign-up n'existe que si aucun admin n'existe encore.
# On détecte le port Traefik ou le port direct de l'app.
IMMICH_PORT=$(grep "CALEOPE_PORT_IMMICH" "${CALEOPE_BASE_DIR}/app-ports.conf" 2>/dev/null | cut -d= -f2- || echo "")
if [ -z "${IMMICH_PORT}" ]; then
    IMMICH_PORT=$(grep -r "immich" "${CALEOPE_APP_DIR}/compose.yml" 2>/dev/null | grep -o '[0-9]*:2283' | cut -d: -f1 | head -1 || echo "2283")
fi
IMMICH_URL="http://localhost:${IMMICH_PORT}"

echo "  → Attente du démarrage d'Immich (max 120s)..."
WAITED=0
until curl -sf --max-time 5 "${IMMICH_URL}/api/server/about" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    [ "${WAITED}" -lt 120 ] || break
done

echo "  → Création du compte admin Immich..."
SIGNUP_RESP=$(curl -s --max-time 10 -X POST "${IMMICH_URL}/api/auth/admin-sign-up" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\",\"name\":\"${ADMIN_NAME}\"}" 2>/dev/null || echo "")

if echo "${SIGNUP_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('email') else 1)" 2>/dev/null; then
    echo "  ✓ Admin Immich créé : ${ADMIN_EMAIL}"
elif echo "${SIGNUP_RESP}" | grep -q "already"; then
    echo "  ⚠ Admin déjà existant (installation précédente)"
else
    echo "  ⚠ Création admin : ${SIGNUP_RESP}"
fi

# ── SSO OAuth2 via Authentik ─────────────────────────────────────────────────
# Immich supporte OAuth2 natif. On crée un provider OIDC dans Authentik et on
# configure Immich via son API. Immich (Node.js) doit joindre Authentik → on
# injecte NODE_EXTRA_CA_CERTS + extra_hosts dans le compose pour contourner
# le hairpin NAT et le cert auto-signé Traefik.
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2- || echo "authentik.${BASE_DOMAIN}")
        [ -n "${AK_DOMAIN}" ] || AK_DOMAIN="authentik.${BASE_DOMAIN}"

        if [ -n "${AK_TOKEN}" ]; then
            AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null)
            AK_PORT="${AK_PORT:-9000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            echo "  → Configuration OAuth2 Immich dans Authentik..."

            AUTH_FLOW=$(curl -sf --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -sf --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                IMMICH_OIDC_SECRET=$(openssl rand -hex 16)
                PROV_BODY=$(python3 -c "
import json
print(json.dumps({
    'name': 'Immich',
    'authorization_flow': '${AUTH_FLOW}',
    'invalidation_flow': '${INVAL_FLOW}',
    'client_type': 'confidential',
    'client_id': 'immich',
    'client_secret': '${IMMICH_OIDC_SECRET}',
    'redirect_uris': [{'matching_mode': 'strict', 'url': 'https://${CALEOPE_DOMAIN}/auth/login'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
}))
" 2>/dev/null)
                PROV_PK=$(curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" -d "${PROV_BODY}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Immich\",\"slug\":\"immich-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Groupes Authentik par app
                    USERS_GRP=$(curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-immich-users\",\"is_superuser\":false}" \
                        | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                    ADMINS_GRP=$(curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-immich-admins\",\"is_superuser\":false}" \
                        | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                    # extra_hosts + NODE_EXTRA_CA_CERTS pour joindre Authentik depuis Immich
                    TRAEFIK_IP=$(docker inspect traefik \
                        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
                    TRAEFIK_CERT="${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"

                    if [ -n "${TRAEFIK_IP}" ] && [ -f "${TRAEFIK_CERT}" ]; then
                        awk -v domain="${AK_DOMAIN}" -v ip="${TRAEFIK_IP}" -v cert="${TRAEFIK_CERT}" '
/^  immich-server:$/ { in_svc=1 }
/^  [a-z]/ && !/^  immich-server:$/ { in_svc=0 }
in_svc && /^    env_file:/ && !extra_done {
    print "    environment:"
    print "      - NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/traefik-auth.crt"
    print "    extra_hosts:"
    print "      - \"" domain ":" ip "\""
    extra_done=1
}
in_svc && /^    volumes:/ && !vol_done {
    print
    print "      - \"" cert ":/usr/local/share/ca-certificates/traefik-auth.crt:ro\""
    vol_done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/immich_compose_sso.yml && \
                        mv /tmp/immich_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true
                    fi

                    # Configurer OAuth2 dans Immich via l'API
                    WAITED_SSO=0
                    until curl -sf --max-time 5 "${IMMICH_URL}/api/server/about" >/dev/null 2>&1; do
                        sleep 5; WAITED_SSO=$((WAITED_SSO + 5))
                        [ "${WAITED_SSO}" -lt 60 ] || break
                    done

                    IMMICH_TOKEN=$(curl -sf --max-time 10 -X POST "${IMMICH_URL}/api/auth/login" \
                        -H "Content-Type: application/json" \
                        -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" \
                        | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null || echo "")

                    if [ -n "${IMMICH_TOKEN}" ]; then
                        CURR_CFG=$(curl -sf "${IMMICH_URL}/api/system-config" -H "Authorization: Bearer ${IMMICH_TOKEN}" 2>/dev/null || echo "{}")
                        python3 - << PYEOF
import json
try:
    d = json.loads('''${CURR_CFG}''')
except:
    d = {}
d["oauth"] = {
    "enabled": True,
    "issuerUrl": "https://${AK_DOMAIN}/application/o/immich-sso/",
    "clientId": "immich",
    "clientSecret": "${IMMICH_OIDC_SECRET}",
    "scope": "openid email profile",
    "signingAlgorithm": "RS256",
    "profileSigningAlgorithm": "none",
    "tokenEndpointAuthMethod": "client_secret_post",
    "storageLabelClaim": "preferred_username",
    "storageQuotaClaim": "immich_quota",
    "roleClaim": "immich_role",
    "defaultStorageQuota": None,
    "timeout": 30000,
    "buttonText": "Se connecter avec Authentik",
    "autoRegister": True,
    "autoLaunch": False,
    "mobileOverrideEnabled": False,
    "mobileRedirectUri": ""
}
import subprocess
r = subprocess.run(
    ["curl","-sf","-X","PUT","${IMMICH_URL}/api/system-config",
     "-H","Content-Type: application/json",
     "-H","Authorization: Bearer ${IMMICH_TOKEN}",
     "-d",json.dumps(d)],
    capture_output=True, text=True)
out = r.stdout
try:
    res = json.loads(out)
    enabled = res.get("oauth", {}).get("enabled", False)
    print("  ✓ Immich OAuth2 configuré (enabled=" + str(enabled) + ")")
except:
    print("  ⚠ Config OAuth2 : " + out[:100])
PYEOF
                    else
                        echo "  ⚠ Login Immich échoué — OAuth2 à configurer manuellement"
                    fi

                    cat >> "${CONFIG_DIR}/secrets.env" << OIDCENV
IMMICH_OIDC_CLIENT_ID=immich
IMMICH_OIDC_CLIENT_SECRET=${IMMICH_OIDC_SECRET}
OIDCENV
                    echo "  ✓ Immich OAuth2 configuré dans Authentik (PK=${PROV_PK})"
                    [ -n "${USERS_GRP}" ] && echo "  ✓ Groupes créés: caleope-immich-users / caleope-immich-admins"
                fi
            fi
        fi
    fi
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │              Immich — Galerie photos auto-hébergée               │
  ├──────────────────────────────────────────────────────────────────┤
  │  Application : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Compte admin :                                                  │
  │    Email    : ${ADMIN_EMAIL}
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  Application mobile : "Immich" sur App Store / Play Store        │
  │    → Entrer https://${CALEOPE_DOMAIN}/ comme URL serveur         │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Immich — Identifiants admin                ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL      : https://${CALEOPE_DOMAIN}/"
echo "  ║  Email    : ${ADMIN_EMAIL}"
echo "  ║  Password : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Immich configuré"
