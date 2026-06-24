#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/freshrss"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/freshrss"/{data,extensions}

FRESHRSS_ADMIN_USER=""
FRESHRSS_ADMIN_PASS=""
FRESHRSS_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    FRESHRSS_ADMIN_USER=$(grep "^FRESHRSS_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    FRESHRSS_ADMIN_PASS=$(grep "^FRESHRSS_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    FRESHRSS_PORT_WEB=$(grep   "^FRESHRSS_PORT_WEB="   "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

[ -n "${PARAM_FRESHRSS_ADMIN_USER:-}" ] && FRESHRSS_ADMIN_USER="${PARAM_FRESHRSS_ADMIN_USER}"
[ -n "${PARAM_FRESHRSS_ADMIN_PASS:-}" ] && FRESHRSS_ADMIN_PASS="${PARAM_FRESHRSS_ADMIN_PASS}"
[ -n "${PARAM_FRESHRSS_PORT_WEB:-}"   ] && FRESHRSS_PORT_WEB="${PARAM_FRESHRSS_PORT_WEB}"
[ -z "${FRESHRSS_ADMIN_USER}" ] && FRESHRSS_ADMIN_USER="admin"
[ -z "${FRESHRSS_ADMIN_PASS}" ] && FRESHRSS_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
[ -z "${FRESHRSS_PORT_WEB}"   ] && FRESHRSS_PORT_WEB="8065"

cat > "${_SECRETS}" <<ENV
FRESHRSS_ADMIN_USER=${FRESHRSS_ADMIN_USER}
FRESHRSS_ADMIN_PASS=${FRESHRSS_ADMIN_PASS}
FRESHRSS_PORT_WEB=${FRESHRSS_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ FreshRSS configuré"

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
    if authentik_register_app "FreshRSS" "freshrss" "https://freshrss.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

# ── Token API FreshRSS (Google Reader API) ────────────────────────────────────
_existing_token=$(grep "^FRESHRSS_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _existing_token=""

if [ -z "${_existing_token}" ]; then
    echo ""
    echo "→ Attente démarrage FreshRSS (max 60s)..."
    for _i in $(seq 1 20); do
        if curl -sf --max-time 3 "http://localhost:${FRESHRSS_PORT_WEB}/" >/dev/null 2>&1; then
            # Activer l'API dans les settings FreshRSS
            docker exec freshrss php /var/www/FreshRSS/cli/update-user.php \
                --user "${FRESHRSS_ADMIN_USER}" \
                --api_password "${FRESHRSS_ADMIN_PASS}" 2>/dev/null || true

            _token_resp=$(curl -sf --max-time 10 -X POST \
                "http://localhost:${FRESHRSS_PORT_WEB}/api/greader.php/accounts/ClientLogin" \
                -d "Email=${FRESHRSS_ADMIN_USER}&Passwd=${FRESHRSS_ADMIN_PASS}" 2>/dev/null) || _token_resp=""

            _api_token=$(echo "${_token_resp}" | grep "^Auth=" | cut -d= -f2-) || _api_token=""

            if [ -n "${_api_token}" ]; then
                sed -i '/^FRESHRSS_API_TOKEN/d' "${_SECRETS}"
                echo "FRESHRSS_API_TOKEN=${_api_token}" >> "${_SECRETS}"
                echo "  ✓ Token API FreshRSS (Google Reader) généré"
            fi
            break
        fi
        sleep 3
    done
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
FreshRSS est démarré.
Interface : http://<IP>:${FRESHRSS_PORT_WEB}
Utilisateur : ${FRESHRSS_ADMIN_USER}
Mot de passe : ${FRESHRSS_ADMIN_PASS}

API Google Reader disponible sur : /api/greader.php
INFO

echo "✓ FreshRSS prêt — http://<IP>:${FRESHRSS_PORT_WEB}"
