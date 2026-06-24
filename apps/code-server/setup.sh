#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/code-server"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/code-server/config"
mkdir -p "${CALEOPE_APP_DATA}/code-server/workspace"
chown -R 1000:1000 "${CALEOPE_APP_DATA}/code-server" 2>/dev/null || true

CODE_SERVER_PORT=""
CODE_SERVER_PASSWORD=""
CODE_SERVER_SUDO_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    CODE_SERVER_PORT=$(grep "^CODE_SERVER_PORT=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    CODE_SERVER_PASSWORD=$(grep "^CODE_SERVER_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    CODE_SERVER_SUDO_PASSWORD=$(grep "^CODE_SERVER_SUDO_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_CODE_SERVER_PORT:-}" ] && CODE_SERVER_PORT="${PARAM_CODE_SERVER_PORT}"
[ -n "${PARAM_CODE_SERVER_PASSWORD:-}" ] && CODE_SERVER_PASSWORD="${PARAM_CODE_SERVER_PASSWORD}"
[ -n "${PARAM_CODE_SERVER_SUDO_PASSWORD:-}" ] && CODE_SERVER_SUDO_PASSWORD="${PARAM_CODE_SERVER_SUDO_PASSWORD}"

[ -z "${CODE_SERVER_PORT}" ] && CODE_SERVER_PORT="8443"
if [ -z "${CODE_SERVER_PASSWORD}" ]; then
    CODE_SERVER_PASSWORD=$(openssl rand -hex 12)
    echo "  ✓ Mot de passe généré"
fi
[ -z "${CODE_SERVER_SUDO_PASSWORD}" ] && CODE_SERVER_SUDO_PASSWORD="${CODE_SERVER_PASSWORD}"

cat > "${_SECRETS}" <<ENV
CODE_SERVER_PORT=${CODE_SERVER_PORT}
CODE_SERVER_PASSWORD=${CODE_SERVER_PASSWORD}
CODE_SERVER_SUDO_PASSWORD=${CODE_SERVER_SUDO_PASSWORD}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Code Server est démarré.
Interface : http://<IP>:${CODE_SERVER_PORT}

Mot de passe : ${CODE_SERVER_PASSWORD}

Le workspace est accessible dans : ${CALEOPE_APP_DATA}/code-server/workspace/
INFO

echo "✓ Code Server prêt — http://<IP>:${CODE_SERVER_PORT}"
