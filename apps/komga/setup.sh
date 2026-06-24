#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/komga"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/komga/config"
mkdir -p "${CALEOPE_APP_DATA}/komga/comics"
mkdir -p "${CALEOPE_APP_DATA}/komga/mangas"
chown -R 1000:1000 "${CALEOPE_APP_DATA}/komga" 2>/dev/null || true

KOMGA_PORT=""
KOMGA_ADMIN_EMAIL=""
KOMGA_ADMIN_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    KOMGA_PORT=$(grep "^KOMGA_PORT=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    KOMGA_ADMIN_EMAIL=$(grep "^KOMGA_ADMIN_EMAIL=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    KOMGA_ADMIN_PASSWORD=$(grep "^KOMGA_ADMIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_KOMGA_PORT:-}" ] && KOMGA_PORT="${PARAM_KOMGA_PORT}"
[ -n "${PARAM_KOMGA_ADMIN_EMAIL:-}" ] && KOMGA_ADMIN_EMAIL="${PARAM_KOMGA_ADMIN_EMAIL}"
[ -n "${PARAM_KOMGA_ADMIN_PASSWORD:-}" ] && KOMGA_ADMIN_PASSWORD="${PARAM_KOMGA_ADMIN_PASSWORD}"

[ -z "${KOMGA_PORT}" ] && KOMGA_PORT="8085"
[ -z "${KOMGA_ADMIN_EMAIL}" ] && KOMGA_ADMIN_EMAIL="admin@${CALEOPE_DOMAIN:-localhost}"
if [ -z "${KOMGA_ADMIN_PASSWORD}" ]; then
    KOMGA_ADMIN_PASSWORD=$(openssl rand -hex 16)
    echo "  ✓ Mot de passe admin généré"
fi

# application.yml — définit le compte admin
mkdir -p "${CALEOPE_APP_DATA}/komga/config"
cat > "${CALEOPE_APP_DATA}/komga/config/application.yml" <<YAML
komga:
  initial-user:
    email: ${KOMGA_ADMIN_EMAIL}
    password: ${KOMGA_ADMIN_PASSWORD}
  oauth2:
    create-user-if-not-exists: true
YAML

cat > "${_SECRETS}" <<ENV
KOMGA_PORT=${KOMGA_PORT}
KOMGA_ADMIN_EMAIL=${KOMGA_ADMIN_EMAIL}
KOMGA_ADMIN_PASSWORD=${KOMGA_ADMIN_PASSWORD}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Komga est démarré.
Interface : http://<IP>:${KOMGA_PORT}

Identifiants admin :
  Email    : ${KOMGA_ADMIN_EMAIL}
  Password : ${KOMGA_ADMIN_PASSWORD}

Bibliothèques disponibles :
  Comics : ${CALEOPE_APP_DATA}/komga/comics/
  Mangas : ${CALEOPE_APP_DATA}/komga/mangas/

Pour ajouter vos bibliothèques, allez dans Paramètres → Bibliothèques.
INFO

echo "✓ Komga prêt — http://<IP>:${KOMGA_PORT}"
