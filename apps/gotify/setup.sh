#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/gotify"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/gotify/data"

GOTIFY_DEFAULTUSER_PASS=""

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Gotify est démarré.
Interface : https://${CALEOPE_DOMAIN}/

Identifiants par défaut : admin / ${GOTIFY_DEFAULTUSER_PASS}
Changer le mot de passe dans Settings après connexion.
INFO

echo "  URL : https://${CALEOPE_DOMAIN}/"
echo "✓ Gotify prêt"
