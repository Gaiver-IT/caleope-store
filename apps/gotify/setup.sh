#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/gotify"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/gotify/data"

GOTIFY_PORT_WEB=""
GOTIFY_DEFAULTUSER_PASS=""
if [ -f "${_SECRETS}" ]; then
    GOTIFY_PORT_WEB=$(grep "^GOTIFY_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    GOTIFY_DEFAULTUSER_PASS=$(grep "^GOTIFY_DEFAULTUSER_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_GOTIFY_PORT_WEB:-}" ] && GOTIFY_PORT_WEB="${CALEOPE_PARAM_GOTIFY_PORT_WEB}"
[ -n "${CALEOPE_PARAM_GOTIFY_DEFAULTUSER_PASS:-}" ] && GOTIFY_DEFAULTUSER_PASS="${CALEOPE_PARAM_GOTIFY_DEFAULTUSER_PASS}"
[ -z "${GOTIFY_PORT_WEB}" ] && GOTIFY_PORT_WEB="8090"
[ -z "${GOTIFY_DEFAULTUSER_PASS}" ] && GOTIFY_DEFAULTUSER_PASS="$(openssl rand -base64 12)"

cat > "${_SECRETS}" <<ENV
GOTIFY_PORT_WEB=${GOTIFY_PORT_WEB}
GOTIFY_DEFAULTUSER_PASS=${GOTIFY_DEFAULTUSER_PASS}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Gotify configuré"

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
    if authentik_register_app "Gotify" "gotify" "https://gotify.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Gotify est démarré.
Interface : http://<IP>:${GOTIFY_PORT_WEB}

Identifiants par défaut : admin / ${GOTIFY_DEFAULTUSER_PASS}
Changer le mot de passe dans Settings après connexion.
INFO

echo "✓ Gotify prêt — http://<IP>:${GOTIFY_PORT_WEB}"
