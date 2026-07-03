#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/n8n"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/n8n/data"
# n8n runs as uid 1000 (node) — ensure write access to data dir
chmod 777 "${CALEOPE_BASE_DIR}/app-data/n8n/data"

cat > "${_SECRETS}" <<ENV
N8N_PROTOCOL=https
N8N_HOST=${CALEOPE_DOMAIN}
WEBHOOK_URL=https://${CALEOPE_DOMAIN}/
N8N_EDITOR_BASE_URL=https://${CALEOPE_DOMAIN}/
GENERIC_TIMEZONE=Europe/Paris
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ n8n configuré"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                   n8n — Automatisation de workflows              │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface   : https://${CALEOPE_DOMAIN}/                        │
  │  Webhook URL : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Créer un compte admin à la première connexion.                  │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ n8n prêt — https://${CALEOPE_DOMAIN}/"
