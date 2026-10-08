#!/bin/bash
set -euo pipefail

trap 'echo "❌ setup.sh Invidious : erreur ligne ${LINENO}" >&2' ERR

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}"
SECRETS="${CONFIG_DIR}/secrets.env"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${CONFIG_DIR}/schema/sql"
mkdir -p "${DATA_DIR}/postgres" "${DATA_DIR}/companion-cache"

# Le schéma officiel est livré dans le paquet afin que PostgreSQL puisse
# initialiser une base vide sans cloner de dépôt sur le serveur Caleope.
cp -f "${PACKAGE_DIR}/schema/init-invidious-db.sh" "${CONFIG_DIR}/schema/init-invidious-db.sh"
cp -f "${PACKAGE_DIR}"/schema/sql/*.sql "${CONFIG_DIR}/schema/sql/"
chmod 755 "${CONFIG_DIR}/schema/init-invidious-db.sh"
chmod 644 "${CONFIG_DIR}"/schema/sql/*.sql

_previous() {
    [ -f "${SECRETS}" ] && grep -m1 "^$1=" "${SECRETS}" 2>/dev/null | cut -d= -f2- || true
}

DB_PASSWORD="$(_previous INVIDIOUS_DB_PASSWORD)"
HMAC_KEY="$(_previous INVIDIOUS_HMAC_KEY)"
COMPANION_KEY="$(_previous INVIDIOUS_COMPANION_KEY)"

[ -n "${DB_PASSWORD}" ] || DB_PASSWORD="$(openssl rand -hex 24)"
[ -n "${HMAC_KEY}" ] || HMAC_KEY="$(openssl rand -hex 20)"
# Invidious exige exactement 16 caractères pour cette clé.
[ -n "${COMPANION_KEY}" ] || COMPANION_KEY="$(openssl rand -hex 8)"

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
fi

{
    printf 'INVIDIOUS_DB_PASSWORD=%s\n' "${DB_PASSWORD}"
    printf 'INVIDIOUS_HMAC_KEY=%s\n' "${HMAC_KEY}"
    printf 'INVIDIOUS_COMPANION_KEY=%s\n' "${COMPANION_KEY}"
    printf 'POSTGRES_DB=invidious\n'
    printf 'POSTGRES_USER=invidious\n'
    printf 'POSTGRES_PASSWORD=%s\n' "${DB_PASSWORD}"
    printf 'CALEOPE_AUTH_MIDDLEWARE=%s\n' "${CALEOPE_AUTH_MIDDLEWARE}"
} > "${SECRETS}.new"
mv -f "${SECRETS}.new" "${SECRETS}"
chmod 600 "${SECRETS}"

cat > "${CALEOPE_APP_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                 Invidious — YouTube sans publicité               │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  La lecture passe par Invidious Companion.                       │
  │  Les inscriptions Invidious sont désactivées.                    │
  │  Authentik protège l'accès lorsqu'il est installé.               │
  │                                                                  │
  │  Maintenance : redémarrer Invidious régulièrement si YouTube     │
  │  commence à refuser ou ralentir les lectures.                    │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Invidious configuré — https://${CALEOPE_DOMAIN}/"
