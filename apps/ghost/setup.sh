#!/bin/bash
# setup.sh — Ghost CMS
set -euo pipefail
echo "→ Préparation de Ghost..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/ghost"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{content,db}

# ── Params ──────────────────────────────────────────────────────────────────
BLOG_TITLE="${CALEOPE_PARAM_BLOG_TITLE:-Mon Blog}"
ADMIN_EMAIL="${CALEOPE_PARAM_ADMIN_EMAIL:-}"
ADMIN_NAME="${CALEOPE_PARAM_ADMIN_NAME:-Admin}"

if [ -z "${ADMIN_EMAIL}" ]; then
    echo "❌ ADMIN_EMAIL est requis" >&2
    exit 1
fi

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_ROOT_PASS=$(openssl rand -hex 24)
DB_PASS=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

MAIL_BLOCK="mail__transport=Direct"
if [ -n "${SMTP_HOST}" ]; then
    MAIL_BLOCK="mail__transport=SMTP
mail__options__host=${SMTP_HOST}
mail__options__port=${SMTP_PORT}
mail__options__auth__user=${SMTP_USER}
mail__options__auth__pass=${SMTP_PASS}
mail__from=${SMTP_FROM}"
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# MySQL
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_DATABASE=ghost
MYSQL_USER=ghost
MYSQL_PASSWORD=${DB_PASS}

# Ghost config (url défini via environment: dans compose, pas ici)
database__client=mysql
database__connection__host=ghost-db
database__connection__user=ghost
database__connection__password=${DB_PASS}
database__connection__database=ghost
${MAIL_BLOCK}

# Bootstrap (admin setup)
GHOST_ADMIN_EMAIL=${ADMIN_EMAIL}
GHOST_ADMIN_PASS=${ADMIN_PASS}
GHOST_ADMIN_NAME=${ADMIN_NAME}
GHOST_BLOG_TITLE=${BLOG_TITLE}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh (run once par ghost-bootstrap container) ───────────────────
# Attend que Ghost soit prêt puis configure via l'API Admin
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

GHOST_URL="http://ghost:2368"
MAX_WAIT=120
WAITED=0

echo "→ Ghost bootstrap : attente de Ghost..."
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "${GHOST_URL}/ghost/api/admin/site/" 2>/dev/null)" != "000" ]; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Ghost non joignable après ${MAX_WAIT}s"
        exit 1
    fi
done
echo "  ✓ Ghost prêt (${WAITED}s)"

# Vérifier si déjà configuré
STATUS=$(curl -sf --max-redirs 0 "${GHOST_URL}/ghost/api/admin/authentication/setup/" 2>/dev/null || echo "")
IS_SETUP=$(echo "${STATUS}" | grep -c '"status":"eep"' || true)

if [ "${IS_SETUP}" -gt 0 ]; then
    echo "  ✓ Ghost déjà configuré — bootstrap ignoré"
    exit 0
fi

echo "  → Création du compte admin..."
RESPONSE=$(curl -sf --max-redirs 0 -X POST \
    -H "Content-Type: application/json" \
    -d "{\"setup\":[{\"name\":\"${GHOST_ADMIN_NAME}\",\"email\":\"${GHOST_ADMIN_EMAIL}\",\"password\":\"${GHOST_ADMIN_PASS}\",\"blogTitle\":\"${GHOST_BLOG_TITLE}\"}]}" \
    "${GHOST_URL}/ghost/api/admin/authentication/setup/" 2>&1 || echo "")

if echo "${RESPONSE}" | grep -q '"token"'; then
    echo "  ✓ Compte admin créé"
else
    echo "  ⚠ Réponse inattendue du setup Ghost :"
    echo "  ${RESPONSE}"
fi
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# ── Authentik ForwardAuth ─────────────────────────────────────────────────────
# Ghost admin n'a pas d'OIDC natif → ForwardAuth via Traefik (authentik@docker).
# API Authentik via http://localhost:8000 (pas l'URL publique — hairpin NAT absent).
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -n "${AK_TOKEN}" ]; then
            AK_BASE="http://localhost:8000/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            AUTH_FLOW=$(curl -sf --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -sf --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                PROV_PK=$(curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/proxy/" \
                    -d "{\"name\":\"Ghost\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"external_host\":\"https://${CALEOPE_DOMAIN}\",\"mode\":\"forward_single\"}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Ghost\",\"slug\":\"ghost-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Groupes Authentik
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-ghost-users\",\"is_superuser\":false}" >/dev/null 2>&1 || true
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-ghost-admins\",\"is_superuser\":false}" >/dev/null 2>&1 || true

                    # Outpost embedded
                    OUTPOST_PK=$(curl -sf --max-time 10 -H "${AK_HA}" \
                        "${AK_BASE}/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded" \
                        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
                    if [ -n "${OUTPOST_PK}" ]; then
                        CUR_PROVS=$(curl -sf --max-time 10 -H "${AK_HA}" \
                            "${AK_BASE}/outposts/instances/${OUTPOST_PK}/" \
                            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('providers',[])))" 2>/dev/null || echo "[]")
                        NEW_PROVS=$(python3 -c "
import json
l=json.loads('${CUR_PROVS}')
if ${PROV_PK} not in l: l.append(${PROV_PK})
print(json.dumps(l))" 2>/dev/null || echo "[${PROV_PK}]")
                        curl -sf --max-time 10 -X PATCH -H "${AK_HA}" -H "${AK_HJ}" \
                            "${AK_BASE}/outposts/instances/${OUTPOST_PK}/" \
                            -d "{\"providers\":${NEW_PROVS}}" >/dev/null 2>&1 || true
                    fi

                    # Injecter middleware dans le compose Ghost
                    awk '
/traefik.http.routers.ghost.entrypoints/ && !done {
    print
    indent = substr($0, 1, index($0, "-") - 1) "- "
    print indent "\"traefik.http.routers.ghost.middlewares=authentik@docker\""
    done=1; next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/ghost_compose_sso.yml && \
                    mv /tmp/ghost_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true

                    echo "  ✓ Ghost ForwardAuth configuré dans Authentik (PK=${PROV_PK})"
                fi
            fi
        fi
    fi
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                      Ghost — CMS moderne                         │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⏳  Ghost initialise la base (30-60s au premier boot).          │
  │                                                                  │
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/ghost/                   │
  │    Email    : ${ADMIN_EMAIL}
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  Blog public : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║               Ghost — Identifiants admin             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/ghost/"
echo "  ║  Email: ${ADMIN_EMAIL}"
echo "  ║  Pass : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Ghost configuré"
