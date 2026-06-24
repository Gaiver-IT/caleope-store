#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/monica"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/monica/data"
mkdir -p "${CALEOPE_APP_DATA}/monica/db"

MONICA_PORT_WEB=""
MYSQL_PASSWORD=""
MYSQL_ROOT_PASSWORD=""
APP_KEY=""
if [ -f "${_SECRETS}" ]; then
    MONICA_PORT_WEB=$(grep "^MONICA_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MYSQL_PASSWORD=$(grep "^MYSQL_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MYSQL_ROOT_PASSWORD=$(grep "^MYSQL_ROOT_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    APP_KEY=$(grep "^APP_KEY=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_MONICA_PORT_WEB:-}" ] && MONICA_PORT_WEB="${PARAM_MONICA_PORT_WEB}"
[ -n "${PARAM_MYSQL_PASSWORD:-}" ] && MYSQL_PASSWORD="${PARAM_MYSQL_PASSWORD}"
[ -n "${PARAM_MYSQL_ROOT_PASSWORD:-}" ] && MYSQL_ROOT_PASSWORD="${PARAM_MYSQL_ROOT_PASSWORD}"
[ -z "${MONICA_PORT_WEB}" ] && MONICA_PORT_WEB="8082"
[ -z "${MYSQL_PASSWORD}" ] && MYSQL_PASSWORD="$(openssl rand -base64 18)"
[ -z "${MYSQL_ROOT_PASSWORD}" ] && MYSQL_ROOT_PASSWORD="$(openssl rand -base64 18)"
[ -z "${APP_KEY}" ] && APP_KEY="base64:$(openssl rand -base64 32)"

MONICA_DOMAIN="${CALEOPE_DOMAIN:-localhost}"

cat > "${_SECRETS}" <<ENV
MONICA_PORT_WEB=${MONICA_PORT_WEB}
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
APP_URL=http://${MONICA_DOMAIN}:${MONICA_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Monica configuré"

# ── Auto-enregistrement dans Authentik ──────────────────────────────────────
authentik_register_app() {
    local APP_NAME="$1" APP_SLUG="$2" APP_URL="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 1

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    if [ -z "${AK_DOMAIN}" ]; then
        local BASE_DOMAIN_AK
        BASE_DOMAIN_AK=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
        AK_DOMAIN="authentik.${BASE_DOMAIN_AK}"
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
    if authentik_register_app "Monica" "monica" "https://monica.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Monica est démarré.
Interface : http://<IP>:${MONICA_PORT_WEB}

Créez votre compte lors du premier accès via /register.
La base de données MySQL est automatiquement configurée.
INFO

echo "✓ Monica prêt — http://<IP>:${MONICA_PORT_WEB}"
