#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/komga"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/config"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/comics"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/mangas"
chown -R 1000:1000 "${CALEOPE_BASE_DIR}/app-data/komga" 2>/dev/null || true

KOMGA_ADMIN_EMAIL=""
KOMGA_ADMIN_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    KOMGA_ADMIN_EMAIL=$(grep "^KOMGA_ADMIN_EMAIL=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    KOMGA_ADMIN_PASSWORD=$(grep "^KOMGA_ADMIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_KOMGA_ADMIN_EMAIL:-}" ] && KOMGA_ADMIN_EMAIL="${CALEOPE_PARAM_KOMGA_ADMIN_EMAIL}"
[ -n "${CALEOPE_PARAM_KOMGA_ADMIN_PASSWORD:-}" ] && KOMGA_ADMIN_PASSWORD="${CALEOPE_PARAM_KOMGA_ADMIN_PASSWORD}"

[ -z "${KOMGA_ADMIN_EMAIL}" ] && KOMGA_ADMIN_EMAIL="admin@${CALEOPE_DOMAIN:-localhost}"
if [ -z "${KOMGA_ADMIN_PASSWORD}" ]; then
    KOMGA_ADMIN_PASSWORD=$(openssl rand -hex 16)
fi

cat > "${_SECRETS}" <<ENV
KOMGA_ADMIN_EMAIL=${KOMGA_ADMIN_EMAIL}
KOMGA_ADMIN_PASSWORD=${KOMGA_ADMIN_PASSWORD}
ENV
chmod 600 "${_SECRETS}"

# bootstrap.sh: wait for Komga then claim via /api/v1/claim
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

KOMGA_URL="http://komga.:25600"
MAX_WAIT=120
WAITED=0

echo "→ Komga bootstrap : attente de Komga..."
until curl -sf --max-time 5 "${KOMGA_URL}/api/v1/claim" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Komga non joignable après ${MAX_WAIT}s"
        exit 1
    fi
done
echo "  ✓ Komga prêt (${WAITED}s)"

# Check if already claimed
IS_CLAIMED=$(curl -sf "${KOMGA_URL}/api/v1/claim" 2>/dev/null | grep -c '"isClaimed":true' || true)
if [ "${IS_CLAIMED}" -gt 0 ]; then
    echo "  ✓ Komga déjà configuré — bootstrap ignoré"
    exit 0
fi

# Claim via X-Komga-Email / X-Komga-Password headers
RESULT=$(curl -sf -X POST "${KOMGA_URL}/api/v1/claim" \
    -H "X-Komga-Email: ${KOMGA_ADMIN_EMAIL}" \
    -H "X-Komga-Password: ${KOMGA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{}" 2>&1 || echo "")

if echo "${RESULT}" | grep -q '"email"'; then
    echo "  ✓ Compte admin créé"
else
    echo "  ⚠ Réponse inattendue : ${RESULT}"
fi
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                    Komga — Comics & Mangas                       │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Identifiants admin :                                            │
  │    Email    : ${KOMGA_ADMIN_EMAIL}
  │    Password : ${KOMGA_ADMIN_PASSWORD}
  │                                                                  │
  │  Bibliothèques :                                                 │
  │    Comics : /opt/gaiver-it/caleope/app-data/komga/comics/        │
  │    Mangas : /opt/gaiver-it/caleope/app-data/komga/mangas/        │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║               Komga — Identifiants admin             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/"
echo "  ║  Email: ${KOMGA_ADMIN_EMAIL}"
echo "  ║  Pass : ${KOMGA_ADMIN_PASSWORD}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Komga configuré"
