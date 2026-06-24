#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/plex"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/plex/config"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/plex/tv"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/plex/movies"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/plex/music"
chown -R 1000:1000 "${CALEOPE_BASE_DIR}/app-data/plex" 2>/dev/null || true

PLEX_PORT_WEB=""
PLEX_CLAIM=""
if [ -f "${_SECRETS}" ]; then
    PLEX_PORT_WEB=$(grep "^PLEX_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PLEX_CLAIM=$(grep "^PLEX_CLAIM=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_PLEX_PORT_WEB:-}" ] && PLEX_PORT_WEB="${CALEOPE_PARAM_PLEX_PORT_WEB}"
[ -n "${CALEOPE_PARAM_PLEX_CLAIM:-}" ] && PLEX_CLAIM="${CALEOPE_PARAM_PLEX_CLAIM}"
[ -z "${PLEX_PORT_WEB}" ] && PLEX_PORT_WEB="32400"

cat > "${_SECRETS}" <<ENV
PLEX_PORT_WEB=${PLEX_PORT_WEB}
PLEX_CLAIM=${PLEX_CLAIM}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Plex configuré"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Plex est démarré.
Interface : http://<IP>:${PLEX_PORT_WEB}/web

Un compte Plex est requis pour la configuration initiale.
Obtenez un claim token sur https://plex.tv/claim avant de démarrer.

Médiathèques disponibles :
  Films    : ${CALEOPE_BASE_DIR}/app-data/plex/movies/
  Séries   : ${CALEOPE_BASE_DIR}/app-data/plex/tv/
  Musique  : ${CALEOPE_BASE_DIR}/app-data/plex/music/
INFO

echo "✓ Plex prêt — http://<IP>:${PLEX_PORT_WEB}/web"
