#!/bin/bash
# AdGuard Home setup — génère les secrets et configure AdGuard Home via son API
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/adguard"
_SECRETS="${CONFIG_DIR}/secrets.env"

# ── Credentials ───────────────────────────────────────────────────────────────
ADGUARD_USERNAME="admin"
ADGUARD_PASSWORD=""
ADGUARD_DNS1="1.1.1.1"
ADGUARD_DNS2="1.0.0.1"

if [ -f "${_SECRETS}" ]; then
    _PREV_USER=$(grep "^ADGUARD_USERNAME=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_USER=""
    _PREV_PASS=$(grep "^ADGUARD_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_PASS=""
    _PREV_DNS1=$(grep "^ADGUARD_DNS1="    "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_DNS1=""
    _PREV_DNS2=$(grep "^ADGUARD_DNS2="    "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_DNS2=""
    [ -n "${_PREV_USER}" ] && ADGUARD_USERNAME="${_PREV_USER}"
    [ -n "${_PREV_PASS}" ] && ADGUARD_PASSWORD="${_PREV_PASS}"
    [ -n "${_PREV_DNS1}" ] && ADGUARD_DNS1="${_PREV_DNS1}"
    [ -n "${_PREV_DNS2}" ] && ADGUARD_DNS2="${_PREV_DNS2}"
fi

[ -n "${CALEOPE_PARAM_ADGUARD_USERNAME:-}" ] && ADGUARD_USERNAME="${CALEOPE_PARAM_ADGUARD_USERNAME}"
[ -n "${CALEOPE_PARAM_ADGUARD_PASSWORD:-}" ] && ADGUARD_PASSWORD="${CALEOPE_PARAM_ADGUARD_PASSWORD}"
[ -n "${CALEOPE_PARAM_ADGUARD_DNS1:-}"     ] && ADGUARD_DNS1="${CALEOPE_PARAM_ADGUARD_DNS1}"
[ -n "${CALEOPE_PARAM_ADGUARD_DNS2:-}"     ] && ADGUARD_DNS2="${CALEOPE_PARAM_ADGUARD_DNS2}"

[ -z "${ADGUARD_PASSWORD}" ] && \
    ADGUARD_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-16)

mkdir -p "${CONFIG_DIR}"
cat > "${_SECRETS}" << ENV
ADGUARD_USERNAME=${ADGUARD_USERNAME}
ADGUARD_PASSWORD=${ADGUARD_PASSWORD}
ADGUARD_DNS1=${ADGUARD_DNS1}
ADGUARD_DNS2=${ADGUARD_DNS2}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Secrets AdGuard Home générés"

# ── Configuration initiale via API (setup automatique) ───────────────────────
_AG_PORT="${ADGUARD_PORT_WEB:-3080}"
_AG_URL="http://localhost:${_AG_PORT}"

echo ""
echo "→ Attente démarrage AdGuard Home..."
_ag_started=false
for _i in $(seq 1 20); do
    if curl -sf "${_AG_URL}" >/dev/null 2>&1; then
        _ag_started=true
        break
    fi
    sleep 3
done

if ${_ag_started}; then
    # Vérifie si l'installation initiale est nécessaire
    _install_needed=$(curl -sf "${_AG_URL}/control/install/check_config" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('web',{}).get('status','ok'))" 2>/dev/null) || _install_needed="ok"

    if [ "${_install_needed}" != "ok" ] || curl -sf "${_AG_URL}/control/status" \
        -H "Authorization: Basic $(echo -n "${ADGUARD_USERNAME}:${ADGUARD_PASSWORD}" | base64)" >/dev/null 2>&1; then
        echo "  ℹ AdGuard Home déjà configuré"
    else
        echo "  → Configuration initiale AdGuard Home..."
        # Hash bcrypt du mot de passe
        _PASS_HASH=$(python3 -c "
import subprocess, sys
try:
    import bcrypt
    h = bcrypt.hashpw('${ADGUARD_PASSWORD}'.encode(), bcrypt.gensalt()).decode()
    print(h)
except:
    sys.exit(1)
" 2>/dev/null) || _PASS_HASH=""

        if [ -n "${_PASS_HASH}" ]; then
            curl -sf -X POST "${_AG_URL}/control/install/configure" \
                -H "Content-Type: application/json" \
                -d "{
                    \"web\": {\"ip\": \"0.0.0.0\", \"port\": 3000},
                    \"dns\": {\"ip\": \"0.0.0.0\", \"port\": 53},
                    \"username\": \"${ADGUARD_USERNAME}\",
                    \"password\": \"${_PASS_HASH}\"
                }" >/dev/null 2>&1 && echo "  ✓ AdGuard Home configuré" || echo "  ⚠ Configuration initiale échouée (à faire manuellement)"
        else
            echo "  ⚠ bcrypt non disponible — configuration manuelle requise"
            echo "    Accéder à http://<IP>:${_AG_PORT} et configurer manuellement"
        fi
    fi

    # Configuration des DNS upstream
    echo "  → Configuration DNS upstream ${ADGUARD_DNS1} / ${ADGUARD_DNS2}..."
    _AUTH="Authorization: Basic $(echo -n "${ADGUARD_USERNAME}:${ADGUARD_PASSWORD}" | base64)"
    curl -sf -X POST "${_AG_URL}/control/dns_config" \
        -H "Content-Type: application/json" \
        -H "${_AUTH}" \
        -d "{\"upstream_dns\": [\"${ADGUARD_DNS1}\", \"${ADGUARD_DNS2}\"], \"bootstrap_dns\": [\"9.9.9.9\"]}" \
        >/dev/null 2>&1 && echo "  ✓ DNS upstream configurés" || true
else
    echo "  ⚠ AdGuard Home non joignable — configuration manuelle requise"
fi

# ── Post-install info ─────────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/post-install.txt" << INFO
AdGuard Home est démarré.
Interface admin : http://<IP>:${_AG_PORT}
Utilisateur : ${ADGUARD_USERNAME}
Mot de passe : ${ADGUARD_PASSWORD}

Pour utiliser AdGuard Home comme DNS sur votre réseau :
  Configurer l'IP de ce serveur comme DNS sur vos routeurs/clients.
  Port DNS : 53
INFO

echo "  ✓ AdGuard Home configuré — admin : http://<IP>:${_AG_PORT}"
