#!/bin/bash
# setup.sh — Authentik Identity Provider
# Variables injectées par Caleope :
#   CALEOPE_BASE_DIR, CALEOPE_APP_ID, CALEOPE_APP_DIR, CALEOPE_DOMAIN
set -euo pipefail
echo "→ Préparation d'Authentik..."

APP_CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/authentik"
APP_DATA_DIR="${CALEOPE_BASE_DIR}/app-data/authentik"

mkdir -p "${APP_CONFIG_DIR}"
mkdir -p "${APP_DATA_DIR}/"{media,custom-templates,db,redis}

# Authentik tourne en UID/GID 1000 dans ses containers (server + worker)
# Les volumes media et custom-templates doivent lui appartenir
chown -R 1000:1000 "${APP_DATA_DIR}/media"
chown -R 1000:1000 "${APP_DATA_DIR}/custom-templates"

# Génération des secrets — on préserve les valeurs existantes sur réinstall
# pour ne pas casser la base Postgres (password divergerait du volume DB)
_PREV_SECRETS="${APP_CONFIG_DIR}/secrets.env"
SECRET_KEY=$(openssl rand -hex 50)
DB_PASS=$(openssl rand -hex 20)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
ADMIN_TOKEN=$(openssl rand -hex 32)
if [[ -f "${_PREV_SECRETS}" ]]; then
    _P_SK=$(grep "^AUTHENTIK_SECRET_KEY=" "${_PREV_SECRETS}" 2>/dev/null | cut -d= -f2-) && [[ -n "${_P_SK}" ]] && SECRET_KEY="${_P_SK}"
    _P_DB=$(grep "^POSTGRES_PASSWORD=" "${_PREV_SECRETS}" 2>/dev/null | cut -d= -f2-)  && [[ -n "${_P_DB}" ]] && DB_PASS="${_P_DB}"
    _P_AP=$(grep "^AUTHENTIK_BOOTSTRAP_PASSWORD=" "${_PREV_SECRETS}" 2>/dev/null | cut -d= -f2-) && [[ -n "${_P_AP}" ]] && ADMIN_PASS="${_P_AP}"
    _P_AT=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${_PREV_SECRETS}" 2>/dev/null | cut -d= -f2-)   && [[ -n "${_P_AT}" ]] && ADMIN_TOKEN="${_P_AT}"
    echo "  ✓ Secrets existants conservés (réinstall)"
fi

cat > "${APP_CONFIG_DIR}/secrets.env" << EOF
# PostgreSQL
POSTGRES_PASSWORD=${DB_PASS}
AUTHENTIK_POSTGRESQL__PASSWORD=${DB_PASS}

# Authentik core
AUTHENTIK_SECRET_KEY=${SECRET_KEY}
AUTHENTIK_ERROR_REPORTING__ENABLED=false

# URL externe navigateur — séparée de l'URL interne Docker (http://authentik-server:9000)
# pour que le discovery document OIDC retourne une authorization_endpoint accessible
# par le navigateur, tout en gardant le token_endpoint sur l'URL interne Docker.
AUTHENTIK_HOST_BROWSER=https://${CALEOPE_DOMAIN}

# Bootstrap admin (premier démarrage uniquement)
AUTHENTIK_BOOTSTRAP_EMAIL=admin@${CALEOPE_DOMAIN}
AUTHENTIK_BOOTSTRAP_PASSWORD=${ADMIN_PASS}
AUTHENTIK_BOOTSTRAP_TOKEN=${ADMIN_TOKEN}

# Domaine Authentik (lu par les autres apps pour l'auto-enregistrement)
AUTHENTIK_DOMAIN=${CALEOPE_DOMAIN}
EOF
chmod 600 "${APP_CONFIG_DIR}/secrets.env"

cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                Authentik — Gestionnaire d'identités              │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⏳  Authentik initialise sa base (1-2 min au premier boot).     │
  │                                                                  │
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/if/admin/               │
  │    Login    : akadmin                                            │
  │    Password : ${ADMIN_PASS}                              │
  │                                                                  │
  │  Token API  : ${ADMIN_TOKEN}             │
  │                                                                  │
  │  ── Intégration ForwardAuth avec les autres apps ──              │
  │  Le middleware Traefik "authentik@docker" est automatiquement    │
  │  disponible. Pour protéger une app installée, ajoutez dans       │
  │  son docker-compose.yml :                                        │
  │    CALEOPE_AUTH_MIDDLEWARE=authentik@docker                      │
  │  dans son fichier app-config/<app>/secrets.env, puis relancez.  │
  │                                                                  │
  │  Secrets dans : app-config/authentik/secrets.env                │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          Authentik — Identifiants d'accès            ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL admin : https://${CALEOPE_DOMAIN}/if/admin/"
echo "  ║  Login     : akadmin"
echo "  ║  Password  : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Authentik configuré"
