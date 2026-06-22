#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/pterodactyl/"{panel,logs,nginx,db,servers}
mkdir -p /tmp/pterodactyl

# Paramètres
ADMIN_EMAIL="${CALEOPE_PARAM_ADMIN_EMAIL:-admin@${CALEOPE_DOMAIN}}"
ADMIN_FIRST="${CALEOPE_PARAM_ADMIN_FIRST:-Admin}"
ADMIN_LAST="${CALEOPE_PARAM_ADMIN_LAST:-Caleope}"
ADMIN_USER="${CALEOPE_PARAM_ADMIN_USER:-admin}"

# Ports alloués
WINGS_PORT="${CALEOPE_PORT_WINGS:-8080}"
SFTP_PORT="${CALEOPE_PORT_SFTP:-2022}"
WEB_PORT="${CALEOPE_PORT_WEB:-80}"

# Génération des secrets
DB_PASS=$(openssl rand -hex 20)
DB_ROOT=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
APP_KEY="base64:$(openssl rand -base64 32)"

cat > "${CONFIG_DIR}/secrets.env" <<EOF
# MariaDB
MARIADB_ROOT_PASSWORD=${DB_ROOT}
MARIADB_DATABASE=panel
MARIADB_USER=pterodactyl
MARIADB_PASSWORD=${DB_PASS}

# Pterodactyl Panel
APP_ENV=production
APP_ENVIRONMENT_ONLY=false
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_THEME=pterodactyl
APP_URL=https://${CALEOPE_DOMAIN}

DB_HOST=pterodactyl-db
DB_PORT=3306
DB_DATABASE=panel
DB_USERNAME=pterodactyl
DB_PASSWORD=${DB_PASS}

CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_DRIVER=redis
REDIS_HOST=pterodactyl-cache

MAIL_DRIVER=log
MAIL_FROM=no-reply@${CALEOPE_DOMAIN}

# Compte admin initial
PTERO_ADMIN_EMAIL=${ADMIN_EMAIL}
PTERO_ADMIN_USER=${ADMIN_USER}
PTERO_ADMIN_PASS=${ADMIN_PASS}
PTERO_ADMIN_FIRST=${ADMIN_FIRST}
PTERO_ADMIN_LAST=${ADMIN_LAST}
PTERO_WINGS_PORT=${WINGS_PORT}
PTERO_SFTP_PORT=${SFTP_PORT}
PTERO_DOMAIN=${CALEOPE_DOMAIN}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# Wings config — sera remplacée par le bootstrap une fois le node créé
# Config minimale pour que Wings démarre sans crasher immédiatement
cat > "${CONFIG_DIR}/wings.yml" <<EOF
debug: false
uuid: $(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/.\{8\}/&-/;s/.\{13\}/&-/;s/.\{18\}/&-/;s/.\{23\}/&-/')
token_id: placeholder
token: placeholder
api:
  host: 0.0.0.0
  port: ${WINGS_PORT}
  ssl:
    enabled: false
  upload_limit: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: ${SFTP_PORT}
allowed_mounts: []
remote: https://${CALEOPE_DOMAIN}
EOF
chmod 600 "${CONFIG_DIR}/wings.yml"

# Bootstrap — crée l'admin + le node Wings via artisan/API
cat > "${CONFIG_DIR}/bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash
set -euo pipefail

PANEL_URL="http://pterodactyl-panel:80"
ADMIN_EMAIL="${PTERO_ADMIN_EMAIL}"
ADMIN_USER="${PTERO_ADMIN_USER}"
ADMIN_PASS="${PTERO_ADMIN_PASS}"
ADMIN_FIRST="${PTERO_ADMIN_FIRST}"
ADMIN_LAST="${PTERO_ADMIN_LAST}"
WINGS_PORT="${PTERO_WINGS_PORT:-8080}"
SFTP_PORT="${PTERO_SFTP_PORT:-2022}"
PTERO_DOMAIN="${PTERO_DOMAIN}"
CONFIG_DIR="${CALEOPE_BASE_DIR:-/opt/gaiver-it/caleope}/app-config/pterodactyl"

echo "  ⏳ Attente de Pterodactyl Panel (max 3 min)..."
for i in $(seq 1 36); do
    STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "${PANEL_URL}/" 2>/dev/null) || STATUS="000"
    [ "${STATUS}" != "000" ] && [ "${STATUS}" != "502" ] && { echo "  ✓ Panel prêt (HTTP ${STATUS})"; break; }
    sleep 5
done

