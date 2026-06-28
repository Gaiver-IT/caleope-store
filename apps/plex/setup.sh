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

# Preserve PLEX_CLAIM on reinstall (token is single-use, don't regenerate)
PLEX_CLAIM=""
if [ -f "${_SECRETS}" ]; then
    PLEX_CLAIM=$(grep "^PLEX_CLAIM=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_PLEX_CLAIM:-}" ] && PLEX_CLAIM="${CALEOPE_PARAM_PLEX_CLAIM}"

cat > "${_SECRETS}" <<ENV
PLEX_CLAIM=${PLEX_CLAIM}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Plex — Serveur multimédia                          │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/web                       │
  │                                                                  │
  │  Un compte Plex est requis pour la configuration initiale.       │
  │  Obtenez un claim token sur https://plex.tv/claim                │
  │  puis reinstallez avec : caleope install plex                    │
  │    --param plex_claim=<token>                                    │
  │                                                                  │
  │  Médiathèques disponibles :                                      │
  │    Films  : ${CALEOPE_BASE_DIR}/app-data/plex/movies/            │
  │    Séries : ${CALEOPE_BASE_DIR}/app-data/plex/tv/                │
  │    Musique: ${CALEOPE_BASE_DIR}/app-data/plex/music/             │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Plex — Serveur multimédia                  ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL    : https://${CALEOPE_DOMAIN}/web"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Plex configuré"
