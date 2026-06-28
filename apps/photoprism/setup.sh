#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/photoprism"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/photoprism/originals"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/photoprism/storage"

# Preserve admin password on reinstall
PHOTOPRISM_ADMIN_PASSWORD=""
if [ -f "${_SECRETS}" ]; then
    PHOTOPRISM_ADMIN_PASSWORD=$(grep "^PHOTOPRISM_ADMIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${PHOTOPRISM_ADMIN_PASSWORD}" ] && PHOTOPRISM_ADMIN_PASSWORD="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)"

cat > "${_SECRETS}" <<ENV
PHOTOPRISM_ADMIN_USER=admin
PHOTOPRISM_ADMIN_PASSWORD=${PHOTOPRISM_ADMIN_PASSWORD}
PHOTOPRISM_AUTH_MODE=password
PHOTOPRISM_SITE_URL=https://${CALEOPE_DOMAIN}/
PHOTOPRISM_ORIGINALS_LIMIT=5000
PHOTOPRISM_HTTP_COMPRESSION=gzip
PHOTOPRISM_LOG_LEVEL=info
PHOTOPRISM_READONLY=false
PHOTOPRISM_EXPERIMENTAL=false
PHOTOPRISM_DISABLE_CHOWN=false
PHOTOPRISM_DISABLE_WEBDAV=false
PHOTOPRISM_DISABLE_SETTINGS=false
PHOTOPRISM_DISABLE_TENSORFLOW=false
PHOTOPRISM_DISABLE_FACES=false
PHOTOPRISM_DISABLE_CLASSIFICATION=false
PHOTOPRISM_FFMPEG_ENCODER=software
PHOTOPRISM_DATABASE_DRIVER=sqlite
ENV
chmod 600 "${_SECRETS}"

# ── OIDC Authentik (natif PhotoPrism) ─────────────────────────────────────────
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
            REDIRECT_URI="https://${CALEOPE_DOMAIN}/api/v1/oidc/redirect"

            EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/providers/oauth2/?search=PhotoPrism" \
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
                    -d "{\"name\":\"PhotoPrism\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}" \
                    2>/dev/null || echo "")
                PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
            fi

            if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/core/applications/" \
                    -d "{\"name\":\"PhotoPrism\",\"slug\":\"photoprism\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                    >/dev/null 2>&1 || true

                cat >> "${_SECRETS}" <<OIDCENV

# OIDC Authentik (natif PhotoPrism)
PHOTOPRISM_OIDC_CLIENT_ID=${SSO_CLIENT_ID}
PHOTOPRISM_OIDC_CLIENT_SECRET=${SSO_CLIENT_SECRET}
PHOTOPRISM_OIDC_ISSUER_URL=https://${AK_DOMAIN}/application/o/photoprism/
PHOTOPRISM_OIDC_REGISTER=true
PHOTOPRISM_OIDC_USERNAME=preferred_username
PHOTOPRISM_OIDC_WEBDAV=false
OIDCENV
                echo "  ✓ PhotoPrism OIDC configuré dans Authentik"
            fi
        fi
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               PhotoPrism — Gestionnaire de photos                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Login : admin                                                   │
  │  Pass  : ${PHOTOPRISM_ADMIN_PASSWORD}                            │
  │    → Changer dans Settings → Account                             │
  │                                                                  │
  │  Photos à placer dans :                                          │
  │    ${CALEOPE_BASE_DIR}/app-data/photoprism/originals/            │
  │                                                                  │
  │  Indexation : Library → Index                                    │
  │                                                                  │
  │  SSO Authentik (OIDC natif) :                                    │
  │    → Bouton "Sign in with OpenID Connect" sur la page de         │
  │      connexion                                                   │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           PhotoPrism — Gestionnaire de photos        ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL   : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login : admin"
echo "  ║  Pass  : ${PHOTOPRISM_ADMIN_PASSWORD}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ PhotoPrism configuré"
