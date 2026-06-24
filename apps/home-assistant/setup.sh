#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/home-assistant"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_APP_DATA}/home-assistant/config"

HA_PORT_WEB=""
if [ -f "${_SECRETS}" ]; then
    HA_PORT_WEB=$(grep "^HA_PORT_WEB=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_HA_PORT_WEB:-}" ] && HA_PORT_WEB="${PARAM_HA_PORT_WEB}"
[ -z "${HA_PORT_WEB}" ] && HA_PORT_WEB="8123"

cat > "${_SECRETS}" <<ENV
HA_PORT_WEB=${HA_PORT_WEB}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Home Assistant configuré"

# ── Trusted proxies pour Traefik ─────────────────────────────────────────────
# Home Assistant nécessite de déclarer les proxies de confiance dans configuration.yaml
HA_CONFIG="${CALEOPE_APP_DATA}/home-assistant/config/configuration.yaml"
if [ ! -f "${HA_CONFIG}" ]; then
    cat > "${HA_CONFIG}" <<YAML
# Généré par Caleope
homeassistant:
  name: Ma maison
  country: FR
  language: fr
  unit_system: metric
  time_zone: Europe/Paris
  external_url: "http://${CALEOPE_DOMAIN:-localhost}:${HA_PORT_WEB}"

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12
    - 10.0.0.0/8
    - 192.168.0.0/16

default_config:
YAML
    echo "  ✓ configuration.yaml créé"
fi

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
    local HA_AUTH="Authorization: Bearer ${TOKEN}"
    local HJ="Content-Type: application/json"

    local i=0
    until curl -sf --max-time 5 -H "${HA_AUTH}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 6 ] || return 1; sleep 5
    done

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA_AUTH}" "${BASE}/flows/instances/?designation=authentication" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['pk'])" 2>/dev/null) || return 1

    local APP_UUID
    APP_UUID=$(curl -sf --max-time 10 -H "${HA_AUTH}" "${BASE}/core/applications/?slug=${APP_SLUG}" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('results',[]); print(r[0]['pk'] if r else '')" 2>/dev/null) || APP_UUID=""

    if [ -z "${APP_UUID}" ]; then
        local PROV_ID
        PROV_ID=$(curl -sf --max-time 10 -X POST -H "${HA_AUTH}" -H "${HJ}" "${BASE}/providers/proxy/" \
            -d "{\"name\":\"${APP_NAME} Proxy\",\"authorization_flow\":\"${FLOW_UUID}\",\"mode\":\"forward_single\",\"external_host\":\"${APP_URL}\"}" \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['pk'])") || return 1
        curl -sf --max-time 10 -X POST -H "${HA_AUTH}" -H "${HJ}" "${BASE}/core/applications/" \
            -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROV_ID},\"meta_launch_url\":\"${APP_URL}\"}" >/dev/null || return 1
    fi

    echo "  → ${APP_NAME} enregistré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    if authentik_register_app "Home Assistant" "home-assistant" "https://ha.${CALEOPE_DOMAIN#*.}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Home Assistant est démarré.
Interface : http://<IP>:${HA_PORT_WEB}

Suivez l'assistant de configuration au premier accès pour créer votre compte.
Les trusted_proxies sont pré-configurés pour Traefik (172.16.0.0/12).

Note : Pour la découverte mDNS et les intégrations réseau locales,
un accès réseau étendu peut être nécessaire (docker network_mode: host).
INFO

echo "✓ Home Assistant prêt — http://<IP>:${HA_PORT_WEB}"
