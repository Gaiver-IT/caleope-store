#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/ntfy"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/ntfy/data"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/ntfy/config"

NTFY_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    NTFY_PORT_WEB=$(grep "^NTFY_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_NTFY_PORT_WEB:-}" ] && NTFY_PORT_WEB="${CALEOPE_PARAM_NTFY_PORT_WEB}"
[ -z "${NTFY_PORT_WEB}" ] && NTFY_PORT_WEB="8070"

cat > "${_SECRETS}" <<ENV
NTFY_PORT_WEB=${NTFY_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"

# Créer la config ntfy si absente
NTFY_CONF="${CALEOPE_BASE_DIR}/app-data/ntfy/config/server.yml"
if [ ! -f "${NTFY_CONF}" ]; then
    cat > "${NTFY_CONF}" <<CONF
base-url: "https://ntfy.${CALEOPE_DOMAIN#*.}"
listen-http: ":80"
cache-file: "/var/lib/ntfy/cache.db"
auth-file: "/var/lib/ntfy/auth.db"
auth-default-access: "deny-all"
behind-proxy: true
CONF
    chmod 644 "${NTFY_CONF}"
fi

echo "  ✓ ntfy configuré"

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
    if authentik_register_app "ntfy" "ntfy" "https://ntfy.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
ntfy est démarré.
Interface : http://<IP>:${NTFY_PORT_WEB}

Configurer des topics via l'interface web ou l'API REST.
Docs : https://docs.ntfy.sh/
INFO

echo "✓ ntfy prêt — http://<IP>:${NTFY_PORT_WEB}"
