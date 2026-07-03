#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/grocy"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/grocy/data"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Grocy configuré"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                  Grocy — Gestion du foyer et stocks              │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Identifiants par défaut : admin / admin                         │
  │  Changer le mot de passe immédiatement dans                      │
  │  Administration > Utilisateurs.                                  │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Grocy prêt — https://${CALEOPE_DOMAIN}/"
