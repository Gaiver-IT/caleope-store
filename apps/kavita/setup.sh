#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/kavita"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/kavita/config"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/kavita/manga"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/kavita/comics"

KAVITA_ADMIN_USER="${CALEOPE_PARAM_KAVITA_ADMIN_USER:-admin}"
KAVITA_ADMIN_EMAIL="${CALEOPE_PARAM_KAVITA_ADMIN_EMAIL:-admin@${CALEOPE_DOMAIN}}"
KAVITA_ADMIN_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    OLD_PASS=$(grep "^KAVITA_ADMIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    [ -n "${OLD_PASS}" ] && KAVITA_ADMIN_PASSWORD="${OLD_PASS}"
fi
[ -n "${CALEOPE_PARAM_KAVITA_ADMIN_PASSWORD:-}" ] && KAVITA_ADMIN_PASSWORD="${CALEOPE_PARAM_KAVITA_ADMIN_PASSWORD}"
if [ -z "${KAVITA_ADMIN_PASSWORD}" ]; then
    # Kavita requires: uppercase, lowercase, digit, special char, min 6 chars
    BASE=$(openssl rand -base64 10 | tr -dc 'A-Za-z0-9' | head -c 10)
    KAVITA_ADMIN_PASSWORD="${BASE}1!A"
fi

cat > "${_SECRETS}" <<ENV
KAVITA_ADMIN_USER=${KAVITA_ADMIN_USER}
KAVITA_ADMIN_EMAIL=${KAVITA_ADMIN_EMAIL}
KAVITA_ADMIN_PASSWORD=${KAVITA_ADMIN_PASSWORD}
ENV
chmod 600 "${_SECRETS}"

# bootstrap.sh: wait for Kavita then register admin account
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

KAVITA_URL="http://kavita.:5000"
MAX_WAIT=120
WAITED=0

echo "→ Kavita bootstrap : attente de Kavita..."
until curl -sf --max-time 5 "${KAVITA_URL}/" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Kavita non joignable après ${MAX_WAIT}s"
        exit 1
    fi
done
echo "  ✓ Kavita prêt (${WAITED}s)"

# Register admin (first call creates admin, subsequent calls fail if user exists)
RESP=$(curl -sf -X POST "${KAVITA_URL}/api/Account/register" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${KAVITA_ADMIN_USER}\",\"password\":\"${KAVITA_ADMIN_PASSWORD}\",\"email\":\"${KAVITA_ADMIN_EMAIL}\"}" 2>&1 || echo "")

if echo "${RESP}" | grep -q '"token"'; then
    echo "  ✓ Compte admin créé"
elif echo "${RESP}" | grep -q "already\|exist\|409"; then
    echo "  ✓ Compte admin déjà existant"
else
    echo "  ⚠ Réponse : ${RESP}"
fi
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                Kavita — Reader Manga/Comics/PDF                  │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Identifiants admin :                                            │
  │    Login    : ${KAVITA_ADMIN_USER}
  │    Password : ${KAVITA_ADMIN_PASSWORD}
  │    Email    : ${KAVITA_ADMIN_EMAIL}
  │                                                                  │
  │  Bibliothèques :                                                 │
  │    Mangas : /opt/gaiver-it/caleope/app-data/kavita/manga/        │
  │    Comics : /opt/gaiver-it/caleope/app-data/kavita/comics/       │
  │                                                                  │
  │  Formats : CBZ, CBR, PDF, EPUB, MOBI, AZW3                       │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              Kavita — Identifiants admin             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login: ${KAVITA_ADMIN_USER}"
echo "  ║  Pass : ${KAVITA_ADMIN_PASSWORD}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Kavita configuré"
