#!/bin/bash
set -euo pipefail

trap 'echo "❌ setup.sh Music Assistant : erreur ligne ${LINENO}" >&2' ERR

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/data"
SECRETS="${CONFIG_DIR}/secrets.env"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${CONFIG_DIR}" "${DATA_DIR}"

TZ_VALUE="Europe/Paris"
if [ -s /etc/timezone ]; then
    TZ_VALUE="$(tr -d '\r\n' < /etc/timezone)"
fi
LOG_LEVEL="${CALEOPE_PARAM_LOG_LEVEL:-info}"
CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    python3 "${PACKAGE_DIR}/authentik-forward-auth.py" "${CALEOPE_BASE_DIR}" \
        "${CALEOPE_DOMAIN}" "music-assistant" "Music Assistant"
    CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
fi

{
    printf 'TZ=%s\n' "${TZ_VALUE}"
    printf 'LOG_LEVEL=%s\n' "${LOG_LEVEL}"
    printf 'CALEOPE_AUTH_MIDDLEWARE=%s\n' "${CALEOPE_AUTH_MIDDLEWARE}"
} > "${SECRETS}.new"
mv -f "${SECRETS}.new" "${SECRETS}"
chmod 600 "${SECRETS}"

cat > "${CALEOPE_APP_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                 Music Assistant — Musique unifiée                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Dans Settings > Music providers, ajouter :                      │
  │    1. Jellyfin — votre bibliothèque locale                       │
  │    2. Spotify — abonnement Premium requis                        │
  │    3. Deezer — abonnement Premium, HiFi ou Family requis         │
  │    4. YouTube Music — Premium, cookie et PO Token local          │
  │                                                                  │
  │  Les titres Spotify/Deezer sont diffusés à la demande et ne      │
  │  sont pas téléchargés dans le stockage Caleope.                  │
  │  Finamp continue de se connecter directement à Jellyfin.         │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Music Assistant configuré — https://${CALEOPE_DOMAIN}/"
