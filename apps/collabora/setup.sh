#!/bin/bash
# setup.sh — Collabora Online (CODE) — moteur bureautique pour Nextcloud
set -euo pipefail
echo "→ Préparation de Collabora Online..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
_SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}"

# Domaine de base Caleope (pour autoriser Nextcloud comme hôte WOPI)
BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2- || true)
[ -z "${BASE_DOMAIN}" ] && BASE_DOMAIN="${CALEOPE_DOMAIN#*.}"

# Mot de passe console admin idempotent
ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    ADMIN_PASS=$(grep "^password=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${ADMIN_PASS}" ] && ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)

# aliasgroup1 : regex des hôtes WOPI autorisés (Nextcloud sur le domaine Caleope).
# extra_params : SSL terminé par Traefik (Collabora en HTTP interne).
cat > "${_SECRETS}" <<ENV
username=admin
password=${ADMIN_PASS}
aliasgroup1=https://.*\\.${BASE_DOMAIN}:443
domain=.*\\.${BASE_DOMAIN}
extra_params=--o:ssl.enable=false --o:ssl.termination=true
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │           Collabora Online — Édition de documents               │
  ├──────────────────────────────────────────────────────────────────┤
  │  À connecter à Nextcloud :                                       │
  │   Nextcloud → Apps → « Nextcloud Office »                        │
  │   Réglages → Nextcloud Office → URL du serveur :                │
  │     https://${CALEOPE_DOMAIN}                                    │
  │                                                                  │
  │  Console admin : https://${CALEOPE_DOMAIN}/browser/dist/admin/admin.html │
  │   user: admin   pass: ${ADMIN_PASS}                              │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Collabora Online configuré — à relier depuis Nextcloud"
