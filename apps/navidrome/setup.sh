#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/navidrome"
_SECRETS="${CONFIG_DIR}/secrets.env"
_MUSIC_DIR="${CALEOPE_BASE_DIR}/app-data/navidrome/music"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/navidrome/data"
mkdir -p "${_MUSIC_DIR}"
chown -R 1000:1000 "${CALEOPE_BASE_DIR}/app-data/navidrome" 2>/dev/null || true

cat > "${_SECRETS}" <<ENV
ND_MUSICFOLDER=/music
ND_DATAFOLDER=/data
ND_LOGLEVEL=info
ND_SESSIONTIMEOUT=24h
ND_BASEURL=
ENV
chmod 600 "${_SECRETS}"

# ── OIDC Authentik (natif Navidrome >= 0.52) ──────────────────────────────────
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
            REDIRECT_URI="https://${CALEOPE_DOMAIN}/auth/callback"

            EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/providers/oauth2/?search=Navidrome" \
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
                PROV_RESP=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" \
                    -d "{\"name\":\"Navidrome\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}" \
                    2>/dev/null || echo "")
                PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
            fi

            if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/core/applications/" \
                    -d "{\"name\":\"Navidrome\",\"slug\":\"navidrome\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                    >/dev/null 2>&1 || true

                cat >> "${_SECRETS}" <<OIDCENV

# OIDC Authentik (natif Navidrome)
ND_OIDCENABLED=true
ND_OIDCISSUER=https://${AK_DOMAIN}/application/o/navidrome/
ND_OIDCCLIENTID=${SSO_CLIENT_ID}
ND_OIDCCLIENTSECRET=${SSO_CLIENT_SECRET}
ND_OIDCSCOPES=openid profile email
ND_OIDCREDIRECTURL=https://${CALEOPE_DOMAIN}/auth/callback
OIDCENV
                echo "  ✓ Navidrome OIDC configuré dans Authentik"
            fi
        fi
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Navidrome — Serveur de musique                     │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Premier accès : créer un compte admin via le wizard             │
  │                                                                  │
  │  Musique à placer dans :                                         │
  │    ${_MUSIC_DIR}/                                                │
  │                                                                  │
  │  Compatible clients Subsonic (DSub, Symfonium, Ultrasonic…)      │
  │    URL serveur : https://${CALEOPE_DOMAIN}/                      │
  │                                                                  │
  │  SSO Authentik (OIDC natif) :                                    │
  │    → Bouton "Login with Authentik" sur la page de connexion      │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Navidrome — Serveur de musique             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL    : https://${CALEOPE_DOMAIN}/"
echo "  ║  Musique: ${_MUSIC_DIR}/"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Navidrome configuré"
