#!/bin/bash
# setup.sh — Qdrant (base de données vectorielle)
set -euo pipefail
echo "→ Préparation de Qdrant..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/storage"

# ── Clé d'API idempotente (protège l'API REST/gRPC) ──────────────────────────
API_KEY="${CALEOPE_PARAM_QDRANT_API_KEY:-}"
if [ -z "${API_KEY}" ] && [ -f "${_SECRETS}" ]; then
    API_KEY=$(grep "^QDRANT__SERVICE__API_KEY=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${API_KEY}" ] && API_KEY=$(openssl rand -hex 24)

cat > "${_SECRETS}" <<ENV
QDRANT__SERVICE__API_KEY=${API_KEY}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              Qdrant — Base de données vectorielle                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Dashboard : https://${CALEOPE_DOMAIN}/dashboard                 │
  │  API       : https://${CALEOPE_DOMAIN}/  (header api-key requis) │
  │  Clé API   : ${API_KEY}
  │  (aussi dans app-config/${CALEOPE_APP_ID}/secrets.env)           │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Qdrant configuré — https://${CALEOPE_DOMAIN}/dashboard"
