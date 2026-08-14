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
# ⚠️ POURQUOI ce garde-fou : une montée de version passe par
# « caleope install wordpress --force », donc par CE script. Si on ré-engendre
# les mots de passe à chaque passage, MariaDB garde l'ancien (son volume
# app-data/wordpress/db survit à la montée) pendant que WordPress présente le
# nouveau -> connexion BDD refusée -> HTTP 500, l'app coupée de ses données.
# Idem pour les sels : les changer invalide toutes les sessions/cookies.
# On relit donc ce qui est DÉJÀ dans secrets.env et on ne tire au sort que ce
# qui manque vraiment (= première installation).
_SECRETS="${CONFIG_DIR}/secrets.env"

_garde() { # $1 = clé TELLE QU'ÉCRITE dans secrets.env, $2 = commande d'engendrement
    local cur=""
    if [ -f "${_SECRETS}" ]; then
        # « || true » obligatoire : sans lui, un grep sans résultat (clé absente
        # d'un ancien secrets.env) ferait SORTIR le script à cause du
        # « set -euo pipefail » de l'en-tête.
        cur=$(grep -m1 "^$1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- || true)
    fi
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; else eval "$2"; fi
}

# Les 4 sels n'ont PAS de clé à eux dans secrets.env : ils sont noyés dans la
# ligne WORDPRESS_CONFIG_EXTRA sous la forme define('AUTH_KEY','...'). On les
# ré-extrait un par un plutôt que de figer la ligne entière — ainsi WP_HOME et
# WP_SITEURL continuent de suivre ${CALEOPE_DOMAIN} s'il change (comme un port
# réalloué par le daemon, un domaine n'est pas un secret et doit rester mobile).
_garde_sel() { # $1 = nom de la constante PHP dans WORDPRESS_CONFIG_EXTRA, $2 = engendrement
    local cur=""
    if [ -f "${_SECRETS}" ]; then
        cur=$(grep "^WORDPRESS_CONFIG_EXTRA=" "${_SECRETS}" 2>/dev/null | head -1 \
              | sed -n "s/.*define('$1','\([^']*\)').*/\1/p" || true)
    fi
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; else eval "$2"; fi
}

# DB_PASS alimente À LA FOIS MARIADB_PASSWORD et WORDPRESS_DB_PASSWORD : relire
# la clé côté base (MARIADB_PASSWORD) suffit, les deux restent alignées.
DB_PASS=$(_garde MARIADB_PASSWORD "openssl rand -hex 20")
DB_ROOT=$(_garde MARIADB_ROOT_PASSWORD "openssl rand -hex 24")
ADMIN_PASS=$(_garde WP_ADMIN_PASSWORD "openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16")
AUTH_KEY=$(_garde_sel AUTH_KEY "openssl rand -hex 32")
SECURE_AUTH_KEY=$(_garde_sel SECURE_AUTH_KEY "openssl rand -hex 32")
LOGGED_IN_KEY=$(_garde_sel LOGGED_IN_KEY "openssl rand -hex 32")
NONCE_KEY=$(_garde_sel NONCE_KEY "openssl rand -hex 32")

# WORDPRESS_CONFIG_EXTRA — deux contraintes (voir la ligne dans le heredoc) :
#  1. TOUT sur UNE ligne : un env file ne supporte pas le multi-lignes (docker
#     compose plante sinon sur « unexpected character "(" »).
#  2. UNIQUEMENT des define() : l'image WordPress fait un eval() de cette valeur ;
#     la moindre structure de contrôle (if/isset) casse le parse de TOUT l'eval
#     -> Fatal PHP -> 500. Le forçage HTTPS derrière proxy est déjà fait
#     nativement par l'image, donc inutile ici.
# NB : ne PAS mettre ce genre de commentaire DANS le heredoc <<EOF (non quoté) —
# un $ y serait interprété (bug déjà attrapé : "$CONFIG_EXTRA" unbound).
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

# WordPress — URL publique + clés (une ligne, define() seuls — voir note ci-dessus)
WORDPRESS_CONFIG_EXTRA=define('WP_HOME','https://${CALEOPE_DOMAIN}'); define('WP_SITEURL','https://${CALEOPE_DOMAIN}'); define('AUTH_KEY','${AUTH_KEY}'); define('SECURE_AUTH_KEY','${SECURE_AUTH_KEY}'); define('LOGGED_IN_KEY','${LOGGED_IN_KEY}'); define('NONCE_KEY','${NONCE_KEY}');

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
