#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/stirling-pdf"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/stirling-pdf"/{configs,logs}

# Remove stale settings.yml so Stirling PDF recreates it fresh
# SECURITY_ENABLELOGIN=false is set via env var in docker-compose
rm -f "${CALEOPE_BASE_DIR}/app-data/stirling-pdf/configs/settings.yml"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              Stirling PDF — Traitement de documents PDF          │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Accès libre (pas d'authentification par défaut).                │
  │  Protéger avec Authentik si exposé publiquement.                 │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          Stirling PDF — Outil PDF sans auth          ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL : https://${CALEOPE_DOMAIN}/"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Stirling PDF configuré"
