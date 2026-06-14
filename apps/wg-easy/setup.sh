#!/bin/bash
# setup.sh — WG-Easy (WireGuard VPN + interface web)
set -euo pipefail
echo "→ Préparation de WG-Easy..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/wg-easy"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/data"

# ── Params ──────────────────────────────────────────────────────────────────
WG_HOST="${CALEOPE_PARAM_WG_HOST:-}"
WG_DEFAULT_DNS="${CALEOPE_PARAM_WG_DEFAULT_DNS:-1.1.1.1}"

if [ -z "${WG_HOST}" ]; then
    echo "❌ WG_HOST (IP ou domaine public) est requis" >&2
    exit 1
fi

# ── Mot de passe admin (hashé bcrypt via wg-easy interne) ────────────────────
# wg-easy gère son propre hash bcrypt au premier démarrage si PASSWORD_HASH fourni
# On génère juste le mot de passe brut — il sera hashé par wg-easy lui-même
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)

cat > "${CONFIG_DIR}/secrets.env" << EOF
# WG-Easy
WG_HOST=${WG_HOST}
PASSWORD=${ADMIN_PASS}
WG_DEFAULT_DNS=${WG_DEFAULT_DNS}
WG_DEFAULT_ADDRESS=10.8.0.x
WG_ALLOWED_IPS=0.0.0.0/0
WG_PERSISTENT_KEEPALIVE=25
PORT=51821
WG_PORT=51820
UI_TRAFFIC_STATS=true
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │               WG-Easy — WireGuard VPN + Interface web            │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/                         │
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  Serveur VPN : ${WG_HOST}:51820 (UDP)                            │
  │                                                                  │
  │  Pour ajouter un client VPN :                                    │
  │    1. Ouvrir l'interface web                                     │
  │    2. Cliquer "+ New client"                                     │
  │    3. Scanner le QR code ou télécharger le fichier .conf         │
  │                                                                  │
  │  ⚠ Le port UDP 51820 est ouvert dans UFW automatiquement.        │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║             WG-Easy — Mot de passe admin             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL     : https://${CALEOPE_DOMAIN}/"
echo "  ║  Password: ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ WG-Easy configuré (VPN: ${WG_HOST}:51820/UDP)"
