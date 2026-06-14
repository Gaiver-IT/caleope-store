#!/bin/bash
# setup.sh — WordPress
set -euo pipefail
echo "→ Préparation de WordPress..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/wordpress"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{wp-content,db}

# ── Params ──────────────────────────────────────────────────────────────────
BLOG_TITLE="${PARAM_BLOG_TITLE:-Mon Site}"
ADMIN_EMAIL="${PARAM_ADMIN_EMAIL:-}"
ADMIN_USER="${PARAM_ADMIN_USER:-admin}"

if [ -z "${ADMIN_EMAIL}" ]; then
    echo "❌ ADMIN_EMAIL est requis" >&2
    exit 1
fi

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_ROOT_PASS=$(openssl rand -hex 24)
DB_PASS=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)
AUTH_KEY=$(openssl rand -hex 32)
SECURE_AUTH_KEY=$(openssl rand -hex 32)
LOGGED_IN_KEY=$(openssl rand -hex 32)
NONCE_KEY=$(openssl rand -hex 32)

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# MariaDB
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=${DB_PASS}

# WordPress
WORDPRESS_DB_HOST=wordpress-db
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=${DB_PASS}
WORDPRESS_DB_NAME=wordpress
WORDPRESS_TABLE_PREFIX=wp_
WORDPRESS_AUTH_KEY=${AUTH_KEY}
WORDPRESS_SECURE_AUTH_KEY=${SECURE_AUTH_KEY}
WORDPRESS_LOGGED_IN_KEY=${LOGGED_IN_KEY}
WORDPRESS_NONCE_KEY=${NONCE_KEY}

# Bootstrap WP-CLI
WP_SITE_URL=https://${CALEOPE_DOMAIN}
WP_SITE_TITLE=${BLOG_TITLE}
WP_ADMIN_USER=${ADMIN_USER}
WP_ADMIN_EMAIL=${ADMIN_EMAIL}
WP_ADMIN_PASS=${ADMIN_PASS}

# SMTP (pour le plugin WP Mail SMTP si installé)
CALEOPE_SMTP_HOST=${SMTP_HOST}
CALEOPE_SMTP_PORT=${SMTP_PORT}
CALEOPE_SMTP_USER=${SMTP_USER}
CALEOPE_SMTP_PASS=${SMTP_PASS}
CALEOPE_SMTP_FROM=${SMTP_FROM}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh (WP-CLI) ────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/bash
set -e

WP="/usr/local/bin/wp --allow-root --path=/var/www/html"
MAX_WAIT=120
WAITED=0

echo "→ WordPress bootstrap : attente de la base de données..."
until $WP db check >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Base de données non joignable après ${MAX_WAIT}s"
        exit 1
    fi
done
echo "  ✓ DB prête (${WAITED}s)"

# Déjà installé ?
if $WP core is-installed 2>/dev/null; then
    echo "  ✓ WordPress déjà installé — bootstrap ignoré"
    exit 0
fi

echo "  → Installation WordPress..."
$WP core install \
    --url="${WP_SITE_URL}" \
    --title="${WP_SITE_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASS}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email

$WP language core install fr_FR --activate 2>/dev/null || true
$WP option update blogdescription "" 2>/dev/null || true

echo "  ✓ WordPress installé"
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
    echo "  ✓ WordPress enregistré dans Authentik"
}

if [ -f "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" ]; then
    echo "  → Enregistrement dans Authentik..."
    authentik_register_app "WordPress" "wordpress" "https://${CALEOPE_DOMAIN}" || true
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                     WordPress — CMS classique                    │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/wp-admin/               │
  │    Login    : ${ADMIN_USER}
  │    Password : ${ADMIN_PASS}
  │    Email    : ${ADMIN_EMAIL}
  │                                                                  │
  │  Site public : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║            WordPress — Identifiants admin            ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/wp-admin/"
echo "  ║  Login: ${ADMIN_USER}"
echo "  ║  Pass : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ WordPress configuré"
