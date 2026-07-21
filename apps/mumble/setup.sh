#!/bin/bash
# setup.sh — Mumble (serveur vocal)
set -euo pipefail
echo "→ Préparation de Mumble..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
_SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/data"

WELCOME="${CALEOPE_PARAM_WELCOME_TEXT:-Bienvenue sur ce serveur Mumble Caleope.}"

# Mot de passe SuperUser idempotent (admin du serveur Mumble)
SU_PASS=""
if [ -f "${_SECRETS}" ]; then
    SU_PASS=$(grep "^MUMBLE_SUPERUSER_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${SU_PASS}" ] && SU_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)

cat > "${_SECRETS}" <<ENV
MUMBLE_SUPERUSER_PASSWORD=${SU_PASS}
MUMBLE_CONFIG_welcometext=${WELCOME}
MUMBLE_CONFIG_registerName=Caleope Mumble
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                  Mumble — Serveur vocal                         │
  ├──────────────────────────────────────────────────────────────────┤
  │  Connexion (client Mumble) : ${CALEOPE_DOMAIN}  port 64738      │
  │  Admin : utilisateur « SuperUser »                              │
  │  Mot de passe SuperUser : ${SU_PASS}                            │
  │  (aussi dans app-config/${CALEOPE_APP_ID}/secrets.env)          │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Mumble configuré — ${CALEOPE_DOMAIN}:64738"
