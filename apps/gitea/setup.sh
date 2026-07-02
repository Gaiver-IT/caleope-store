#!/bin/bash
# setup.sh — Gitea (forge Git auto-hébergée)
set -euo pipefail
echo "→ Préparation de Gitea..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/gitea"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{data,db}

# ── Params ──────────────────────────────────────────────────────────────────
ADMIN_USER="${CALEOPE_PARAM_ADMIN_USER:-git-admin}"
ADMIN_EMAIL="${CALEOPE_PARAM_ADMIN_EMAIL:-admin@${CALEOPE_DOMAIN}}"

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)
SECRET_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
INTERNAL_TOKEN=$(openssl rand -hex 32)

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

MAIL_ENABLED="false"
MAIL_BLOCK=""
if [ -n "${SMTP_HOST}" ]; then
    MAIL_ENABLED="true"
    MAIL_BLOCK="GITEA__mailer__ENABLED=true
GITEA__mailer__PROTOCOL=smtp+starttls
GITEA__mailer__SMTP_ADDR=${SMTP_HOST}
GITEA__mailer__SMTP_PORT=${SMTP_PORT}
GITEA__mailer__USER=${SMTP_USER}
GITEA__mailer__PASSWD=${SMTP_PASS}
GITEA__mailer__FROM=${SMTP_FROM}"
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# PostgreSQL
POSTGRES_DB=gitea
POSTGRES_USER=gitea
POSTGRES_PASSWORD=${DB_PASS}

# Gitea (env-based config via GITEA__ prefix)
GITEA__database__DB_TYPE=postgres
GITEA__database__HOST=gitea-db:5432
GITEA__database__NAME=gitea
GITEA__database__USER=gitea
GITEA__database__PASSWD=${DB_PASS}
GITEA__server__DOMAIN=${CALEOPE_DOMAIN}
GITEA__server__ROOT_URL=https://${CALEOPE_DOMAIN}/
GITEA__server__SSH_DOMAIN=${CALEOPE_DOMAIN}
GITEA__server__SSH_PORT=2222
GITEA__security__SECRET_KEY=${SECRET_KEY}
GITEA__security__INTERNAL_TOKEN=${INTERNAL_TOKEN}
GITEA__oauth2__JWT_SECRET=${JWT_SECRET}
GITEA__security__INSTALL_LOCK=true
GITEA__service__DISABLE_REGISTRATION=false
${MAIL_BLOCK}

# Bootstrap
GITEA_ADMIN_USER=${ADMIN_USER}
GITEA_ADMIN_EMAIL=${ADMIN_EMAIL}
GITEA_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh (crée le compte admin via CLI gitea) ─────────────────────────
# Tourne dans un container gitea/gitea:latest avec user=git et data monté.
# gitea CLI a accès à app.ini et peut créer le premier admin sans auth.
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
MAX_WAIT=180
WAITED=0

echo "→ Gitea bootstrap : attente de l'API HTTP (gitea:3000)..."
until wget -qO- http://gitea:3000/api/v1/version >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    [ "${WAITED}" -lt "${MAX_WAIT}" ] || { echo "⚠️  Gitea non joignable — skip bootstrap"; exit 0; }
done
echo "  ✓ API Gitea prête (${WAITED}s)"

# Vérifier si l'admin existe déjà
EXISTS=$(wget -qO- "http://gitea:3000/api/v1/users/${GITEA_ADMIN_USER}" 2>/dev/null | grep -c '"login"' || true)
if [ "${EXISTS}" -gt 0 ]; then
    echo "  ✓ Admin '${GITEA_ADMIN_USER}' déjà créé — bootstrap ignoré"
    exit 0
fi

