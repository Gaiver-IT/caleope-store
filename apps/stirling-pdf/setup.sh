#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/stirling-pdf"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/stirling-pdf"/{configs,logs}

STIRLING_PDF_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    STIRLING_PDF_PORT_WEB=$(grep "^STIRLING_PDF_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_STIRLING_PDF_PORT_WEB:-}" ] && STIRLING_PDF_PORT_WEB="${PARAM_STIRLING_PDF_PORT_WEB}"
[ -z "${STIRLING_PDF_PORT_WEB}" ] && STIRLING_PDF_PORT_WEB="8088"

cat > "${_SECRETS}" <<ENV
STIRLING_PDF_PORT_WEB=${STIRLING_PDF_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Stirling PDF est démarré.
Interface : http://<IP>:${STIRLING_PDF_PORT_WEB}

Pas d'authentification par défaut — protéger avec Authentik ForwardAuth si exposé.
INFO

echo "✓ Stirling PDF prêt — http://<IP>:${STIRLING_PDF_PORT_WEB}"
