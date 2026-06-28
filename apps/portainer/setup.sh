#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/portainer"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/portainer/data"

PORTAINER_ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    PORTAINER_PORT_WEB=$(grep  "^PORTAINER_PORT_WEB="   "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PORTAINER_ADMIN_PASS=$(grep "^PORTAINER_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${PORTAINER_PORT_WEB}"   ] && PORTAINER_PORT_WEB="9000"
[ -z "${PORTAINER_ADMIN_PASS}" ] && PORTAINER_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

cat > "${_SECRETS}" <<ENV
PORTAINER_ADMIN_PASS=${PORTAINER_ADMIN_PASS}
ENV
chmod 600 "${_SECRETS}"

# ── Note : la configuration admin se fait via le wizard au 1er accès ──────────
# setup.sh tourne à l'étape 7 (avant docker compose up étape 9).
# L'initialisation API de Portainer se fait via un container bootstrap post-démarrage.
echo "→ Portainer sera accessible sur le port ${PORTAINER_PORT_WEB}"
echo "  ℹ Configurer le mot de passe admin à la 1ère connexion avec : ${PORTAINER_ADMIN_PASS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Portainer CE est démarré.
Interface : http://<IP>:${PORTAINER_PORT_WEB}
Utilisateur admin : admin
Mot de passe      : ${PORTAINER_ADMIN_PASS}
INFO

echo "✓ Portainer prêt — http://<IP>:${PORTAINER_PORT_WEB}"
