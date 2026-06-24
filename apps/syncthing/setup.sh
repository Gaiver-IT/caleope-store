#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/syncthing"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/syncthing/config"

SYNCTHING_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    SYNCTHING_PORT_WEB=$(grep "^SYNCTHING_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_SYNCTHING_PORT_WEB:-}" ] && SYNCTHING_PORT_WEB="${CALEOPE_PARAM_SYNCTHING_PORT_WEB}"
[ -z "${SYNCTHING_PORT_WEB}" ] && SYNCTHING_PORT_WEB="8384"

cat > "${_SECRETS}" <<ENV
SYNCTHING_PORT_WEB=${SYNCTHING_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Syncthing configuré"

# ── Configurer l'adresse d'écoute GUI (pas seulement localhost) ───────────────
echo ""
echo "→ Attente démarrage Syncthing (max 30s)..."
for _i in $(seq 1 10); do
    if [ -f "${CALEOPE_BASE_DIR}/app-data/syncthing/config/config.xml" ]; then
        # Remplacer 127.0.0.1 par 0.0.0.0 pour l'accès distant
        sed -i 's|<address>127.0.0.1:8384</address>|<address>0.0.0.0:8384</address>|' \
            "${CALEOPE_BASE_DIR}/app-data/syncthing/config/config.xml" 2>/dev/null || true
        echo "  ✓ Syncthing GUI configurée pour accès distant"
        break
    fi
    sleep 3
done

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Syncthing est démarré.
Interface : http://<IP>:${SYNCTHING_PORT_WEB}

La configuration se fait dans l'interface web.
Ports ouverts : 22000 (sync TCP/UDP), 21027 (découverte UDP).
INFO

echo "✓ Syncthing prêt — http://<IP>:${SYNCTHING_PORT_WEB}"
