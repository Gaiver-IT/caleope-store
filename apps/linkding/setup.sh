#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/linkding"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/linkding/data"

LINKDING_ADMIN_USER=""
LINKDING_ADMIN_PASS=""
LINKDING_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    LINKDING_ADMIN_USER=$(grep "^LINKDING_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    LINKDING_ADMIN_PASS=$(grep "^LINKDING_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    LINKDING_PORT_WEB=$(grep  "^LINKDING_PORT_WEB="   "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

[ -n "${CALEOPE_PARAM_LINKDING_ADMIN_USER:-}" ] && LINKDING_ADMIN_USER="${CALEOPE_PARAM_LINKDING_ADMIN_USER}"
[ -n "${CALEOPE_PARAM_LINKDING_ADMIN_PASS:-}" ] && LINKDING_ADMIN_PASS="${CALEOPE_PARAM_LINKDING_ADMIN_PASS}"
[ -n "${CALEOPE_PARAM_LINKDING_PORT_WEB:-}"   ] && LINKDING_PORT_WEB="${CALEOPE_PARAM_LINKDING_PORT_WEB}"
[ -z "${LINKDING_ADMIN_USER}" ] && LINKDING_ADMIN_USER="admin"
[ -z "${LINKDING_ADMIN_PASS}" ] && LINKDING_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
[ -z "${LINKDING_PORT_WEB}"   ] && LINKDING_PORT_WEB="9090"

# Générer un token API pour CaleOpe
LINKDING_API_TOKEN=""
if [ -f "${_SECRETS}" ]; then
    LINKDING_API_TOKEN=$(grep "^LINKDING_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

cat > "${_SECRETS}" <<ENV
LINKDING_ADMIN_USER=${LINKDING_ADMIN_USER}
LINKDING_ADMIN_PASS=${LINKDING_ADMIN_PASS}
LINKDING_PORT_WEB=${LINKDING_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Linkding configuré"

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
    if authentik_register_app "Linkding" "linkding" "https://linkding.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

# ── Token API Linkding ────────────────────────────────────────────────────────
if [ -z "${LINKDING_API_TOKEN}" ]; then
    echo ""
    echo "→ Génération token API Linkding..."
    _ld_ready=false
    for _i in $(seq 1 20); do
        if curl -sf --max-time 3 "http://localhost:${LINKDING_PORT_WEB}/health" >/dev/null 2>&1; then
            _ld_ready=true; break
        fi
        sleep 3
    done

    if ${_ld_ready}; then
        # linkding 1.31+ utilise bookmarks_apitoken (pas DRF authtoken)
        _token=$(docker exec linkding python manage.py shell -c "
import binascii, os
from django.db import connection
from django.contrib.auth.models import User
from django.utils import timezone
u = User.objects.get(username='${LINKDING_ADMIN_USER}')
rows = connection.cursor().execute('SELECT key FROM bookmarks_apitoken WHERE user_id=?', [u.id]).fetchall()
if rows:
    print(rows[0][0])
else:
    key = binascii.hexlify(os.urandom(20)).decode()
    with connection.cursor() as c:
        c.execute('INSERT INTO bookmarks_apitoken (key, name, created, user_id) VALUES (?,?,?,?)',
                  [key, 'caleope', timezone.now().isoformat(), u.id])
    print(key)
" 2>/dev/null | tail -1) || _token=""

        if [ -n "${_token}" ]; then
            sed -i '/^LINKDING_API_TOKEN/d' "${_SECRETS}"
            echo "LINKDING_API_TOKEN=${_token}" >> "${_SECRETS}"
            echo "  ✓ Token API Linkding généré"
        else
            echo "  ⚠ Token API non obtenu (générer manuellement dans Paramètres > Intégrations)"
        fi
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Linkding est démarré.
Interface : http://<IP>:${LINKDING_PORT_WEB}
Utilisateur : ${LINKDING_ADMIN_USER}
Mot de passe : ${LINKDING_ADMIN_PASS}
INFO

echo "✓ Linkding prêt — http://<IP>:${LINKDING_PORT_WEB}"
