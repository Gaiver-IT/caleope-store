#!/bin/bash
# setup.sh — Gitea (forge Git auto-hébergée)
set -euo pipefail
echo "→ Préparation de Gitea..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/gitea"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{data,db}

# ── Params ──────────────────────────────────────────────────────────────────
ADMIN_USER="${CALEOPE_PARAM_ADMIN_USER:-git-admin}"
ADMIN_EMAIL="${CALEOPE_PARAM_ADMIN_EMAIL:-}"

if [ -z "${ADMIN_EMAIL}" ]; then
    echo "❌ ADMIN_EMAIL est requis" >&2
    exit 1
fi

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)
SECRET_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
INTERNAL_TOKEN=$(openssl rand -hex 32)

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

MAIL_ENABLED="false"
MAIL_BLOCK=""
if [ -n "${SMTP_HOST}" ]; then
    MAIL_ENABLED="true"
    MAIL_BLOCK="GITEA__mailer__ENABLED=true
GITEA__mailer__PROTOCOL=smtp+starttls
GITEA__mailer__SMTP_ADDR=${SMTP_HOST}
GITEA__mailer__SMTP_PORT=${SMTP_PORT}
GITEA__mailer__USER=${SMTP_USER}
GITEA__mailer__PASSWD=${SMTP_PASS}
GITEA__mailer__FROM=${SMTP_FROM}"
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# PostgreSQL
POSTGRES_DB=gitea
POSTGRES_USER=gitea
POSTGRES_PASSWORD=${DB_PASS}

# Gitea (env-based config via GITEA__ prefix)
GITEA__database__DB_TYPE=postgres
GITEA__database__HOST=gitea-db:5432
GITEA__database__NAME=gitea
GITEA__database__USER=gitea
GITEA__database__PASSWD=${DB_PASS}
GITEA__server__DOMAIN=${CALEOPE_DOMAIN}
GITEA__server__ROOT_URL=https://${CALEOPE_DOMAIN}/
GITEA__server__SSH_DOMAIN=${CALEOPE_DOMAIN}
GITEA__server__SSH_PORT=2222
GITEA__security__SECRET_KEY=${SECRET_KEY}
GITEA__security__INTERNAL_TOKEN=${INTERNAL_TOKEN}
GITEA__oauth2__JWT_SECRET=${JWT_SECRET}
GITEA__security__INSTALL_LOCK=true
GITEA__service__DISABLE_REGISTRATION=false
${MAIL_BLOCK}

# Bootstrap
GITEA_ADMIN_USER=${ADMIN_USER}
GITEA_ADMIN_EMAIL=${ADMIN_EMAIL}
GITEA_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh (crée le compte admin via l'API HTTP) ───────────────────────
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e
MAX_WAIT=180
WAITED=0

echo "→ Gitea bootstrap : attente de l'API HTTP (gitea:3000)..."
until curl -sf --max-time 3 http://gitea:3000/api/v1/version >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    [ "${WAITED}" -lt "${MAX_WAIT}" ] || { echo "⚠️  Gitea non joignable — skip bootstrap"; exit 0; }
done
echo "  ✓ API Gitea prête (${WAITED}s)"

# Vérifier si l'admin existe déjà via l'API
EXISTS=$(curl -sf http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER} 2>/dev/null | grep -c '"login"' || true)
if [ "${EXISTS}" -gt 0 ]; then
    echo "  ✓ Admin '${GITEA_ADMIN_USER}' déjà créé — bootstrap ignoré"
    exit 0
fi

echo "  → Création du compte admin via CLI..."
/usr/local/bin/gitea admin user create \
    --config /data/gitea/conf/app.ini \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASS}" \
    --email "${GITEA_ADMIN_EMAIL}" \
    --admin \
    --must-change-password=false 2>&1 || {
    echo "  ⚠️  CLI gitea échoué — tentative via admin API..."
    curl -sf -X POST http://gitea:3000/api/v1/admin/users \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${GITEA_ADMIN_USER}\",\"password\":\"${GITEA_ADMIN_PASS}\",\"email\":\"${GITEA_ADMIN_EMAIL}\",\"must_change_password\":false,\"source_id\":0}" \
        >/dev/null 2>&1 || true
}

echo "  ✓ Compte admin Gitea créé"
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
    echo "  ✓ Gitea enregistré dans Authentik"
}

if [ -f "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" ]; then
    echo "  → Enregistrement dans Authentik..."
    authentik_register_app "Gitea" "gitea" "https://${CALEOPE_DOMAIN}" || true
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                   Gitea — Forge Git auto-hébergée                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface web : https://${CALEOPE_DOMAIN}/                      │
  │                                                                  │
  │  Compte admin :                                                  │
  │    Login    : ${ADMIN_USER}
  │    Password : ${ADMIN_PASS}
  │    Email    : ${ADMIN_EMAIL}
  │                                                                  │
  │  SSH Git (port 2222) :                                           │
  │    git clone ssh://git@${CALEOPE_DOMAIN}:2222/user/repo.git     │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              Gitea — Identifiants admin              ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login: ${ADMIN_USER}"
echo "  ║  Pass : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Gitea configuré"