echo "  → Création du compte admin via CLI gitea..."
/usr/local/bin/gitea admin user create \
    --config /data/gitea/conf/app.ini \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASS}" \
    --email "${GITEA_ADMIN_EMAIL}" \
    --admin \
    --must-change-password=false 2>&1 && echo "  ✓ Compte admin Gitea créé" || echo "  ⚠ Création admin échouée"
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# ── Authentik OIDC ───────────────────────────────────────────────────────────
# Gitea supporte OIDC natif → on crée un provider OAuth2 dans Authentik et on
# enregistre la source OAuth dans Gitea via CLI (avec URL interne pour la
# validation) puis on patche la DB pour remplacer par l'URL publique.
# L'API Authentik n'est pas joignable depuis le serveur via son URL publique
# (hairpin NAT absent) → on utilise http://localhost:8000.
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -z "${AK_DOMAIN}" ]; then
            BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
            AK_DOMAIN="authentik.${BASE_DOMAIN}"
        fi

        if [ -n "${AK_TOKEN}" ] && [ -n "${AK_DOMAIN}" ]; then
            AK_PORT=$(grep "^CALEOPE_PORT_WEB=" "${CALEOPE_BASE_DIR}/apps-installed/authentik/app.env" 2>/dev/null | cut -d= -f2-)
            AK_PORT="${AK_PORT:-8000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            echo "  → Configuration OIDC Gitea dans Authentik..."

            AUTH_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                GIT_OIDC_SECRET=$(openssl rand -hex 16)
                PROV_BODY=$(python3 -c "
import json
d = {
    'name': 'Gitea',
    'authorization_flow': '${AUTH_FLOW}',
    'invalidation_flow': '${INVAL_FLOW}',
    'client_type': 'confidential',
    'client_id': 'gitea',
    'client_secret': '${GIT_OIDC_SECRET}',
    'redirect_uris': [{'matching_mode': 'strict', 'url': 'https://${CALEOPE_DOMAIN}/user/oauth2/Authentik/callback'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
}
print(json.dumps(d))
" 2>/dev/null)
                PROV_PK=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" -d "${PROV_BODY}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Gitea\",\"slug\":\"gitea-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Récupérer l'IP interne d'Authentik pour la CLI Gitea
                    # Gitea CLI valide le discovery URL au moment de la création
                    # → utiliser l'adresse interne Docker puis patcher la DB
                    AK_INTERNAL_IP=$(docker inspect authentik-server \
                        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | \
                        awk '{for(i=1;i<=NF;i++) if($i~/^172\./) {print $i; exit}}')
                    AK_INTERNAL_URL="http://${AK_INTERNAL_IP:-172.18.0.10}:9000"

                    # Ajouter extra_hosts pour que Gitea résolve le domaine Authentik
                    awk -v domain="${AK_DOMAIN}" -v ip="${AK_INTERNAL_IP:-172.18.0.10}" '
/^  gitea:$/ { in_gitea=1 }
in_gitea && /^    environment:/ && !extra_done {
    print "    extra_hosts:"
    print "      - \"" domain ":" ip "\""
    extra_done=1
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/gitea_compose_sso.yml && \
                    mv /tmp/gitea_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true

                    # Enregistrer la source OIDC dans Gitea via CLI (URL interne)
                    docker exec gitea gitea admin auth add-oauth \
                        --name "Authentik" \
                        --provider "openidConnect" \
                        --key "gitea" \
                        --secret "${GIT_OIDC_SECRET}" \
                        --auto-discover-url "${AK_INTERNAL_URL}/application/o/gitea-sso/.well-known/openid-configuration" \
                        --use-custom-urls false \
                        --admin-group "authentik Admins" \
                        --config /data/gitea/conf/app.ini 2>/dev/null || true

                    # Patcher la DB Gitea pour remplacer l'URL interne par l'URL publique
                    docker exec gitea-db sh -c "
psql -U gitea -d gitea -c \"UPDATE login_source SET cfg = REPLACE(cfg::text, '${AK_INTERNAL_URL}', 'https://${AK_DOMAIN}')::json WHERE name = 'Authentik' AND is_active = true;\"
" 2>/dev/null || true

                    echo "  ✓ Gitea OIDC configuré dans Authentik (PK=${PROV_PK})"
                else
                    echo "  ⚠ Erreur création provider OIDC Gitea"
                fi
            else
                echo "  ⚠ Flows Authentik introuvables"
            fi
        fi
    fi
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │                   Gitea — Forge Git auto-hébergée                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface web : https://${CALEOPE_DOMAIN}/                      │
  │                                                                  │
  │  Compte admin :                                                  │
  │    Login    : ${ADMIN_USER}
  │    Password : ${ADMIN_PASS}
  │    Email    : ${ADMIN_EMAIL}
  │                                                                  │
  │  SSH Git (port 2222) :                                           │
  │    git clone ssh://git@${CALEOPE_DOMAIN}:2222/user/repo.git     │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              Gitea — Identifiants admin              ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login: ${ADMIN_USER}"
echo "  ║  Pass : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Gitea configuré"
