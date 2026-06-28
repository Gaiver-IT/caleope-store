#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/portainer"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/portainer/data"

PORTAINER_ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    PORTAINER_ADMIN_PASS=$(grep "^PORTAINER_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${PORTAINER_ADMIN_PASS}" ] && PORTAINER_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

cat > "${_SECRETS}" <<ENV
PORTAINER_ADMIN_PASS=${PORTAINER_ADMIN_PASS}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Portainer — Gestion Docker                         │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Login : admin                                                   │
  │  Pass  : ${PORTAINER_ADMIN_PASS}                                 │
  │    → Définir à la première connexion (wizard)                    │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Portainer — Gestion Docker                 ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL   : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login : admin"
echo "  ║  Pass  : ${PORTAINER_ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Portainer configuré"
