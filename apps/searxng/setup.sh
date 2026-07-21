#!/bin/bash
# setup.sh — SearXNG (métamoteur de recherche privé)
set -euo pipefail
echo "→ Préparation de SearXNG..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
SX_DIR="${CONFIG_DIR}/searxng"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${SX_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/valkey"

# ── Secret idempotent (param > existant > généré) ────────────────────────────
SEARXNG_SECRET="${CALEOPE_PARAM_SEARXNG_SECRET:-}"
if [ -z "${SEARXNG_SECRET}" ] && [ -f "${_SECRETS}" ]; then
    SEARXNG_SECRET=$(grep "^SEARXNG_SECRET=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${SEARXNG_SECRET}" ] && SEARXNG_SECRET=$(openssl rand -hex 32)

cat > "${_SECRETS}" <<ENV
SEARXNG_SECRET=${SEARXNG_SECRET}
SEARXNG_BASE_URL=https://${CALEOPE_DOMAIN}/
ENV
chmod 600 "${_SECRETS}"

# settings.yml : généré seulement s'il n'existe pas (l'image le complète au 1er run).
# On pose le redis (valkey) et le secret ; le reste = défauts SearXNG.
if [ ! -f "${SX_DIR}/settings.yml" ]; then
cat > "${SX_DIR}/settings.yml" <<YML
use_default_settings: true
server:
  secret_key: "${SEARXNG_SECRET}"
  limiter: true
  image_proxy: true
redis:
  url: redis://searxng-redis:6379/0
search:
  formats:
    - html
    - json
YML
fi
chmod 644 "${SX_DIR}/settings.yml"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │            SearXNG — Recherche web sans profilage                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │  API JSON  : https://${CALEOPE_DOMAIN}/search?q=...&format=json  │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ SearXNG configuré — https://${CALEOPE_DOMAIN}/"
