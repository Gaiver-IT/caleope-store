#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/wordpress/html"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/wordpress/db"

# Paramètres
SITE_TITLE="${CALEOPE_PARAM_SITE_TITLE:-Mon Site}"
ADMIN_USER="${CALEOPE_PARAM_ADMIN_USER:-admin}"
ADMIN_EMAIL="${CALEOPE_PARAM_ADMIN_EMAIL:-admin@${CALEOPE_DOMAIN}}"

# Génération des secrets
DB_PASS=$(openssl rand -hex 20)
DB_ROOT=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
AUTH_KEY=$(openssl rand -hex 32)
SECURE_AUTH_KEY=$(openssl rand -hex 32)
LOGGED_IN_KEY=$(openssl rand -hex 32)
NONCE_KEY=$(openssl rand -hex 32)

cat > "${CONFIG_DIR}/secrets.env" <<EOF
# MariaDB
MARIADB_ROOT_PASSWORD=${DB_ROOT}
MARIADB_DATABASE=wordpress
MARIADB_USER=wordpress
MARIADB_PASSWORD=${DB_PASS}

# WordPress — connexion BDD
WORDPRESS_DB_HOST=wordpress-db:3306
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD=${DB_PASS}

# WordPress — URL publique (critique pour wp-admin derrière un reverse proxy)
WORDPRESS_CONFIG_EXTRA=
define('WP_HOME',      'https://${CALEOPE_DOMAIN}');
define('WP_SITEURL',   'https://${CALEOPE_DOMAIN}');
define('AUTH_KEY',     '${AUTH_KEY}');
define('SECURE_AUTH_KEY','${SECURE_AUTH_KEY}');
define('LOGGED_IN_KEY','${LOGGED_IN_KEY}');
define('NONCE_KEY',    '${NONCE_KEY}');
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}

# Compte admin (utilisé par le bootstrap WP-CLI)
WP_ADMIN_USER=${ADMIN_USER}
WP_ADMIN_PASSWORD=${ADMIN_PASS}
WP_ADMIN_EMAIL=${ADMIN_EMAIL}
WP_SITE_TITLE=${SITE_TITLE}
WP_SITE_URL=https://${CALEOPE_DOMAIN}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# Script de bootstrap WP-CLI (exécuté après le démarrage de WordPress)
cat > "${CONFIG_DIR}/bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash
set -euo pipefail

WP_URL="${WP_SITE_URL:-https://localhost}"
ADMIN_USER="${WP_ADMIN_USER:-admin}"
ADMIN_PASS="${WP_ADMIN_PASSWORD:-changeme}"
ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@localhost}"
SITE_TITLE="${WP_SITE_TITLE:-Mon Site}"

echo "  ⏳ Attente du démarrage de WordPress..."
for i in $(seq 1 30); do
    if docker exec wordpress php -r "require '/var/www/html/wp-load.php'; echo 'ok';" 2>/dev/null | grep -q "ok"; then
        echo "  ✓ WordPress prêt"
        break
    fi
    sleep 5
done

# Installer WordPress via WP-CLI si pas encore installé
if ! docker exec wordpress wp core is-installed --allow-root 2>/dev/null; then
    echo "  → Installation de WordPress..."
    docker exec wordpress wp core install \
        --allow-root \
        --url="${WP_URL}" \
        --title="${SITE_TITLE}" \
        --admin_user="${ADMIN_USER}" \
        --admin_password="${ADMIN_PASS}" \
        --admin_email="${ADMIN_EMAIL}" \
        --skip-email 2>/dev/null && echo "  ✓ WordPress installé" || echo "  ⚠ WP-CLI non disponible — installe via le wizard"
fi
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"

cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════╗
║              WordPress — Premiers accès                      ║
╠══════════════════════════════════════════════════════════════╣
║  URL publique  : https://${CALEOPE_DOMAIN}                   ║
║  Administration: https://${CALEOPE_DOMAIN}/wp-admin          ║
║                                                              ║
║  Identifiant   : ${ADMIN_USER}                               ║
║  Mot de passe  : ${ADMIN_PASS}                               ║
║  Email         : ${ADMIN_EMAIL}                              ║
╠══════════════════════════════════════════════════════════════╣
║  ⚠️  PREMIER DÉMARRAGE                                        ║
║  WordPress initialise la base (30-60s).                      ║
║  Si le wizard s'affiche, entre les infos ci-dessus.          ║
║  Si wp-admin redirige en boucle : vider les cookies.         ║
╚══════════════════════════════════════════════════════════════╝
EOF

echo "✓ WordPress préparé"
