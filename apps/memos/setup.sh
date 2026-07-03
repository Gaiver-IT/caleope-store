#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/memos"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/memos/data"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Memos configuré"

# ── Compte admin Memos + token API ───────────────────────────────────────────
MEMOS_ADMIN_USER=""
MEMOS_ADMIN_PASS=""
MEMOS_API_TOKEN=""
if [ -f "${_SECRETS}" ]; then
    MEMOS_ADMIN_USER=$(grep "^MEMOS_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MEMOS_ADMIN_PASS=$(grep "^MEMOS_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MEMOS_API_TOKEN=$(grep "^MEMOS_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${MEMOS_ADMIN_USER}" ] && MEMOS_ADMIN_USER="admin"
[ -z "${MEMOS_ADMIN_PASS}" ] && MEMOS_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"

# setup.sh tourne à l'étape 7 (avant docker compose up étape 9).
# La création du compte admin se fait via le bootstrap container après démarrage.
echo "  → Compte admin Memos sera créé au démarrage du container"

# ── bootstrap.sh (crée le compte admin après démarrage) ──────────────────────
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

MEMOS_URL="http://memos.:5230"
MAX_WAIT=120
WAITED=0

echo "→ Memos bootstrap : attente de l'API..."
until curl -sf --max-time 3 "${MEMOS_URL}/api/v1/auth/status" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    [ "${WAITED}" -lt "${MAX_WAIT}" ] || { echo "⚠ Memos non joignable — skip bootstrap"; exit 0; }
done
echo "  ✓ API Memos prête (${WAITED}s)"

# Créer le premier utilisateur HOST (sera admin)
RESP=$(curl -s --max-time 10 -X POST "${MEMOS_URL}/api/v1/users" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${MEMOS_ADMIN_USER}\",\"password\":\"${MEMOS_ADMIN_PASS}\",\"role\":\"HOST\"}" 2>/dev/null || echo "")

if echo "${RESP}" | grep -q '"id"'; then
    echo "  ✓ Compte admin Memos créé : ${MEMOS_ADMIN_USER}"
elif echo "${RESP}" | grep -qi "already\|exists\|found"; then
    echo "  ✓ Admin déjà existant"
else
    echo "  ⚠ Création admin : ${RESP}"
fi

echo "✓ Memos bootstrap terminé"
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# Stocker les credentials
{
    grep -v "^MEMOS_ADMIN_USER=\|^MEMOS_ADMIN_PASS=\|^MEMOS_API_TOKEN=" "${_SECRETS}" 2>/dev/null || true
    echo "MEMOS_ADMIN_USER=${MEMOS_ADMIN_USER}"
    echo "MEMOS_ADMIN_PASS=${MEMOS_ADMIN_PASS}"
    [ -n "${MEMOS_API_TOKEN}" ] && echo "MEMOS_API_TOKEN=${MEMOS_API_TOKEN}"
} > "${_SECRETS}.tmp" && mv "${_SECRETS}.tmp" "${_SECRETS}"
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                  Memos — Notes et mémos rapides                  │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface   : https://${CALEOPE_DOMAIN}/                        │
  │  Utilisateur : ${MEMOS_ADMIN_USER}                               │
  │  Mot de passe: ${MEMOS_ADMIN_PASS}                               │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Memos prêt — https://${CALEOPE_DOMAIN}/"
