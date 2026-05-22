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
NEXTCLOUD_ADMIN_USER=user-caleope
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}
EOF
chmod 600 "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────┐
  │               Nextcloud — Premiers accès             │
  ├──────────────────────────────────────────────────────┤
  │  ⏳  Nextcloud initialise sa base de données.        │
  │      Patiente 3 à 5 minutes avant d'ouvrir l'URL.   │
  │                                                      │
  │  Identifiants admin générés :                        │
  │    Login    : user-caleope                           │
  │    Password : ${ADMIN_PASS}                  │
  │                                                      │
  │  Ces infos sont aussi dans :                         │
  │  app-config/nextcloud/secrets.env                    │
  └──────────────────────────────────────────────────────┘
EOF

echo "✓ Dossiers et secrets créés"
