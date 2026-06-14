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
API_KEY=$(php artisan p:user:make --list-keys --email="${PTERODACTYL_ADMIN_EMAIL}" 2>/dev/null | grep -oP 'ptlc_\w+' | head -1 || echo "")
if [ -z "${API_KEY}" ]; then
    API_KEY=$(php artisan tinker --execute="
\$user = \App\Models\User::where('email', env('PTERODACTYL_ADMIN_EMAIL'))->first();
if (\$user) {
    \$key = \App\Models\ApiKey::create([
        'user_id' => \$user->id,
        'token_id' => \Illuminate\Support\Str::random(16),
        'token' => \Hash::make(\$t = \Illuminate\Support\Str::random(48)),
        'key_type' => 1,
        'allowed_ips' => null,
        'memo' => 'Caleope auto-generated',
    ]);
    echo 'ptlc_'.\$t;
}" 2>/dev/null | grep -oP 'ptlc_\w+' | tail -1 || echo "")
fi

if [ -n "${API_KEY}" ]; then
    echo "PTERODACTYL_API_KEY=${API_KEY}" >> /etc/pterodactyl/bootstrap.env
    echo "  ✓ Clé API générée : ${API_KEY}"
fi

echo "✓ Pterodactyl Panel initialisé"
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

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
  │  Prochaines étapes après connexion :                             │
  │    1. Aller dans Admin → Locations → Créer une location          │
  │    2. Aller dans Admin → Nodes → Ajouter Wings                   │
  │       (installer Pterodactyl Wings sur ce serveur ou un autre)   │
  │    3. Créer des serveurs de jeux via Admin → Servers             │
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
