#!/bin/bash
# setup.sh — Pterodactyl Panel (gestion de serveurs de jeux)
set -euo pipefail
echo "→ Préparation de Pterodactyl Panel..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/pterodactyl-panel"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{var,logs,db}

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -hex 24)
DB_ROOT_PASS=$(openssl rand -hex 24)
APP_KEY="base64:$(openssl rand -base64 32)"
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 16)
# Email admin par défaut : admin@<domaine>
ADMIN_EMAIL="admin@${CALEOPE_DOMAIN}"

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

MAIL_BLOCK="MAIL_DRIVER=log"
if [ -n "${SMTP_HOST}" ]; then
    MAIL_BLOCK="MAIL_DRIVER=smtp
MAIL_HOST=${SMTP_HOST}
MAIL_PORT=${SMTP_PORT}
MAIL_USERNAME=${SMTP_USER}
MAIL_PASSWORD=${SMTP_PASS}
MAIL_FROM=${SMTP_FROM}
MAIL_ENCRYPTION=tls"
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# MariaDB
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_DATABASE=panel
MYSQL_USER=pterodactyl
MYSQL_PASSWORD=${DB_PASS}

# Pterodactyl Panel
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${CALEOPE_DOMAIN}
APP_KEY=${APP_KEY}
APP_TIMEZONE=Europe/Paris
DB_CONNECTION=mysql
DB_HOST=pterodactyl-db
DB_PORT=3306
DB_DATABASE=panel
DB_USERNAME=pterodactyl
DB_PASSWORD=${DB_PASS}
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_HOST=pterodactyl-redis
REDIS_PORT=6379
${MAIL_BLOCK}

# Bootstrap (admin user)
PTERODACTYL_ADMIN_EMAIL=${ADMIN_EMAIL}
PTERODACTYL_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh (artisan commands via Panel image) ──────────────────────────
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

cd /app
MAX_WAIT=120
WAITED=0

echo "→ Pterodactyl bootstrap : attente de la base de données..."
until php artisan migrate:status >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    [ "${WAITED}" -lt "${MAX_WAIT}" ] || { echo "❌ DB non joignable après ${MAX_WAIT}s"; exit 1; }
done

echo "  → Migrations..."
php artisan migrate --force --seed

echo "  → Création du compte admin..."
php artisan p:user:make \
    --email="${PTERODACTYL_ADMIN_EMAIL}" \
    --username="admin" \
    --name-first="Admin" \
    --name-last="Caleope" \
    --password="${PTERODACTYL_ADMIN_PASS}" \
    --admin=1 2>/dev/null || echo "  ⚠ Admin existe déjà (ignoré)"

echo "  → Génération de la clé API admin..."
# Pterodactyl stocke les tokens chiffrés avec encrypt() (Laravel AES),
# pas en bcrypt. Les champs r_* doivent valoir 3 (lecture+écriture).
# TYPE_APPLICATION = 2, prefix 'ptla_' inclus dans l'identifier.
# Bearer token = identifier (16 chars) + secret (32 chars), sans préfixe sup.
cat > /tmp/gen_api_key.php << 'PHPEOF'
<?php
chdir('/app');
require '/app/vendor/autoload.php';
$app = require_once '/app/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$email = getenv('PTERODACTYL_ADMIN_EMAIL');
$user  = Pterodactyl\Models\User::where('email', $email)->first();
if (!$user) { fwrite(STDERR, "User not found: $email\n"); exit(1); }

$prefix     = 'ptla_';
$identifier = $prefix . Illuminate\Support\Str::random(16 - strlen($prefix));
$secret     = Illuminate\Support\Str::random(32);
$now        = date('Y-m-d H:i:s');
Illuminate\Support\Facades\DB::table('api_keys')->insert([
    'user_id'            => $user->id,
    'identifier'         => $identifier,
    'token'              => encrypt($secret),
    'key_type'           => 2,
    'allowed_ips'        => null,
    'memo'               => 'Caleope auto-generated',
    'r_servers'          => 3,
    'r_nodes'            => 3,
    'r_allocations'      => 3,
    'r_users'            => 3,
    'r_locations'        => 3,
    'r_nests'            => 3,
    'r_eggs'             => 3,
    'r_database_hosts'   => 3,
    'r_server_databases' => 3,
    'created_at'         => $now,
    'updated_at'         => $now,
]);
// Bearer token = identifier + secret (no extra prefix)
echo $identifier . $secret . PHP_EOL;
PHPEOF

API_KEY=$(php /tmp/gen_api_key.php 2>/dev/null | awk '/^ptla_/{print $1;exit}' || echo "")

if [ -n "${API_KEY}" ]; then
    # /app/var est monté → app-data/pterodactyl-panel/var/ sur l'hôte
    echo "PTERODACTYL_API_KEY=${API_KEY}" > /app/var/bootstrap.env
    echo "  ✓ Clé API générée"
else
    echo "  ⚠ Clé API non générée — la configurer manuellement dans Panel → Admin → API"
fi

echo "✓ Pterodactyl Panel initialisé"
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# ── Authentik ForwardAuth ─────────────────────────────────────────────────────
# Pterodactyl Panel n'a pas d'OIDC natif → ForwardAuth via Traefik (authentik@docker).
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -n "${AK_TOKEN}" ]; then
            AK_BASE="http://localhost:8000/api/v3"
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
                    -d "{\"name\":\"Pterodactyl\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"external_host\":\"https://${CALEOPE_DOMAIN}\",\"mode\":\"forward_single\"}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Pterodactyl\",\"slug\":\"pterodactyl-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

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

                    awk '
/traefik.http.routers.pterodactyl.entrypoints/ && !done {
    print
    indent = substr($0, 1, index($0, "-") - 1) "- "
    print indent "\"traefik.http.routers.pterodactyl.middlewares=authentik@docker\""
    done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/ptero_compose_sso.yml && \
                    mv /tmp/ptero_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true

                    echo "  ✓ Pterodactyl ForwardAuth configuré dans Authentik (PK=${PROV_PK})"
                fi
            fi
        fi
    fi
fi

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │           Pterodactyl Panel — Gestion de serveurs de jeux        │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⏳  Le panel migre sa base de données (1-2 min au premier boot).│
  │                                                                  │
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/                         │
  │    Email    : ${ADMIN_EMAIL}
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  ⏳  Bootstrap en cours (30-120s) : migrations + compte admin     │
  │     + génération automatique de la clé API.                      │
  │                                                                  │
  │  Prochaine étape : installer Pterodactyl Wings sur ce serveur    │
  │    → Caleope installera Wings et le connectera au panel auto.    │
  │    → Créer ensuite les serveurs : Admin → Servers                │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║        Pterodactyl Panel — Identifiants admin        ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL   : https://${CALEOPE_DOMAIN}/"
echo "  ║  Email : ${ADMIN_EMAIL}"
echo "  ║  Pass  : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Pterodactyl Panel configuré"
