#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/wikijs/db"

# ── Préserver les secrets existants ───────────────────────────────────────────
DB_PASSWORD=""
JWT_SECRET=""
ADMIN_PASSWORD=""
ADMIN_EMAIL=""
if [ -f "${CONFIG_DIR}/secrets.env" ]; then
    DB_PASSWORD=$(grep "^POSTGRES_PASSWORD=" "${CONFIG_DIR}/secrets.env" | cut -d= -f2-) || true
    JWT_SECRET=$(grep  "^JWT_SECRET="         "${CONFIG_DIR}/secrets.env" | cut -d= -f2-) || true
    ADMIN_PASSWORD=$(grep "^WIKIJS_ADMIN_PASSWORD=" "${CONFIG_DIR}/secrets.env" | cut -d= -f2-) || true
    ADMIN_EMAIL=$(grep    "^WIKIJS_ADMIN_EMAIL="    "${CONFIG_DIR}/secrets.env" | cut -d= -f2-) || true
fi

[ -z "${DB_PASSWORD}"    ] && DB_PASSWORD=$(openssl rand -hex 24)
[ -z "${JWT_SECRET}"     ] && JWT_SECRET=$(openssl rand -hex 32)
[ -z "${ADMIN_PASSWORD}" ] && ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 14)
[ -z "${ADMIN_EMAIL}"    ] && ADMIN_EMAIL="admin@${CALEOPE_DOMAIN}"

cat > "${CONFIG_DIR}/secrets.env" <<EOF
# PostgreSQL
POSTGRES_DB=wiki
POSTGRES_USER=wiki
POSTGRES_PASSWORD=${DB_PASSWORD}

# Wiki.js
DB_TYPE=postgres
DB_HOST=wikijs-db
DB_PORT=5432
DB_USER=wiki
DB_PASS=${DB_PASSWORD}
DB_NAME=wiki
APP_URL=https://${CALEOPE_DOMAIN}
JWT_SECRET=${JWT_SECRET}
WIKIJS_ADMIN_EMAIL=${ADMIN_EMAIL}
WIKIJS_ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── Auto-setup Wiki.js (finalize + API key) ───────────────────────────────────
_WK_URL="http://localhost:${CALEOPE_PORT_WEB}"

echo ""
echo "→ Attente démarrage Wiki.js (max 90s)..."
_wk_ready=false
for _i in $(seq 1 30); do
    if curl -sf --max-time 3 "${_WK_URL}" >/dev/null 2>&1; then
        _wk_ready=true
        break
    fi
    sleep 3
done

