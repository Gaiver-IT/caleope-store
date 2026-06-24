#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/photoprism"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/photoprism/originals"
mkdir -p "${CALEOPE_APP_DATA}/photoprism/storage"

PHOTOPRISM_PORT_WEB=""
PHOTOPRISM_ADMIN_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    PHOTOPRISM_PORT_WEB=$(grep "^PHOTOPRISM_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PHOTOPRISM_ADMIN_PASSWORD=$(grep "^PHOTOPRISM_ADMIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_PHOTOPRISM_PORT_WEB:-}" ] && PHOTOPRISM_PORT_WEB="${PARAM_PHOTOPRISM_PORT_WEB}"
[ -n "${PARAM_PHOTOPRISM_ADMIN_PASSWORD:-}" ] && PHOTOPRISM_ADMIN_PASSWORD="${PARAM_PHOTOPRISM_ADMIN_PASSWORD}"
[ -z "${PHOTOPRISM_PORT_WEB}" ] && PHOTOPRISM_PORT_WEB="2342"
[ -z "${PHOTOPRISM_ADMIN_PASSWORD}" ] && PHOTOPRISM_ADMIN_PASSWORD="$(openssl rand -base64 12)"

SITE_URL="http://${CALEOPE_DOMAIN:-localhost}:${PHOTOPRISM_PORT_WEB}/"

cat > "${_SECRETS}" <<ENV
PHOTOPRISM_PORT_WEB=${PHOTOPRISM_PORT_WEB}
PHOTOPRISM_ADMIN_USER=admin
PHOTOPRISM_ADMIN_PASSWORD=${PHOTOPRISM_ADMIN_PASSWORD}
PHOTOPRISM_AUTH_MODE=password
PHOTOPRISM_SITE_URL=${SITE_URL}
PHOTOPRISM_ORIGINALS_LIMIT=5000
PHOTOPRISM_HTTP_COMPRESSION=gzip
PHOTOPRISM_LOG_LEVEL=info
PHOTOPRISM_READONLY=false
PHOTOPRISM_EXPERIMENTAL=false
PHOTOPRISM_DISABLE_CHOWN=false
PHOTOPRISM_DISABLE_WEBDAV=false
PHOTOPRISM_DISABLE_SETTINGS=false
PHOTOPRISM_DISABLE_TENSORFLOW=false
PHOTOPRISM_DISABLE_FACES=false
PHOTOPRISM_DISABLE_CLASSIFICATION=false
PHOTOPRISM_FFMPEG_ENCODER=software
PHOTOPRISM_DATABASE_DRIVER=sqlite
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ PhotoPrism configuré"

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
    if authentik_register_app "PhotoPrism" "photoprism" "https://photos.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
PhotoPrism est démarré.
Interface : http://<IP>:${PHOTOPRISM_PORT_WEB}

Identifiants : admin / ${PHOTOPRISM_ADMIN_PASSWORD}
Changez le mot de passe immédiatement.

Vos photos doivent être placées dans :
${CALEOPE_APP_DATA}/photoprism/originals/

Lancez une indexation depuis l'interface : Library > Index
INFO

echo "✓ PhotoPrism prêt — http://<IP>:${PHOTOPRISM_PORT_WEB}"
