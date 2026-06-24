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

# Écrire secrets.env (fusionné dans app.env par Caleope)
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

    echo "  → Connexion à l'API Authentik (max 60s)..."
    local i=0
    until curl -sf --max-time 5 -H "${HA}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 12 ] || { echo "  ⚠ Authentik non joignable"; return 1; }
        sleep 5
    done

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || { echo "  ⚠ Flow Authentik introuvable"; return 1; }

    local PROVIDER_PK
    PROVIDER_PK=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/providers/proxy/" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = [p for p in d.get('results',[]) if p['name']==\"${APP_NAME}\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -z "${PROVIDER_PK}" ]; then
        PROVIDER_PK=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
            "${BASE}/providers/proxy/" \
            -d "{\"name\":\"${APP_NAME}\",\"authorization_flow\":\"${FLOW_UUID}\",\"external_host\":\"${APP_URL}\",\"mode\":\"forward_single\"}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "  ⚠ Erreur création Provider"; return 1; }

    curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
        "${BASE}/core/applications/" \
        -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROVIDER_PK}}" \
        >/dev/null 2>&1 || true

    local OUTPOST_UUID CURRENT_PROVIDERS NEW_PROVIDERS
    OUTPOST_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

    if [ -n "${OUTPOST_UUID}" ]; then
        CURRENT_PROVIDERS=$(curl -sf --max-time 10 -H "${HA}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('providers',[])))" 2>/dev/null || echo "[]")
        NEW_PROVIDERS=$(echo "${CURRENT_PROVIDERS}" | python3 -c "
import sys, json
l = json.load(sys.stdin)
if ${PROVIDER_PK} not in l: l.append(${PROVIDER_PK})
print(json.dumps(l))
" 2>/dev/null || echo "[${PROVIDER_PK}]")
        curl -sf --max-time 10 -X PATCH -H "${HA}" -H "${HJ}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            -d "{\"providers\":${NEW_PROVIDERS}}" >/dev/null 2>&1 || true
    fi

    echo "  → ${APP_NAME} enregistré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    if authentik_register_app "Wiki.js" "wikijs" "https://${CALEOPE_DOMAIN}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    else
        echo "  ⚠ ForwardAuth désactivé (enregistrement Authentik échoué)"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${CONFIG_DIR}/secrets.env"

# ── Auto-setup Wiki.js (finalize + API key) ───────────────────────────────────
_WK_PORT="3000"
_WK_URL="http://localhost:8000"

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
    # Vérifier si le wizard de finalisation est encore nécessaire
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
            sleep 2
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
            # Activer l'API (désactivée par défaut)
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
                echo "  ⚠ Création clé API échouée — ajouter manuellement WIKIJS_API_TOKEN"
            fi
        else
            echo "  ⚠ Login Wiki.js échoué — clé API à créer manuellement"
        fi
    else
        echo "  ℹ Clé API Wiki.js déjà présente"
    fi
else
    echo "  ⚠ Wiki.js non joignable — clé API à créer manuellement"
    echo "    1. Aller sur http://<IP>:8000 → Admin → Developer Tools → API Access"
    echo "    2. Créer une clé et l'ajouter dans secrets.env : WIKIJS_API_TOKEN=<clé>"
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
║  L'admin est créé automatiquement — pas de wizard.           ║
║                                                              ║
║  Activer lecture publique (optionnel) :                      ║
║    Administration → Groups → Guests                          ║
║    → cocher "read:pages" et "read:assets"                    ║
╠══════════════════════════════════════════════════════════════╣
║  SYNCHRONISATION GITHUB (optionnel) :                        ║
║    Administration → Storage → Git → Enable                   ║
║    Repo : github.com/Gaiver-IT/caleope (branche: main)       ║
║    Répertoire local : docs                                   ║
║    Token : Personal Access Token GitHub (scope: repo)        ║
╚══════════════════════════════════════════════════════════════╝

Secrets sauvegardés dans : ${CONFIG_DIR}/secrets.env
EOF

echo "✓ Wiki.js préparé"
