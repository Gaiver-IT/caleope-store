#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/paperless-ngx"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/paperless-ngx"/{data,media,export,consume,db,redis}

# Préserver les secrets existants
PAPERLESS_DBPASS=""
PAPERLESS_SECRET_KEY=""
PAPERLESS_ADMIN_USER=""
PAPERLESS_ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    PAPERLESS_DBPASS=$(grep    "^PAPERLESS_DBPASS="      "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_SECRET_KEY=$(grep "^PAPERLESS_SECRET_KEY=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_ADMIN_USER=$(grep "^PAPERLESS_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_ADMIN_PASS=$(grep "^PAPERLESS_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

[ -n "${CALEOPE_PARAM_PAPERLESS_ADMIN_USER:-}" ] && PAPERLESS_ADMIN_USER="${CALEOPE_PARAM_PAPERLESS_ADMIN_USER}"
[ -n "${CALEOPE_PARAM_PAPERLESS_ADMIN_PASS:-}" ] && PAPERLESS_ADMIN_PASS="${CALEOPE_PARAM_PAPERLESS_ADMIN_PASS}"
[ -z "${PAPERLESS_DBPASS}"     ] && PAPERLESS_DBPASS=$(openssl rand -hex 24)
[ -z "${PAPERLESS_SECRET_KEY}" ] && PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
[ -z "${PAPERLESS_ADMIN_USER}" ] && PAPERLESS_ADMIN_USER="admin"
[ -z "${PAPERLESS_ADMIN_PASS}" ] && PAPERLESS_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

cat > "${_SECRETS}" <<ENV
PAPERLESS_DBNAME=paperless
PAPERLESS_DBUSER=paperless
PAPERLESS_DBPASS=${PAPERLESS_DBPASS}
PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET_KEY}
PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER}
PAPERLESS_ADMIN_PASS=${PAPERLESS_ADMIN_PASS}
PAPERLESS_URL=https://${CALEOPE_DOMAIN}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Paperless-NGX configuré"

# ── Token API auto-généré après démarrage ─────────────────────────────────────
_existing_token=$(grep "^PAPERLESS_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _existing_token=""

if [ -z "${_existing_token}" ]; then
    echo ""
    echo "→ Attente démarrage Paperless-NGX (max 120s)..."
    _pl_ready=false
    for _i in $(seq 1 40); do
        if curl -sf --max-time 3 "http://localhost:${CALEOPE_PORT_WEB}/api/token/" >/dev/null 2>&1; then
            _pl_ready=true; break
        fi
        sleep 3
    done

    if ${_pl_ready}; then
        _token_resp=$(curl -sf --max-time 15 -X POST \
            "http://localhost:${CALEOPE_PORT_WEB}/api/token/" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${PAPERLESS_ADMIN_USER}\",\"password\":\"${PAPERLESS_ADMIN_PASS}\"}" 2>/dev/null) || _token_resp=""

        _api_token=$(echo "${_token_resp}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null) || _api_token=""

        if [ -n "${_api_token}" ]; then
            sed -i '/^PAPERLESS_API_TOKEN/d' "${_SECRETS}"
            echo "PAPERLESS_API_TOKEN=${_api_token}" >> "${_SECRETS}"
            echo "  ✓ Token API Paperless-NGX généré"
        else
            echo "  ⚠ Token API non obtenu"
        fi
    else
        echo "  ⚠ Paperless-NGX non joignable après 120s"
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │            Paperless-NGX — Gestion documentaire sans papier      │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface    : https://${CALEOPE_DOMAIN}/                       │
  │  Utilisateur  : ${PAPERLESS_ADMIN_USER}                          │
  │  Mot de passe : ${PAPERLESS_ADMIN_PASS}                          │
  │                                                                  │
  │  Répertoire d'import automatique :                               │
  │    ${CALEOPE_BASE_DIR}/app-data/paperless-ngx/consume            │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Paperless-NGX prêt — https://${CALEOPE_DOMAIN}/"
