#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/monica"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/monica/data"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/monica/db"

MYSQL_PASSWORD=""
MYSQL_ROOT_PASSWORD=""
APP_KEY=""
if [ -f "${_SECRETS}" ]; then
    MYSQL_PASSWORD=$(grep "^MYSQL_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MYSQL_ROOT_PASSWORD=$(grep "^MYSQL_ROOT_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    APP_KEY=$(grep "^APP_KEY=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_MYSQL_PASSWORD:-}" ] && MYSQL_PASSWORD="${CALEOPE_PARAM_MYSQL_PASSWORD}"
[ -n "${CALEOPE_PARAM_MYSQL_ROOT_PASSWORD:-}" ] && MYSQL_ROOT_PASSWORD="${CALEOPE_PARAM_MYSQL_ROOT_PASSWORD}"
[ -z "${MYSQL_PASSWORD}" ] && MYSQL_PASSWORD="$(openssl rand -base64 18)"
[ -z "${MYSQL_ROOT_PASSWORD}" ] && MYSQL_ROOT_PASSWORD="$(openssl rand -base64 18)"
[ -z "${APP_KEY}" ] && APP_KEY="base64:$(openssl rand -base64 32)"

cat > "${_SECRETS}" <<ENV
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
APP_KEY=${APP_KEY}
DB_CONNECTION=mysql
DB_HOST=monica-db
DB_DATABASE=monica
DB_USERNAME=monica
DB_PASSWORD=${MYSQL_PASSWORD}
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${CALEOPE_DOMAIN}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Monica configuré"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              Monica — Gestionnaire de relations personnelles      │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Créez votre compte lors du premier accès via /register.         │
  │  La base de données MySQL est automatiquement configurée.        │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Monica prêt — https://${CALEOPE_DOMAIN}/"
