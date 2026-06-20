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
    # Token brut accepté si argon2 indisponible (mode dégradé)
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

# Sans SMTP : les inscriptions directes sont ouvertes, pas d'envoi d'email
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

# ── Authentik ForwardAuth ─────────────────────────────────────────────────────
# Vaultwarden n'a pas d'OIDC natif → ForwardAuth via Traefik (authentik@docker).
# L'API Authentik est accessible en http://localhost:8000 depuis le serveur hôte.
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -n "${AK_TOKEN}" ]; then
            AK_PORT=$(grep "^CALEOPE_PORT_WEB=" "${CALEOPE_BASE_DIR}/apps-installed/authentik/app.env" 2>/dev/null | cut -d= -f2-)
            AK_PORT="${AK_PORT:-8000}"
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
                PROV_PK=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/proxy/" \
                    -d "{\"name\":\"Vaultwarden\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"external_host\":\"https://${CALEOPE_DOMAIN}\",\"mode\":\"forward_single\"}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Vaultwarden\",\"slug\":\"vaultwarden-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Ajouter le provider à l'outpost embarqué
                    OUTPOST_PK=$(curl -s --max-time 10 -H "${AK_HA}" \
                        "${AK_BASE}/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded" \
                        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
                    if [ -n "${OUTPOST_PK}" ]; then
                        CUR_PROVS=$(curl -s --max-time 10 -H "${AK_HA}" \
                            "${AK_BASE}/outposts/instances/${OUTPOST_PK}/" \
                            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('providers',[])))" 2>/dev/null || echo "[]")
                        NEW_PROVS=$(python3 -c "
import json
l=json.loads('${CUR_PROVS}')
if ${PROV_PK} not in l: l.append(${PROV_PK})
print(json.dumps(l))
" 2>/dev/null || echo "[${PROV_PK}]")
                        curl -s --max-time 10 -X PATCH -H "${AK_HA}" -H "${AK_HJ}" \
                            "${AK_BASE}/outposts/instances/${OUTPOST_PK}/" \
                            -d "{\"providers\":${NEW_PROVS}}" >/dev/null 2>&1 || true
                    fi

                    # Injecter middleware authentik dans le compose
                    awk '
/traefik.http.routers.vaultwarden.entrypoints/ && !done {
    print
    indent = substr($0, 1, index($0, "-") - 1) "- "
    print indent "\"traefik.http.routers.vaultwarden.middlewares=authentik@docker\""
    done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/vw_compose_sso.yml && \
                    mv /tmp/vw_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true

                    echo "  ✓ Vaultwarden ForwardAuth configuré dans Authentik (PK=${PROV_PK})"
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
  │  Les inscriptions sont ouvertes par défaut.                      │
  │  Pour les fermer : SIGNUPS_ALLOWED=false dans secrets.env        │
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
