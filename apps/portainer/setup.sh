#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/portainer"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/portainer/data"

PORTAINER_PORT_WEB=""
PORTAINER_ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    PORTAINER_PORT_WEB=$(grep  "^PORTAINER_PORT_WEB="   "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    PORTAINER_ADMIN_PASS=$(grep "^PORTAINER_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${CALEOPE_PARAM_PORTAINER_PORT_WEB:-}" ] && PORTAINER_PORT_WEB="${CALEOPE_PARAM_PORTAINER_PORT_WEB}"
[ -z "${PORTAINER_PORT_WEB}"   ] && PORTAINER_PORT_WEB="9000"
[ -z "${PORTAINER_ADMIN_PASS}" ] && PORTAINER_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

cat > "${_SECRETS}" <<ENV
PORTAINER_PORT_WEB=${PORTAINER_PORT_WEB}
PORTAINER_ADMIN_PASS=${PORTAINER_ADMIN_PASS}
ENV
chmod 600 "${_SECRETS}"

# ── Init admin via API ────────────────────────────────────────────────────────
echo ""
echo "→ Attente démarrage Portainer (max 60s)..."
_pt_ready=false
for _i in $(seq 1 20); do
    if curl -sf --max-time 3 "http://localhost:${PORTAINER_PORT_WEB}/api/system/status" >/dev/null 2>&1; then
        _pt_ready=true
        break
    fi
    sleep 3
done

if ${_pt_ready}; then
    _status=$(curl -sf --max-time 5 "http://localhost:${PORTAINER_PORT_WEB}/api/system/status" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Edition',''))" 2>/dev/null) || _status=""

    _existing_token=$(grep "^PORTAINER_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _existing_token=""

    if [ -z "${_existing_token}" ]; then
        echo "  → Initialisation compte admin Portainer..."
        _init_resp=$(curl -sf --max-time 10 -X POST \
            "http://localhost:${PORTAINER_PORT_WEB}/api/users/admin/init" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"${PORTAINER_ADMIN_PASS}\"}" 2>/dev/null) || _init_resp=""

        if echo "${_init_resp}" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'Id' in d else 1)" 2>/dev/null; then
            echo "  ✓ Admin créé"
        fi

        # Générer un API token
        _login_resp=$(curl -sf --max-time 10 -X POST \
            "http://localhost:${PORTAINER_PORT_WEB}/api/auth" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"${PORTAINER_ADMIN_PASS}\"}" 2>/dev/null) || _login_resp=""

        _jwt=$(echo "${_login_resp}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('jwt',''))" 2>/dev/null) || _jwt=""

        if [ -n "${_jwt}" ]; then
            _token_resp=$(curl -sf --max-time 10 -X POST \
                "http://localhost:${PORTAINER_PORT_WEB}/api/users/me/tokens" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${_jwt}" \
                -d "{\"description\":\"CaleOpe\",\"password\":\"${PORTAINER_ADMIN_PASS}\"}" 2>/dev/null) || _token_resp=""

            _api_token=$(echo "${_token_resp}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('rawAPIKey',''))" 2>/dev/null) || _api_token=""

            if [ -n "${_api_token}" ]; then
                sed -i '/^PORTAINER_API_TOKEN/d' "${_SECRETS}"
                echo "PORTAINER_API_TOKEN=${_api_token}" >> "${_SECRETS}"
                echo "  ✓ Token API Portainer généré"
            fi
        fi
    else
        echo "  ℹ Portainer déjà configuré"
    fi
else
    echo "  ⚠ Portainer non joignable — config manuelle"
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Portainer CE est démarré.
Interface : http://<IP>:${PORTAINER_PORT_WEB}
Utilisateur admin : admin
Mot de passe      : ${PORTAINER_ADMIN_PASS}
INFO

echo "✓ Portainer prêt — http://<IP>:${PORTAINER_PORT_WEB}"