# Migrations + création admin via artisan
echo "  → Migrations de la base de données..."
docker exec pterodactyl-panel php artisan migrate --force --no-interaction 2>/dev/null || true

echo "  → Création du compte administrateur..."
docker exec pterodactyl-panel php artisan p:user:make \
    --email="${ADMIN_EMAIL}" \
    --username="${ADMIN_USER}" \
    --name-first="${ADMIN_FIRST}" \
    --name-last="${ADMIN_LAST}" \
    --password="${ADMIN_PASS}" \
    --admin=1 \
    --no-interaction 2>/dev/null || echo "  ℹ Admin déjà existant ou artisan non disponible"

# Récupérer un token API via login
sleep 3
API_TOKEN=$(curl -sf -X POST "${PANEL_URL}/api/client/account/api-keys" \
    -H "Content-Type: application/json" \
    -u "${ADMIN_EMAIL}:${ADMIN_PASS}" \
    -d '{"description":"caleope-setup","allowed_ips":[]}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('attributes',{}).get('token',''))" 2>/dev/null) || API_TOKEN=""

if [ -z "${API_TOKEN}" ]; then
    echo "  ⚠ Token API non obtenu — configuration du node Wings à faire manuellement"
    echo "    Panel : https://${PTERO_DOMAIN}/admin/nodes/new"
    exit 0
fi

# Créer le node Wings via l'API admin
NODE_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'Caleope Node',
    'description': 'Node principal géré par Caleope',
    'location_id': 1,
    'fqdn': '${PTERO_DOMAIN}',
    'scheme': 'https',
    'memory': 8192,
    'memory_overallocate': 0,
    'disk': 50000,
    'disk_overallocate': 0,
    'daemonSFTP': int('${SFTP_PORT}'),
    'daemonListen': int('${WINGS_PORT}'),
    'daemonBase': '/var/lib/pterodactyl/volumes'
}))
")

NODE_RESP=$(curl -sf -X POST "${PANEL_URL}/api/application/nodes" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -d "${NODE_PAYLOAD}" 2>/dev/null) || NODE_RESP=""

NODE_ID=$(echo "${NODE_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('attributes',{}).get('id',''))" 2>/dev/null) || NODE_ID=""

if [ -z "${NODE_ID}" ]; then
    echo "  ⚠ Création du node échouée — à configurer manuellement"
    echo "    Panel : https://${PTERO_DOMAIN}/admin/nodes/new"
    exit 0
fi

# Récupérer la config Wings pour ce node
WINGS_CONFIG=$(curl -sf "${PANEL_URL}/api/application/nodes/${NODE_ID}/configuration" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Accept: application/json" 2>/dev/null) || WINGS_CONFIG=""

if [ -n "${WINGS_CONFIG}" ]; then
    echo "${WINGS_CONFIG}" > "${CONFIG_DIR}/wings.yml"
    chmod 600 "${CONFIG_DIR}/wings.yml"
    echo "  ✓ Wings configuré (node ID: ${NODE_ID})"
    echo "  → Redémarrage de Wings avec la nouvelle config..."
    docker restart pterodactyl-wings 2>/dev/null || true
else
    echo "  ⚠ Config Wings non récupérée — node ID ${NODE_ID}"
    echo "    Récupère la config sur : https://${PTERO_DOMAIN}/admin/nodes/${NODE_ID}/configuration"
fi
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"

cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════╗
║          Pterodactyl — Panel + Wings (single server)         ║
╠══════════════════════════════════════════════════════════════╣
║  Panel admin   : https://${CALEOPE_DOMAIN}/admin             ║
║                                                              ║
║  Identifiant   : ${ADMIN_USER}                               ║
║  Email         : ${ADMIN_EMAIL}                              ║
║  Mot de passe  : ${ADMIN_PASS}                               ║
╠══════════════════════════════════════════════════════════════╣
║  ⏳ PREMIER DÉMARRAGE (~2-3 min)                              ║
║  Le bootstrap configure automatiquement le node Wings.       ║
║  Si Wings n'est pas connecté après 5 min :                   ║
║  Panel → Admin → Nodes → Caleope Node → Configuration        ║
╠══════════════════════════════════════════════════════════════╣
║  Ports utilisés :                                            ║
║  Panel (web) : ${WEB_PORT}                                   ║
║  Wings (API) : ${WINGS_PORT}  ← ouvrir dans le pare-feu      ║
║  SFTP        : ${SFTP_PORT}  ← ouvrir dans le pare-feu       ║
╚══════════════════════════════════════════════════════════════╝
EOF

echo "✓ Pterodactyl préparé (panel + wings)"
