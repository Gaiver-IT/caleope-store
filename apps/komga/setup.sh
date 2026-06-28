#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/komga"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/config"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/comics"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/mangas"
chown -R 1000:1000 "${CALEOPE_BASE_DIR}/app-data/komga" 2>/dev/null || true

KOMGA_ADMIN_EMAIL=""
KOMGA_ADMIN_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    KOMGA_ADMIN_EMAIL=$(grep "^KOMGA_ADMIN_EMAIL=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    KOMGA_ADMIN_PASSWORD=$(grep "^KOMGA_ADMIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_KOMGA_ADMIN_EMAIL:-}" ] && KOMGA_ADMIN_EMAIL="${CALEOPE_PARAM_KOMGA_ADMIN_EMAIL}"
[ -n "${CALEOPE_PARAM_KOMGA_ADMIN_PASSWORD:-}" ] && KOMGA_ADMIN_PASSWORD="${CALEOPE_PARAM_KOMGA_ADMIN_PASSWORD}"

[ -z "${KOMGA_ADMIN_EMAIL}" ] && KOMGA_ADMIN_EMAIL="admin@${CALEOPE_DOMAIN:-localhost}"
if [ -z "${KOMGA_ADMIN_PASSWORD}" ]; then
    KOMGA_ADMIN_PASSWORD=$(openssl rand -hex 16)
    echo "  ✓ Mot de passe admin généré"
fi

# application.yml — définit le compte admin
mkdir -p "${CALEOPE_BASE_DIR}/app-data/komga/config"
cat > "${CALEOPE_BASE_DIR}/app-data/komga/config/application.yml" <<YAML
komga:
  initial-user:
    email: ${KOMGA_ADMIN_EMAIL}
    password: ${KOMGA_ADMIN_PASSWORD}
  oauth2:
    create-user-if-not-exists: true
YAML

cat > "${_SECRETS}" <<ENV
KOMGA_ADMIN_EMAIL=${KOMGA_ADMIN_EMAIL}
KOMGA_ADMIN_PASSWORD=${KOMGA_ADMIN_PASSWORD}
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Komga est démarré.
Interface : http://<IP>:<PORT_WEB>

Identifiants admin :
  Email    : ${KOMGA_ADMIN_EMAIL}
  Password : ${KOMGA_ADMIN_PASSWORD}

Bibliothèques disponibles :
  Comics : ${CALEOPE_BASE_DIR}/app-data/komga/comics/
  Mangas : ${CALEOPE_BASE_DIR}/app-data/komga/mangas/

Pour ajouter vos bibliothèques, allez dans Paramètres → Bibliothèques.
INFO

echo "✓ Komga prêt"
