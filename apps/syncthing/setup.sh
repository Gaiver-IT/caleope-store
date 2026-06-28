#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/syncthing"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/syncthing/config"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"

# Syncthing écrit sa config XML au premier démarrage. On attend puis on patch
# l'adresse d'écoute de 127.0.0.1 → 0.0.0.0 pour accès distant via Traefik.
echo "→ Attente config Syncthing (max 30s)..."
for _i in $(seq 1 10); do
    if [ -f "${CALEOPE_BASE_DIR}/app-data/syncthing/config/config.xml" ]; then
        sed -i 's|<address>127.0.0.1:8384</address>|<address>0.0.0.0:8384</address>|' \
            "${CALEOPE_BASE_DIR}/app-data/syncthing/config/config.xml" 2>/dev/null || true
        echo "  ✓ Syncthing GUI configurée (0.0.0.0:8384)"
        break
    fi
    sleep 3
done

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Syncthing — Synchronisation de fichiers            │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Premier accès : définir un login/password via                   │
  │    Settings → GUI → GUI Authentication                           │
  │                                                                  │
  │  Ports de sync : 22000/TCP+UDP, 21027/UDP (découverte)           │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         Syncthing — Synchronisation fichiers         ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL : https://${CALEOPE_DOMAIN}/"
echo "  ║  → Définir login/password au premier accès           ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Syncthing configuré"
