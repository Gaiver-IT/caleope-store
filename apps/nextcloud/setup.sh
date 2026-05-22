#!/bin/bash
set -euo pipefail
echo "→ Préparation de Nextcloud..."

mkdir -p "${CALEOPE_BASE_DIR}/app-data/nextcloud/"{html,db,redis}
mkdir -p "${CALEOPE_BASE_DIR}/app-config/nextcloud"

DB_PASS=$(openssl rand -hex 20)
DB_ROOT_PASS=$(openssl rand -hex 20)
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << EOF
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_PASSWORD=${DB_PASS}
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}
EOF
chmod 600 "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

echo "✓ Dossiers et secrets créés"
echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │  Identifiants Nextcloud générés          │"
echo "  │  User     : admin                        │"
echo "  │  Password : ${ADMIN_PASS}                │"
echo "  │  (aussi dans app-config/nextcloud/)      │"
echo "  └──────────────────────────────────────────┘"
