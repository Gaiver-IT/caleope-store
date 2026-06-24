#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/memos"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/memos/data"

MEMOS_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    MEMOS_PORT_WEB=$(grep "^MEMOS_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_MEMOS_PORT_WEB:-}" ] && MEMOS_PORT_WEB="${CALEOPE_PARAM_MEMOS_PORT_WEB}"
[ -z "${MEMOS_PORT_WEB}" ] && MEMOS_PORT_WEB="5230"

cat > "${_SECRETS}" <<ENV
MEMOS_PORT_WEB=${MEMOS_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Memos configuré"

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
    if authentik_register_app "Memos" "memos" "https://memos.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

# ── Compte admin Memos + token API ───────────────────────────────────────────
MEMOS_ADMIN_USER=""
MEMOS_ADMIN_PASS=""
MEMOS_API_TOKEN=""
if [ -f "${_SECRETS}" ]; then
    MEMOS_ADMIN_USER=$(grep "^MEMOS_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MEMOS_ADMIN_PASS=$(grep "^MEMOS_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    MEMOS_API_TOKEN=$(grep "^MEMOS_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${MEMOS_ADMIN_USER}" ] && MEMOS_ADMIN_USER="admin"
[ -z "${MEMOS_ADMIN_PASS}" ] && MEMOS_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"

# Attendre que memos soit prêt
_mm_ready=false
echo "→ Attente démarrage Memos..."
for _i in $(seq 1 20); do
    if curl -sf --max-time 3 "http://localhost:${MEMOS_PORT_WEB}/api/v1/users" >/dev/null 2>&1; then
        _mm_ready=true; break
    fi
    sleep 3
done

if ${_mm_ready}; then
    # Créer l'utilisateur admin (idempotent - ignore si déjà existant)
    curl -sf --max-time 10 -X POST "http://localhost:${MEMOS_PORT_WEB}/api/v1/users" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${MEMOS_ADMIN_USER}\",\"password\":\"${MEMOS_ADMIN_PASS}\",\"role\":\"HOST\"}" \
        >/dev/null 2>&1 || true
    echo "  ✓ Compte admin Memos configuré"

    # Obtenir le token d'accès
    if [ -z "${MEMOS_API_TOKEN}" ]; then
        _token_resp=$(curl -sf --max-time 10 -X POST "http://localhost:${MEMOS_PORT_WEB}/api/v1/auth/signin" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${MEMOS_ADMIN_USER}\",\"password\":\"${MEMOS_ADMIN_PASS}\"}" 2>/dev/null) || _token_resp=""
        _token=$(echo "${_token_resp}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null) || _token=""
        if [ -n "${_token}" ]; then
            MEMOS_API_TOKEN="${_token}"
            echo "  ✓ Token API Memos généré"
        fi
    fi
fi

# Stocker les credentials
{
    grep -v "^MEMOS_ADMIN_USER=\|^MEMOS_ADMIN_PASS=\|^MEMOS_API_TOKEN=" "${_SECRETS}" 2>/dev/null || true
    echo "MEMOS_ADMIN_USER=${MEMOS_ADMIN_USER}"
    echo "MEMOS_ADMIN_PASS=${MEMOS_ADMIN_PASS}"
    [ -n "${MEMOS_API_TOKEN}" ] && echo "MEMOS_API_TOKEN=${MEMOS_API_TOKEN}"
} > "${_SECRETS}.tmp" && mv "${_SECRETS}.tmp" "${_SECRETS}"
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Memos est démarré.
Interface : http://<IP>:${MEMOS_PORT_WEB}

Utilisateur : ${MEMOS_ADMIN_USER}
Mot de passe : ${MEMOS_ADMIN_PASS}
INFO

echo "✓ Memos prêt — http://<IP>:${MEMOS_PORT_WEB}"
