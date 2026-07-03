#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/home-assistant"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/home-assistant/config"

# Empty secrets.env (HA uses configuration.yaml)
cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"

# ── Trusted proxies pour Traefik + external_url ───────────────────────────────
HA_CONFIG="${CALEOPE_BASE_DIR}/app-data/home-assistant/config/configuration.yaml"
if [ ! -f "${HA_CONFIG}" ]; then
    cat > "${HA_CONFIG}" <<YAML
# Généré par Caleope
homeassistant:
  name: Ma maison
  country: FR
  language: fr
  unit_system: metric
  time_zone: Europe/Paris
  external_url: "https://${CALEOPE_DOMAIN}"
  internal_url: "https://${CALEOPE_DOMAIN}"

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

# ── OIDC Authentik via Home Assistant Auth component ──────────────────────────
# Home Assistant ne supporte pas OIDC directement dans la version de base ;
# l'intégration se fait via une application OIDC custom ou via Nabu Casa.
# → Créer quand même l'app dans Authentik pour le portail
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
        [ -n "${AK_DOMAIN}" ] || AK_DOMAIN="authentik.$(echo "${CALEOPE_DOMAIN}" | cut -d. -f2-)"
        AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null || echo "9000")
        AK_BASE="http://localhost:${AK_PORT}/api/v3"
        AK_HA="Authorization: Bearer ${AK_TOKEN}"
        AK_HJ="Content-Type: application/json"

        AUTH_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
            "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
        INVAL_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
            "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

        if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
            EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/providers/oauth2/?search=HomeAssistant" \
                | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('results',[])
if r: print(json.dumps({'pk':r[0]['pk'],'cid':r[0]['client_id'],'cs':r[0]['client_secret']}))
" 2>/dev/null || echo "")

            if [ -n "${EXISTING}" ]; then
                PROV_PK=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")
                SSO_CLIENT_ID=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['cid'])")
                SSO_CLIENT_SECRET=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['cs'])")
            else
                # HA uses /auth/oidc/callback
                REDIRECT_URI="https://${CALEOPE_DOMAIN}/auth/oidc/callback"
                PROV_RESP=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" \
                    -d "{\"name\":\"HomeAssistant\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}" \
                    2>/dev/null || echo "")
                PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
            fi

            if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/core/applications/" \
                    -d "{\"name\":\"Home Assistant\",\"slug\":\"home-assistant\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                    >/dev/null 2>&1 || true

                # Append OIDC config to HA config for reference (requires HA OIDC integration)
                cat >> "${_SECRETS}" <<OIDCENV

# OIDC Authentik (à configurer via intégration HA "OIDC")
HA_OIDC_CLIENT_ID=${SSO_CLIENT_ID}
HA_OIDC_CLIENT_SECRET=${SSO_CLIENT_SECRET}
HA_OIDC_ISSUER=https://${AK_DOMAIN}/application/o/home-assistant/
OIDCENV
                echo "  ✓ Home Assistant OIDC créé dans Authentik"
                echo "    → Configurer via : Paramètres → Utilisateurs → OIDC"
            fi
        fi
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Home Assistant — Domotique                         │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Suivez l'assistant de configuration au premier accès.           │
  │  Les trusted_proxies sont pré-configurés pour Traefik.           │
  │                                                                  │
  │  Note : Pour mDNS et intégrations réseau locales,                │
  │    utiliser network_mode: host dans docker-compose.              │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Home Assistant — Domotique                 ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL : https://${CALEOPE_DOMAIN}/"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Home Assistant configuré"
