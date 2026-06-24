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
PAPERLESS_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    PAPERLESS_DBPASS=$(grep    "^PAPERLESS_DBPASS="      "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_SECRET_KEY=$(grep "^PAPERLESS_SECRET_KEY=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_ADMIN_USER=$(grep "^PAPERLESS_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_ADMIN_PASS=$(grep "^PAPERLESS_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PAPERLESS_PORT_WEB=$(grep   "^PAPERLESS_PORT_WEB="   "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

[ -n "${CALEOPE_PARAM_PAPERLESS_ADMIN_USER:-}" ] && PAPERLESS_ADMIN_USER="${CALEOPE_PARAM_PAPERLESS_ADMIN_USER}"
[ -n "${CALEOPE_PARAM_PAPERLESS_ADMIN_PASS:-}" ] && PAPERLESS_ADMIN_PASS="${CALEOPE_PARAM_PAPERLESS_ADMIN_PASS}"
[ -n "${CALEOPE_PARAM_PAPERLESS_PORT_WEB:-}"   ] && PAPERLESS_PORT_WEB="${CALEOPE_PARAM_PAPERLESS_PORT_WEB}"
[ -z "${PAPERLESS_DBPASS}"     ] && PAPERLESS_DBPASS=$(openssl rand -hex 24)
[ -z "${PAPERLESS_SECRET_KEY}" ] && PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
[ -z "${PAPERLESS_ADMIN_USER}" ] && PAPERLESS_ADMIN_USER="admin"
[ -z "${PAPERLESS_ADMIN_PASS}" ] && PAPERLESS_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
[ -z "${PAPERLESS_PORT_WEB}"   ] && PAPERLESS_PORT_WEB="8080"

PAPERLESS_DOMAIN="paperless.${CALEOPE_DOMAIN}"

cat > "${_SECRETS}" <<ENV
PAPERLESS_DBNAME=paperless
PAPERLESS_DBUSER=paperless
PAPERLESS_DBPASS=${PAPERLESS_DBPASS}
PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET_KEY}
PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER}
PAPERLESS_ADMIN_PASS=${PAPERLESS_ADMIN_PASS}
PAPERLESS_PORT_WEB=${PAPERLESS_PORT_WEB}
PAPERLESS_DOMAIN=${PAPERLESS_DOMAIN}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Paperless-NGX configuré"

# ── Auto-enregistrement dans Authentik ──────────────────────────────────────
authentik_register_app() {
    local APP_NAME="$1" APP_SLUG="$2" APP_URL="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 1

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    if [ -z "${AK_DOMAIN}" ]; then
        local BASE_DOMAIN
        BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
        AK_DOMAIN="authentik.${BASE_DOMAIN}"
    fi
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || return 1

    local BASE="https://${AK_DOMAIN}/api/v3"
    local HA="Authorization: Bearer ${TOKEN}"
    local HJ="Content-Type: application/json"

    local i=0
    until curl -sf --max-time 5 -H "${HA}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 6 ] || return 1; sleep 5
    done

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/flows/instances/?designation=authentication" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['pk'])" 2>/dev/null) || return 1

    local APP_UUID
    APP_UUID=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/core/applications/?slug=${APP_SLUG}" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('results',[]); print(r[0]['pk'] if r else '')" 2>/dev/null) || APP_UUID=""

    if [ -z "${APP_UUID}" ]; then
        local PROV_ID
        PROV_ID=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" "${BASE}/providers/proxy/" \
            -d "{\"name\":\"${APP_NAME} Proxy\",\"authorization_flow\":\"${FLOW_UUID}\",\"mode\":\"forward_single\",\"external_host\":\"${APP_URL}\"}" \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['pk'])") || return 1
        curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" "${BASE}/core/applications/" \
            -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROV_ID},\"meta_launch_url\":\"${APP_URL}\"}" >/dev/null || return 1
    fi

    echo "  → ${APP_NAME} enregistré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    if authentik_register_app "Paperless-NGX" "paperless-ngx" "https://${PAPERLESS_DOMAIN}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

# ── Token API auto-généré après démarrage ─────────────────────────────────────
_existing_token=$(grep "^PAPERLESS_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _existing_token=""

if [ -z "${_existing_token}" ]; then
    echo ""
    echo "→ Attente démarrage Paperless-NGX (max 120s)..."
    _pl_ready=false
    for _i in $(seq 1 40); do
        if curl -sf --max-time 3 "http://localhost:${PAPERLESS_PORT_WEB}/api/token/" >/dev/null 2>&1; then
            _pl_ready=true; break
        fi
        sleep 3
    done

    if ${_pl_ready}; then
        _token_resp=$(curl -sf --max-time 15 -X POST \
            "http://localhost:${PAPERLESS_PORT_WEB}/api/token/" \
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
Paperless-NGX est démarré.
Interface : http://<IP>:${PAPERLESS_PORT_WEB}
Utilisateur admin : ${PAPERLESS_ADMIN_USER}
Mot de passe      : ${PAPERLESS_ADMIN_PASS}

Répertoire d'import automatique : ${CALEOPE_BASE_DIR}/app-data/paperless-ngx/consume
INFO

echo "✓ Paperless-NGX prêt — http://<IP>:${PAPERLESS_PORT_WEB}"
