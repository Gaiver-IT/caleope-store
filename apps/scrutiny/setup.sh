#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/scrutiny"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/scrutiny/config"
mkdir -p "${CALEOPE_APP_DATA}/scrutiny/influxdb"

SCRUTINY_PORT=""
if [ -f "${_SECRETS}" ]; then
    SCRUTINY_PORT=$(grep "^SCRUTINY_PORT=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_SCRUTINY_PORT:-}" ] && SCRUTINY_PORT="${PARAM_SCRUTINY_PORT}"
[ -z "${SCRUTINY_PORT}" ] && SCRUTINY_PORT="8086"

# Config minimale Scrutiny
cat > "${CALEOPE_APP_DATA}/scrutiny/config/scrutiny.yaml" <<YAML
version: 1

web:
  listen:
    port: 8080
    host: 0.0.0.0

notify:
  urls:
    []
YAML

cat > "${_SECRETS}" <<ENV
SCRUTINY_PORT=${SCRUTINY_PORT}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Scrutiny est démarré.
Interface : http://<IP>:${SCRUTINY_PORT}

Scrutiny surveille automatiquement les disques /dev/sda et /dev/sdb.
Pour ajouter d'autres disques, modifiez les devices dans le docker-compose.yml.

ATTENTION : Scrutiny nécessite des privilèges root (privileged: true).
INFO

echo "✓ Scrutiny prêt — http://<IP>:${SCRUTINY_PORT}"
