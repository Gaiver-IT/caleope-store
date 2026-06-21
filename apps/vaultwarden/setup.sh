#!/bin/bash
# setup.sh — Vaultwarden (gestionnaire de mots de passe)
set -euo pipefail
echo "→ Préparation de Vaultwarden..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/vaultwarden"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/data"

# ── Secrets ─────────────────────────────────────────────────────────────────
# Admin token : argon2 hash requis depuis Vaultwarden 1.28
# Fallback vers token hex si argon2 non disponible sur l'hôte
ADMIN_TOKEN_PLAIN=$(openssl rand -hex 32)
if command -v argon2 >/dev/null 2>&1; then
    SALT=$(openssl rand -hex 8)
    ADMIN_TOKEN_HASH=$(echo -n "${ADMIN_TOKEN_PLAIN}" | argon2 "${SALT}" -e -id -k 65536 -t 3 -p 4 2>/dev/null || echo "")
else
    ADMIN_TOKEN_HASH="${ADMIN_TOKEN_PLAIN}"
fi

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

SMTP_BLOCK=""
if [ -n "${SMTP_HOST}" ]; then
    SMTP_BLOCK="SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USERNAME=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
SMTP_SECURITY=starttls"
fi

REQUIRE_EMAIL_CONFIRMATION="false"
[ -n "${SMTP_HOST}" ] && REQUIRE_EMAIL_CONFIRMATION="true"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# Vaultwarden
ADMIN_TOKEN=${ADMIN_TOKEN_HASH}
DOMAIN=https://${CALEOPE_DOMAIN}
SIGNUPS_ALLOWED=true
SIGNUPS_VERIFY=${REQUIRE_EMAIL_CONFIRMATION}
INVITATIONS_ALLOWED=true
WEBSOCKET_ENABLED=true
ROCKET_PORT=80

# SMTP
${SMTP_BLOCK}

# Token brut (pour l'accès admin — à conserver)
_ADMIN_TOKEN_PLAIN=${ADMIN_TOKEN_PLAIN}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── CA bundle + AUTHENTIK_DOMAIN ────────────────────────────────────────────────
# Vaultwarden (Rust/OpenSSL) doit valider le cert TLS d'Authentik (auto-signé).
# On crée un bundle = CAs système + cert Authentik, monté dans le container.
# AUTHENTIK_DOMAIN est écrit dans secrets.env pour l'interpolation compose (extra_hosts).
BASE_DOMAIN=$(echo "${CALEOPE_DOMAIN}" | cut -d. -f2-)
_AK_DOMAIN_EARLY=$(grep "^AUTHENTIK_DOMAIN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
[ -n "${_AK_DOMAIN_EARLY}" ] || _AK_DOMAIN_EARLY="authentik.${BASE_DOMAIN}"
echo "AUTHENTIK_DOMAIN=${_AK_DOMAIN_EARLY}" >> "${CONFIG_DIR}/secrets.env"

AK_CERT="${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"
if [ -f "${AK_CERT}" ]; then
    cat /etc/ssl/certs/ca-certificates.crt "${AK_CERT}" > "${CONFIG_DIR}/ca-bundle.pem"
else
    cp /etc/ssl/certs/ca-certificates.crt "${CONFIG_DIR}/ca-bundle.pem"
fi
chmod 644 "${CONFIG_DIR}/ca-bundle.pem"

# ── Authentik SSO (OIDC natif) ────────────────────────────────────────────────
# Vaultwarden supporte nativement l'OIDC depuis v1.30 → bouton "Se connecter
# avec SSO" dans l'UI + support des clients Bitwarden (mobile, extension).
# On crée un provider OAuth2/OIDC dans Authentik (pas un proxy ForwardAuth).
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -n "${AK_TOKEN}" ] && [ -n "${AK_DOMAIN}" ]; then
            AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null)
            AK_PORT="${AK_PORT:-9000}"
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
                # Chercher un provider OAuth2 existant (idempotent)
                EXISTING=$(curl -s --max-time 10 -H "${AK_HA}" \
                    "${AK_BASE}/providers/oauth2/?search=Vaultwarden" \
                    | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('results',[])
if r:
    print(json.dumps({'pk':r[0]['pk'],'cid':r[0]['client_id'],'cs':r[0]['client_secret']}))
" 2>/dev/null || echo "")

                if [ -n "${EXISTING}" ]; then
                    PROV_PK=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")
                    SSO_CLIENT_ID=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['cid'])")
                    SSO_CLIENT_SECRET=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['cs'])")
                else
                    REDIRECT_URI="https://${CALEOPE_DOMAIN}/identity/connect/oidc-signin"
                    PROV_RESP=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/providers/oauth2/" \
                        -d "{\"name\":\"Vaultwarden\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"client_type\":\"confidential\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"${REDIRECT_URI}\"}],\"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}" \
                        2>/dev/null || echo "")
                    PROV_PK=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                    SSO_CLIENT_ID=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
                    SSO_CLIENT_SECRET=$(echo "${PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
                fi

                if [ -n "${PROV_PK}" ] && [ -n "${SSO_CLIENT_ID}" ]; then
                    # Créer l'application Authentik
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Vaultwarden\",\"slug\":\"vaultwarden\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Injecter la config SSO dans secrets.env
                    cat >> "${CONFIG_DIR}/secrets.env" << SSOENV

# SSO Authentik (OIDC natif — bouton "Se connecter avec SSO" dans l'UI)
SSO_ENABLED=true
SSO_ONLY=false
SSO_PROVIDER_NAME=Authentik
SSO_AUTHORITY=https://${AK_DOMAIN}/application/o/vaultwarden/
SSO_CLIENT_ID=${SSO_CLIENT_ID}
SSO_CLIENT_SECRET=${SSO_CLIENT_SECRET}
SSOENV

                    echo "  ✓ Vaultwarden OIDC configuré dans Authentik (client_id=${SSO_CLIENT_ID})"
                fi
            fi
        fi
    fi
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │               Vaultwarden — Gestionnaire de mots de passe        │
  ├──────────────────────────────────────────────────────────────────┤
  │  Application : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Interface admin :                                               │
  │    URL   : https://${CALEOPE_DOMAIN}/admin                       │
  │    Token : ${ADMIN_TOKEN_PLAIN}
  │                                                                  │
  │  Connexion SSO : bouton "Se connecter avec SSO" dans l'UI        │
  │    → Utilise Authentik (OIDC). Les comptes locaux restent        │
  │    disponibles en parallèle (SSO_ONLY=false).                    │
  │                                                                  │
  │  Extension navigateur : Bitwarden (compatible Vaultwarden)       │
  │    → Entrer https://${CALEOPE_DOMAIN}/ comme URL serveur         │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          Vaultwarden — Token admin                   ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL admin : https://${CALEOPE_DOMAIN}/admin"
echo "  ║  Token     : ${ADMIN_TOKEN_PLAIN}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Vaultwarden configuré"
