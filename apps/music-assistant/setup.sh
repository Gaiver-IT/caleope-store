#!/bin/bash
set -euo pipefail

trap 'echo "❌ setup.sh Music Assistant : erreur ligne ${LINENO}" >&2' ERR

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/data"
SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}" "${DATA_DIR}"

# Music Assistant doit écouter directement sur l'hôte pour mDNS/UPnP. Une
# passerelle Nginx rejoint le réseau Traefik et relaie HTTP + WebSocket.
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8095' 2>/dev/null | grep -q .; then
    if ! docker inspect music-assistant >/dev/null 2>&1; then
        echo "✗ Le port hôte 8095 est déjà utilisé par un autre service." >&2
        exit 1
    fi
fi

cat > "${CONFIG_DIR}/nginx.conf" <<'NGINX'
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    access_log off;
    error_log /var/log/nginx/error.log warn;

    server {
        listen 8095;
        server_name _;

        location / {
            proxy_pass http://host.docker.internal:8095;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }
    }
}
NGINX
chmod 644 "${CONFIG_DIR}/nginx.conf"

TZ_VALUE="Europe/Paris"
if [ -s /etc/timezone ]; then
    TZ_VALUE="$(tr -d '\r\n' < /etc/timezone)"
fi
LOG_LEVEL="${CALEOPE_PARAM_LOG_LEVEL:-info}"

{
    printf 'TZ=%s\n' "${TZ_VALUE}"
    printf 'LOG_LEVEL=%s\n' "${LOG_LEVEL}"
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
  │                                                                  │
  │  Les titres Spotify/Deezer sont diffusés à la demande et ne      │
  │  sont pas téléchargés dans le stockage Caleope.                  │
  │  Finamp continue de se connecter directement à Jellyfin.         │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Music Assistant configuré — https://${CALEOPE_DOMAIN}/"
