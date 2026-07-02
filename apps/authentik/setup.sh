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

# Bootstrap admin (premier démarrage uniquement)
AUTHENTIK_BOOTSTRAP_EMAIL=admin@${CALEOPE_DOMAIN}
AUTHENTIK_BOOTSTRAP_PASSWORD=${ADMIN_PASS}
AUTHENTIK_BOOTSTRAP_TOKEN=${ADMIN_TOKEN}

# Domaine Authentik (lu par les autres apps pour l'auto-enregistrement)
AUTHENTIK_DOMAIN=${CALEOPE_DOMAIN}

# URL publique d'Authentik (nécessaire pour que l'outpost embedded génère
# des redirect URIs correctes au lieu de 0.0.0.0:9000)
AUTHENTIK_AUTHENTIK__URL=https://${CALEOPE_DOMAIN}
EOF
chmod 600 "${APP_CONFIG_DIR}/secrets.env"

# ── Certificat auto-signé pour le domaine Authentik ──────────────────
# Traefik (websecure :443) sert ce cert pour les appels HTTPS internes
# (ex: Jellyfin → token exchange OIDC via extra_hosts → 172.17.0.1:443)
# Les apps qui en ont besoin récupèrent ce cert pour construire leur CA bundle.
TRAEFIK_CERTS="${CALEOPE_BASE_DIR}/data/traefik/certs"
TRAEFIK_DYN="${CALEOPE_BASE_DIR}/data/traefik/dynamic"
mkdir -p "${TRAEFIK_CERTS}" "${TRAEFIK_DYN}"

# Supprimer si authentik.crt est un répertoire (erreur de création antérieure)
[[ -d "${TRAEFIK_CERTS}/authentik.crt" ]] && rm -rf "${TRAEFIK_CERTS}/authentik.crt"
[[ -d "${TRAEFIK_CERTS}/authentik.key" ]] && rm -rf "${TRAEFIK_CERTS}/authentik.key"

# CALEOPE_DOMAIN est ici le domaine complet de l'app (ex: authentik.caleope-redberry.guernaham.bzh)
# On régénère si le cert n'existe pas ou si le CN ne correspond pas (détecte les mauvais certs)
_REGEN_CERT=true
if [[ -f "${TRAEFIK_CERTS}/authentik.crt" ]]; then
    _ACTUAL_CN=$(openssl x509 -noout -subject -in "${TRAEFIK_CERTS}/authentik.crt" 2>/dev/null \
        | sed 's/.*CN\s*=\s*//')
    if [[ "${_ACTUAL_CN}" == "${CALEOPE_DOMAIN}" ]]; then
        _REGEN_CERT=false
    else
        echo "  ℹ Cert existant (CN=${_ACTUAL_CN}) ≠ attendu (${CALEOPE_DOMAIN}) — regénération"
    fi
fi

if ${_REGEN_CERT}; then
    openssl req -x509 -newkey rsa:4096 \
        -keyout "${TRAEFIK_CERTS}/authentik.key" \
        -out    "${TRAEFIK_CERTS}/authentik.crt" \
        -days 3650 -nodes \
        -subj "/CN=${CALEOPE_DOMAIN}" \
        -addext "subjectAltName=DNS:${CALEOPE_DOMAIN}" \
        2>/dev/null
    chmod 600 "${TRAEFIK_CERTS}/authentik.key"
    chmod 644 "${TRAEFIK_CERTS}/authentik.crt"
    echo "  ✓ Certificat auto-signé généré pour ${CALEOPE_DOMAIN}"
else
    echo "  ✓ Certificat auto-signé existant conservé"
fi

# Config Traefik dynamic : utiliser ce cert pour le domaine Authentik sur :443
# Traefik relit ce fichier à chaud (watch: true dans traefik.yml)
cat > "${TRAEFIK_DYN}/authentik-tls.yml" << TRAFTLS
tls:
  certificates:
    - certFile: /certs/authentik.crt
      keyFile: /certs/authentik.key
TRAFTLS
echo "  ✓ Config TLS Traefik écrite (dynamic/authentik-tls.yml)"

# ── Blueprint : configure l'outpost embedded au premier démarrage ──────────
# Authentik applique automatiquement les blueprints dans /blueprints/custom/
# L'outpost embedded a besoin de authentik_host = URL publique pour que les
# redirects ForwardAuth pointent vers le domaine public et non 0.0.0.0:9000
BLUEPRINTS_DIR="${CALEOPE_BASE_DIR}/app-data/authentik/blueprints"
mkdir -p "${BLUEPRINTS_DIR}"
cat > "${BLUEPRINTS_DIR}/caleope-outpost-config.yaml" << BLUEPRINT
version: 1
metadata:
  name: Caleope - Embedded outpost host
entries:
  - model: authentik_outposts.outpost
    state: present
    identifiers:
      managed: goauthentik.io/outposts/embedded
    attrs:
      config:
        authentik_host: https://${CALEOPE_DOMAIN}
        authentik_host_browser: https://${CALEOPE_DOMAIN}
        authentik_host_insecure: false
BLUEPRINT
echo "  ✓ Blueprint outpost embedded écrit (blueprints/caleope-outpost-config.yaml)"

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
