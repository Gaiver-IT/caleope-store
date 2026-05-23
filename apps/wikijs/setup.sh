#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/wikijs/db"

# Générer les secrets
DB_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 14)

# Écrire secrets.env (fusionné dans app.env par Caleope)
cat > "${CONFIG_DIR}/secrets.env" <<EOF
# PostgreSQL
POSTGRES_DB=wiki
POSTGRES_USER=wiki
POSTGRES_PASSWORD=${DB_PASSWORD}

# Wiki.js
DB_TYPE=postgres
DB_HOST=wikijs-db
DB_PORT=5432
DB_USER=wiki
DB_PASS=${DB_PASSWORD}
DB_NAME=wiki
APP_URL=http://${CALEOPE_DOMAIN}
JWT_SECRET=${JWT_SECRET}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# post-install.txt
cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════╗
║              Wiki.js — Premiers accès                        ║
╠══════════════════════════════════════════════════════════════╣
║  URL          : http://${CALEOPE_DOMAIN}                     ║
║                                                              ║
║  ⚠️  À la PREMIÈRE ouverture, Wiki.js affiche un wizard      ║
║     de configuration. Renseigne :                            ║
║       • Admin email    : admin@gaiver-it.fr                  ║
║       • Admin password : ${ADMIN_PASSWORD}                   ║
║       • (La base de données est déjà configurée)             ║
╠══════════════════════════════════════════════════════════════╣
║  APRÈS le wizard — activer lecture publique :                ║
║    Administration → Groups → Guests                          ║
║    → cocher "read:pages" et "read:assets"                    ║
╠══════════════════════════════════════════════════════════════╣
║  SYNCHRONISATION GITHUB (optionnel) :                        ║
║    Administration → Storage → Git → Enable                   ║
║    Repo : github.com/Gaiver-IT/caleope-docs (branche: main) ║
║    Token : Personal Access Token GitHub (scope: repo)        ║
╚══════════════════════════════════════════════════════════════╝

Secrets sauvegardés dans : ${CONFIG_DIR}/secrets.env
EOF

echo "✓ Wiki.js préparé"
