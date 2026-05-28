#!/bin/bash
set -euo pipefail
echo "→ Préparation de Jellyfin..."

mkdir -p "${CALEOPE_BASE_DIR}/app-data/jellyfin/"{config,cache,media}
mkdir -p "${CALEOPE_BASE_DIR}/app-config/jellyfin"

# Authentik ForwardAuth — activé automatiquement si Authentik est installé
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    echo "  → Authentik détecté, ForwardAuth activé"
else
    CALEOPE_AUTH_MIDDLEWARE=""
fi

cat > "${CALEOPE_BASE_DIR}/app-config/jellyfin/app.env" << EOF
CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}
EOF
chmod 600 "${CALEOPE_BASE_DIR}/app-config/jellyfin/app.env"

echo "✓ Jellyfin prêt"
