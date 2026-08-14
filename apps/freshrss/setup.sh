#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/freshrss"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/freshrss"/{data,extensions}

# Une montée de version passe par « caleope install freshrss --force », donc par
# ce script : tout secret réengendré ici est réécrit dans secrets.env alors que
# l'app (ou le fournisseur SSO) garde encore l'ancien → elle se coupe de ses
# données. On relit donc la valeur déjà en place et on ne l'engendre que la
# première fois.
# $1 = clé TELLE QU'ÉCRITE dans secrets.env, $2 = commande d'engendrement.
_garde() {
    local cur=""
    if [ -f "${_SECRETS}" ]; then
        cur=$(grep -m1 "^$1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- || true) || cur=""
    fi
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; else eval "$2"; fi
}

FRESHRSS_ADMIN_USER=""
FRESHRSS_ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    FRESHRSS_ADMIN_USER=$(grep "^FRESHRSS_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    FRESHRSS_ADMIN_PASS=$(grep "^FRESHRSS_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

[ -n "${CALEOPE_PARAM_FRESHRSS_ADMIN_USER:-}" ] && FRESHRSS_ADMIN_USER="${CALEOPE_PARAM_FRESHRSS_ADMIN_USER}"
[ -n "${CALEOPE_PARAM_FRESHRSS_ADMIN_PASS:-}" ] && FRESHRSS_ADMIN_PASS="${CALEOPE_PARAM_FRESHRSS_ADMIN_PASS}"
[ -z "${FRESHRSS_ADMIN_USER}" ] && FRESHRSS_ADMIN_USER="admin"
[ -z "${FRESHRSS_ADMIN_PASS}" ] && FRESHRSS_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

# OIDC_CLIENT_CRYPTO_KEY et OIDC_REMOTE_USER_CLAIM sont requis par le config Apache
# même quand OIDC_ENABLED=0 — Apache les évalue au parse et échoue s'ils sont absents.
# Cette clé chiffre les cookies/sessions mod_auth_openidc : la réengendrer à chaque
# --force invalide les sessions SSO en cours et casse la connexion Authentik → on garde
# celle déjà écrite dans secrets.env si elle existe.
OIDC_CRYPTO_KEY=$(_garde OIDC_CLIENT_CRYPTO_KEY "openssl rand -hex 32")

cat > "${_SECRETS}" <<ENV
FRESHRSS_ADMIN_USER=${FRESHRSS_ADMIN_USER}
FRESHRSS_ADMIN_PASS=${FRESHRSS_ADMIN_PASS}

# Requis par Apache mod_auth_openidc (même sans OIDC actif)
OIDC_ENABLED=0
OIDC_CLIENT_ID=
OIDC_CLIENT_SECRET=
OIDC_PROVIDER_METADATA_URL=
OIDC_CLIENT_CRYPTO_KEY=${OIDC_CRYPTO_KEY}
OIDC_REMOTE_USER_CLAIM=preferred_username
OIDC_SCOPES=openid email profile
OIDC_X_FORWARDED_HEADERS=X-Forwarded-Host X-Forwarded-Port X-Forwarded-Proto
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ FreshRSS configuré"

# ── OIDC Authentik (natif FreshRSS) ──────────────────────────────────────────
# FreshRSS supporte nativement OIDC via le plugin OIDC / variables d'env.
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-) || true
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-) || true
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
            REDIRECT_URI="https://${CALEOPE_DOMAIN}/i/oidc/callback"

            EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/providers/oauth2/?search=FreshRSS" \
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
                    -d "{\"name\":\"FreshRSS\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}" \
                    2>/dev/null || echo "")
                PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
            fi

            if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/core/applications/" \
                    -d "{\"name\":\"FreshRSS\",\"slug\":\"freshrss\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                    >/dev/null 2>&1 || true

                # mod_auth_openidc (Apache) récupère la discovery OIDC côté serveur
                # à CHAQUE requête. Si l'endpoint n'est pas joignable en HTTPS depuis
                # ce serveur (réseau sans NAT reflection / hairpin KO), Apache renvoie
                # 500 sur TOUTE la page. On teste donc la joignabilité depuis l'hôte :
                # joignable → SSO activé ; sinon → login local (OIDC_ENABLED=0) au lieu
                # de casser l'app. Réactivable dans secrets.env une fois le réseau OK.
                METADATA_URL="https://${AK_DOMAIN}/application/o/freshrss/.well-known/openid-configuration"
                if curl -skf --max-time 8 "${METADATA_URL}" >/dev/null 2>&1; then
                    _OIDC_ENABLED=1
                    _OIDC_MSG="  ✓ FreshRSS OIDC (SSO Authentik) activé"
                else
                    _OIDC_ENABLED=0
                    _OIDC_MSG="  ⚠ Authentik injoignable en HTTPS depuis ce serveur (NAT reflection ?) — SSO désactivé, login local. Provider créé côté Authentik ; passez OIDC_ENABLED=1 dans app-config/freshrss/secrets.env quand le réseau le permet."
                fi
                # Réécrire secrets.env (OIDC activé seulement si joignable)
                cat > "${_SECRETS}" <<OIDCENV
FRESHRSS_ADMIN_USER=${FRESHRSS_ADMIN_USER}
FRESHRSS_ADMIN_PASS=${FRESHRSS_ADMIN_PASS}

# OIDC Authentik (natif FreshRSS via mod_auth_openidc)
OIDC_ENABLED=${_OIDC_ENABLED}
OIDC_CLIENT_ID=${SSO_CLIENT_ID}
OIDC_CLIENT_SECRET=${SSO_CLIENT_SECRET}
OIDC_PROVIDER_METADATA_URL=${METADATA_URL}
OIDC_CLIENT_CRYPTO_KEY=${OIDC_CRYPTO_KEY}
OIDC_REMOTE_USER_CLAIM=preferred_username
OIDC_SCOPES=openid email profile
OIDC_X_FORWARDED_HEADERS=X-Forwarded-Host X-Forwarded-Port X-Forwarded-Proto
OIDCENV
                echo "${_OIDC_MSG}"
            fi
        fi
    fi
fi

# ── Token API FreshRSS (Google Reader API) ────────────────────────────────────
_existing_token=$(grep "^FRESHRSS_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _existing_token=""

if [ -z "${_existing_token}" ]; then
    echo ""
    echo "→ Attente démarrage FreshRSS (max 60s)..."
    for _i in $(seq 1 20); do
        if curl -sf --max-time 3 "http://localhost:${CALEOPE_PORT_WEB}/" >/dev/null 2>&1; then
            # Activer l'API dans les settings FreshRSS
            docker exec freshrss php /var/www/FreshRSS/cli/update-user.php \
                --user "${FRESHRSS_ADMIN_USER}" \
                --api_password "${FRESHRSS_ADMIN_PASS}" 2>/dev/null || true

            _token_resp=$(curl -sf --max-time 10 -X POST \
                "http://localhost:${CALEOPE_PORT_WEB}/api/greader.php/accounts/ClientLogin" \
                -d "Email=${FRESHRSS_ADMIN_USER}&Passwd=${FRESHRSS_ADMIN_PASS}" 2>/dev/null) || _token_resp=""

            _api_token=$(echo "${_token_resp}" | grep "^Auth=" | cut -d= -f2-) || _api_token=""

            if [ -n "${_api_token}" ]; then
                sed -i '/^FRESHRSS_API_TOKEN/d' "${_SECRETS}"
                echo "FRESHRSS_API_TOKEN=${_api_token}" >> "${_SECRETS}"
                echo "  ✓ Token API FreshRSS (Google Reader) généré"
            fi
            break
        fi
        sleep 3
    done
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                  FreshRSS — Agrégateur de flux RSS               │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface    : https://${CALEOPE_DOMAIN}/                       │
  │  Utilisateur  : ${FRESHRSS_ADMIN_USER}                           │
  │  Mot de passe : ${FRESHRSS_ADMIN_PASS}                           │
  │                                                                  │
  │  API Google Reader disponible sur : /api/greader.php             │
  │                                                                  │
  │  SSO Authentik (OIDC natif) :                                    │
  │    → Bouton "Login with OIDC" sur la page de connexion           │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ FreshRSS prêt — https://${CALEOPE_DOMAIN}/"