if ${_wk_ready}; then
    _needs_setup=$(curl -sf --max-time 5 "${_WK_URL}/finalize" -o /dev/null -w "%{http_code}") || _needs_setup="000"
    _existing_jwt=$(grep "^WIKIJS_API_TOKEN=" "${CONFIG_DIR}/secrets.env" 2>/dev/null | cut -d= -f2-) || _existing_jwt=""

    if [ "${_needs_setup}" = "200" ] && [ -z "${_existing_jwt}" ]; then
        echo "  → Finalisation Wiki.js (création compte admin)..."
        _finalize_result=$(curl -sf --max-time 15 -X POST "${_WK_URL}/finalize" \
            -H "Content-Type: application/json" \
            -d "{
                \"adminEmail\": \"${ADMIN_EMAIL}\",
                \"adminPassword\": \"${ADMIN_PASSWORD}\",
                \"adminPasswordConfirm\": \"${ADMIN_PASSWORD}\",
                \"siteUrl\": \"https://${CALEOPE_DOMAIN}\",
                \"telemetry\": false
            }" 2>/dev/null) || _finalize_result=""

        if echo "${_finalize_result}" | grep -q '"ok":true'; then
            echo "  ✓ Compte admin créé (${ADMIN_EMAIL})"
            sleep 3
        else
            echo "  ⚠ Finalisation échouée ou déjà effectuée : ${_finalize_result}" | head -c 200
        fi
    fi

    # Créer la clé API CaleOpe si absente
    if [ -z "${_existing_jwt}" ]; then
        echo "  → Création clé API CaleOpe..."
        _login_resp=$(curl -sf --max-time 10 -X POST "${_WK_URL}/graphql" \
            -H "Content-Type: application/json" \
            -d "{\"query\":\"mutation { authentication { login(username: \\\"${ADMIN_EMAIL}\\\", password: \\\"${ADMIN_PASSWORD}\\\", strategy: \\\"local\\\") { jwt responseResult { succeeded message } } } }\"}" 2>/dev/null) || _login_resp=""

        _wk_jwt=$(echo "${_login_resp}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['authentication']['login']['jwt'])" 2>/dev/null) || _wk_jwt=""

        if [ -n "${_wk_jwt}" ]; then
            curl -sf --max-time 10 -X POST "${_WK_URL}/graphql" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${_wk_jwt}" \
                -d '{"query":"mutation { authentication { setApiState(enabled: true) { responseResult { succeeded } } } }"}' >/dev/null 2>&1 || true

            _api_resp=$(curl -sf --max-time 10 -X POST "${_WK_URL}/graphql" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${_wk_jwt}" \
                -d "{\"query\":\"mutation { authentication { createApiKey(name: \\\"CaleOpe\\\", expiration: \\\"87600h\\\", fullAccess: true, group: 1) { responseResult { succeeded message } key } } }\"}" 2>/dev/null) || _api_resp=""

            _api_key=$(echo "${_api_resp}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['authentication']['createApiKey']['key'])" 2>/dev/null) || _api_key=""

            if [ -n "${_api_key}" ]; then
                sed -i '/^WIKIJS_API_TOKEN/d' "${CONFIG_DIR}/secrets.env"
                echo "WIKIJS_API_TOKEN=${_api_key}" >> "${CONFIG_DIR}/secrets.env"
                echo "  ✓ Clé API Wiki.js générée et sauvegardée"
            else
                echo "  ⚠ Création clé API échouée — ajouter manuellement"
            fi
        else
            echo "  ⚠ Login Wiki.js échoué — compte admin à créer manuellement"
        fi
    else
        echo "  ℹ Clé API Wiki.js déjà présente"
    fi

    # ── OIDC Authentik (natif Wiki.js) ────────────────────────────────────────
    # Wiki.js v2 supporte nativement OIDC via stratégie "oidc"
    # → pas de ForwardAuth, pas de proxy, SSO direct
    _wk_jwt_for_oidc="${_wk_jwt:-}"
    if [ -z "${_wk_jwt_for_oidc}" ]; then
        _login_resp2=$(curl -sf --max-time 10 -X POST "${_WK_URL}/graphql" \
            -H "Content-Type: application/json" \
            -d "{\"query\":\"mutation { authentication { login(username: \\\"${ADMIN_EMAIL}\\\", password: \\\"${ADMIN_PASSWORD}\\\", strategy: \\\"local\\\") { jwt } } }\"}" 2>/dev/null) || _login_resp2=""
        _wk_jwt_for_oidc=$(echo "${_login_resp2}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['authentication']['login']['jwt'])" 2>/dev/null) || _wk_jwt_for_oidc=""
    fi

    if [ -n "${_wk_jwt_for_oidc}" ] && [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
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
                REDIRECT_URI="https://${CALEOPE_DOMAIN}/login/oidc/callback"

                EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                    "${AK_BASE}/providers/oauth2/?search=Wikijs" \
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
                        -d "{\"name\":\"Wikijs\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}" \
                        2>/dev/null || echo "")
                    PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                    SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                    SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
                fi

                if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                    APP_SLUG=$(curl -s --max-time 10 -H "${AK_HA}" \
                        "${AK_BASE}/core/applications/" \
                        | python3 -c "
import sys,json
d=json.load(sys.stdin)
pk=int('${PROV_PK}')
r=[a for a in d.get('results',[]) if a.get('provider')==pk]
print(r[0]['slug'] if r else '')
" 2>/dev/null || echo "")

                    if [ -z "${APP_SLUG}" ]; then
                        APP_RESP=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                            "${AK_BASE}/core/applications/" \
                            -d "{\"name\":\"Wiki.js\",\"slug\":\"wikijs\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                            2>/dev/null || echo "")
                        APP_SLUG=$(echo "${APP_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug','wikijs'))" 2>/dev/null || echo "wikijs")
                    fi

                    # Configurer la stratégie OIDC dans Wiki.js via GraphQL
                    ISSUER="https://${AK_DOMAIN}/application/o/${APP_SLUG}/"
                    _OIDC_PAYLOAD=$(python3 -c "
import json
config = [
    {'key': 'issuer',        'value': json.dumps({'v': '${ISSUER}'})},
    {'key': 'clientId',      'value': json.dumps({'v': '${SSO_CLIENT_ID}'})},
    {'key': 'clientSecret',  'value': json.dumps({'v': '${SSO_CLIENT_SECRET}'})},
    {'key': 'callbackURL',   'value': json.dumps({'v': 'https://${CALEOPE_DOMAIN}/login/oidc/callback'})},
    {'key': 'emailClaim',    'value': json.dumps({'v': 'email'})},
    {'key': 'usernameClaim', 'value': json.dumps({'v': 'preferred_username'})},
    {'key': 'scope',         'value': json.dumps({'v': 'openid profile email'})},
    {'key': 'authorizationURL', 'value': json.dumps({'v': ''})},
    {'key': 'tokenURL',         'value': json.dumps({'v': ''})},
    {'key': 'userInfoURL',      'value': json.dumps({'v': ''})},
    {'key': 'jwksURL',          'value': json.dumps({'v': ''})},
    {'key': 'logoutRedirectURL','value': json.dumps({'v': ''})},
    {'key': 'enableUserProfile','value': json.dumps({'v': True})},
    {'key': 'enableGroups',     'value': json.dumps({'v': False})},
    {'key': 'groupsClaim',      'value': json.dumps({'v': 'groups'})},
    {'key': 'mapGroups',        'value': json.dumps({'v': False})},
    {'key': 'adminGroup',       'value': json.dumps({'v': ''})},
]
q = '''mutation {
  authentication {
    updateStrategies(strategies: [
      {
        key: \"oidc\",
        strategyKey: \"oidc\",
        displayName: \"Authentik\",
        enabled: true,
        selfRegistration: true,
        config: ''' + json.dumps(config) + '''
      }
    ]) {
      responseResult { succeeded errorCode message }
    }
  }
}'''
print(json.dumps({'query': q}))
" 2>/dev/null || echo "")

                    if [ -n "${_OIDC_PAYLOAD}" ]; then
                        _oidc_resp=$(curl -sf --max-time 15 -X POST "${_WK_URL}/graphql" \
                            -H "Content-Type: application/json" \
                            -H "Authorization: Bearer ${_wk_jwt_for_oidc}" \
                            -d "${_OIDC_PAYLOAD}" 2>/dev/null) || _oidc_resp=""
                        if echo "${_oidc_resp}" | grep -q '"succeeded":true'; then
                            echo "  ✓ OIDC Authentik configuré dans Wiki.js (issuer=${ISSUER})"
                        else
                            echo "  ⚠ Configuration OIDC Wiki.js: ${_oidc_resp}" | head -c 300
                        fi
                    fi
                    echo "  ✓ Authentik OIDC (slug=${APP_SLUG}, client_id=${SSO_CLIENT_ID})"
                fi
            fi
        fi
    fi
else
    echo "  ⚠ Wiki.js non joignable — configuration manuelle requise"
    echo "    1. Aller sur https://${CALEOPE_DOMAIN}/ → finaliser le wizard"
    echo "    2. Admin → Authentication → OIDC → configurer avec Authentik"
fi

# post-install.txt
cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════╗
║              Wiki.js — Premiers accès                        ║
╠══════════════════════════════════════════════════════════════╣
║  URL          : https://${CALEOPE_DOMAIN}                    ║
║  Admin email  : ${ADMIN_EMAIL}                               ║
║  Admin pass   : ${ADMIN_PASSWORD}                            ║
╠══════════════════════════════════════════════════════════════╣
║  SSO Authentik (OIDC natif) :                                ║
║    → Bouton "Login with Authentik" sur la page de connexion  ║
║    → Configurable dans Admin → Authentication → OIDC         ║
╠══════════════════════════════════════════════════════════════╣
║  SYNCHRONISATION GITHUB (optionnel) :                        ║
║    Administration → Storage → Git → Enable                   ║
║    Repo : github.com/Gaiver-IT/caleope (branche: main)       ║
║    Répertoire local : docs                                   ║
║    Token : Personal Access Token GitHub (scope: repo)        ║
╚══════════════════════════════════════════════════════════════╝

Secrets sauvegardés dans : ${CONFIG_DIR}/secrets.env
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              Wiki.js — Accès                         ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL   : https://${CALEOPE_DOMAIN}/"
echo "  ║  Email : ${ADMIN_EMAIL}"
echo "  ║  Pass  : ${ADMIN_PASSWORD}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Wiki.js préparé"
