#!/bin/bash
# setup.sh — Ghost CMS
set -euo pipefail
echo "→ Préparation de Ghost..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/ghost"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{content,db}

# ── Params ──────────────────────────────────────────────────────────────────
BLOG_TITLE="${PARAM_BLOG_TITLE:-Mon Blog}"
ADMIN_EMAIL="${PARAM_ADMIN_EMAIL:-}"
ADMIN_NAME="${PARAM_ADMIN_NAME:-Admin}"

if [ -z "${ADMIN_EMAIL}" ]; then
    echo "❌ ADMIN_EMAIL est requis" >&2
    exit 1
fi

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_ROOT_PASS=$(openssl rand -hex 24)
DB_PASS=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

MAIL_BLOCK=""
if [ -n "${SMTP_HOST}" ]; then
    MAIL_BLOCK="mail__transport=SMTP
mail__options__host=${SMTP_HOST}
mail__options__port=${SMTP_PORT}
mail__options__auth__user=${SMTP_USER}
mail__options__auth__pass=${SMTP_PASS}
mail__from=${SMTP_FROM}"
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# MySQL
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_DATABASE=ghost
MYSQL_USER=ghost
MYSQL_PASSWORD=${DB_PASS}

# Ghost config
database__client=mysql
database__connection__host=ghost-db
database__connection__user=ghost
database__connection__password=${DB_PASS}
database__connection__database=ghost
url=https://${CALEOPE_DOMAIN}
${MAIL_BLOCK}

# Bootstrap (admin setup)
GHOST_ADMIN_EMAIL=${ADMIN_EMAIL}
GHOST_ADMIN_PASS=${ADMIN_PASS}
GHOST_ADMIN_NAME=${ADMIN_NAME}
GHOST_BLOG_TITLE=${BLOG_TITLE}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh (run once par ghost-bootstrap container) ───────────────────
# Attend que Ghost soit prêt puis configure via l'API Admin
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

GHOST_URL="http://ghost:2368"
MAX_WAIT=120
WAITED=0

echo "→ Ghost bootstrap : attente de Ghost..."
until wget -qO- "${GHOST_URL}/ghost/api/admin/site/" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Ghost non joignable après ${MAX_WAIT}s"
        exit 1
    fi
done
echo "  ✓ Ghost prêt (${WAITED}s)"

# Vérifier si déjà configuré
STATUS=$(wget -qO- "${GHOST_URL}/ghost/api/admin/authentication/setup/" 2>/dev/null || echo "")
IS_SETUP=$(echo "${STATUS}" | grep -c '"status":"eep"' || true)

if [ "${IS_SETUP}" -gt 0 ]; then
    echo "  ✓ Ghost déjà configuré — bootstrap ignoré"
    exit 0
fi

echo "  → Création du compte admin..."
RESPONSE=$(wget -qO- --header="Content-Type: application/json" \
    --post-data="{\"setup\":[{\"name\":\"${GHOST_ADMIN_NAME}\",\"email\":\"${GHOST_ADMIN_EMAIL}\",\"password\":\"${GHOST_ADMIN_PASS}\",\"blogTitle\":\"${GHOST_BLOG_TITLE}\"}]}" \
    "${GHOST_URL}/ghost/api/admin/authentication/setup/" 2>&1 || echo "")

if echo "${RESPONSE}" | grep -q '"token"'; then
    echo "  ✓ Compte admin créé"
else
    echo "  ⚠ Réponse inattendue du setup Ghost :"
    echo "  ${RESPONSE}"
fi
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# ── Authentik (proxy forward auth) ──────────────────────────────────────────
authentik_register_app() {
    local APP_NAME="$1" APP_SLUG="$2" APP_URL="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 0

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || return 0

    local BASE="https://${AK_DOMAIN}/api/v3"
    local HA="Authorization: Bearer ${TOKEN}"
    local HJ="Content-Type: application/json"

    local i=0
    until curl -sf --max-time 5 -H "${HA}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 12 ] || return 0
        sleep 5
    done

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || return 0

    local PROVIDER_PK
    PROVIDER_PK=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
        "${BASE}/providers/proxy/" \
        -d "{\"name\":\"${APP_NAME}\",\"authorization_flow\":\"${FLOW_UUID}\",\"external_host\":\"${APP_URL}\",\"mode\":\"forward_single\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    [ -n "${PROVIDER_PK}" ] || return 0

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
        NEW_PROVIDERS=$(python3 -c "
import json
l = json.loads('${CURRENT_PROVIDERS}')
if ${PROVIDER_PK} not in l: l.append(${PROVIDER_PK})
print(json.dumps(l))")
        curl -sf --max-time 10 -X PATCH -H "${HA}" -H "${HJ}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            -d "{\"providers\":${NEW_PROVIDERS}}" >/dev/null 2>&1 || true
    fi
    echo "  ✓ Ghost enregistré dans Authentik"
}

if [ -f "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" ]; then
    echo "  → Enregistrement dans Authentik..."
    authentik_register_app "Ghost" "ghost" "https://${CALEOPE_DOMAIN}" || true
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                      Ghost — CMS moderne                         │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⏳  Ghost initialise la base (30-60s au premier boot).          │
  │                                                                  │
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/ghost/                   │
  │    Email    : ${ADMIN_EMAIL}
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  Blog public : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║               Ghost — Identifiants admin             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/ghost/"
echo "  ║  Email: ${ADMIN_EMAIL}"
echo "  ║  Pass : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Ghost configuré"
