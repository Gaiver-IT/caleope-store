#!/bin/bash
# setup.sh — Tailscale (VPN mesh)
set -euo pipefail
echo "→ Préparation de Tailscale..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/tailscale"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/state"

# ── Params ──────────────────────────────────────────────────────────────────
TS_AUTHKEY="${CALEOPE_PARAM_TS_AUTHKEY:-}"
TS_HOSTNAME="${CALEOPE_PARAM_TS_HOSTNAME:-caleope-server}"
TS_EXTRA_ARGS="${CALEOPE_PARAM_TS_EXTRA_ARGS:-}"

if [ -z "${TS_AUTHKEY}" ]; then
    echo "❌ TS_AUTHKEY (clé auth Tailscale) est requis" >&2
    exit 1
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# Tailscale
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${TS_HOSTNAME}
TS_EXTRA_ARGS=${TS_EXTRA_ARGS}
TS_STATE_DIR=/var/lib/tailscale
TS_USERSPACE=false
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                    Tailscale — VPN mesh simple                   │
  ├──────────────────────────────────────────────────────────────────┤
  │  Ce serveur rejoint ton réseau Tailscale automatiquement.        │
  │                                                                  │
  │  Nom de la machine : ${TS_HOSTNAME}
  │                                                                  │
  │  Administration : https://login.tailscale.com/admin/machines     │
  │                                                                  │
  │  Pour accéder aux services depuis un appareil Tailscale :        │
  │    → Installer l'app Tailscale sur l'appareil                    │
  │    → Se connecter au même compte Tailscale                       │
  │    → Les services sont accessibles via l'IP Tailscale            │
  │      du serveur (visible dans l'admin Tailscale)                 │
  │                                                                  │
  │  Vérifier la connexion :                                         │
  │    docker exec tailscale tailscale status                        │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "✓ Tailscale configuré (hostname: ${TS_HOSTNAME})"
echo "  → Vérifier la connexion : docker exec tailscale tailscale status"
