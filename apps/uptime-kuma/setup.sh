#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/uptime-kuma"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/uptime-kuma/data"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Uptime Kuma configuré"

# ── API key auto-génération ───────────────────────────────────────────────────
# Uptime Kuma gère ses comptes uniquement via son interface web au premier démarrage.
# Pas d'API d'initialisation publique — setup manuel requis.

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Uptime Kuma — Surveillance de services             │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Première connexion : créer un compte admin directement          │
  │  dans l'interface.                                               │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Uptime Kuma prêt — https://${CALEOPE_DOMAIN}/"
