#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/navidrome"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/navidrome/data"
mkdir -p "${CALEOPE_APP_DATA}/navidrome/music"
chown -R 1000:1000 "${CALEOPE_APP_DATA}/navidrome" 2>/dev/null || true

NAVIDROME_PORT_WEB=""
ND_LOGLEVEL=""
if [ -f "${_SECRETS}" ]; then
    NAVIDROME_PORT_WEB=$(grep "^NAVIDROME_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    ND_LOGLEVEL=$(grep "^ND_LOGLEVEL=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_NAVIDROME_PORT_WEB:-}" ] && NAVIDROME_PORT_WEB="${PARAM_NAVIDROME_PORT_WEB}"
[ -n "${PARAM_ND_LOGLEVEL:-}" ] && ND_LOGLEVEL="${PARAM_ND_LOGLEVEL}"
[ -z "${NAVIDROME_PORT_WEB}" ] && NAVIDROME_PORT_WEB="4533"
[ -z "${ND_LOGLEVEL}" ] && ND_LOGLEVEL="info"

cat > "${_SECRETS}" <<ENV
NAVIDROME_PORT_WEB=${NAVIDROME_PORT_WEB}
ND_MUSICFOLDER=/music
ND_DATAFOLDER=/data
ND_LOGLEVEL=${ND_LOGLEVEL}
ND_SESSIONTIMEOUT=24h
ND_BASEURL=
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Navidrome configuré"

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
    if authentik_register_app "Navidrome" "navidrome" "https://navidrome.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Navidrome est démarré.
Interface : http://<IP>:${NAVIDROME_PORT_WEB}

Créez le compte admin lors du premier accès.
Placez votre musique dans : ${CALEOPE_APP_DATA}/navidrome/music/
Compatible avec les clients Subsonic (DSub, Symfonium, Ultrasonic, etc.)
INFO

echo "✓ Navidrome prêt — http://<IP>:${NAVIDROME_PORT_WEB}"
