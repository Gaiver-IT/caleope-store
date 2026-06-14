#!/bin/bash
# setup.sh — Immich (galerie photos auto-hébergée)
set -euo pipefail
echo "→ Préparation d'Immich..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/immich"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{library,db,model-cache}

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -hex 24)

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# PostgreSQL
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_USER=immich
POSTGRES_DB=immich

# Immich
DB_HOSTNAME=immich-db
DB_USERNAME=immich
DB_PASSWORD=${DB_PASS}
DB_DATABASE_NAME=immich
REDIS_HOSTNAME=immich-redis

# URL publique (pour les liens de partage)
IMMICH_SERVER_URL=https://${CALEOPE_DOMAIN}

# SMTP (configuré via l'interface admin Immich)
_SMTP_HOST=${SMTP_HOST}
_SMTP_PORT=${SMTP_PORT}
_SMTP_USER=${SMTP_USER}
_SMTP_PASS=${SMTP_PASS}
_SMTP_FROM=${SMTP_FROM}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │              Immich — Galerie photos auto-hébergée               │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⏳  Immich initialise la base (1-2 min au premier boot).        │
  │                                                                  │
  │  Application : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  → Créer le premier compte sur l'interface web.                  │
  │    Le premier compte créé devient automatiquement admin.         │
  │                                                                  │
  │  Configuration SMTP (si activée dans Caleope) :                  │
  │    Admin → Administration → Email → entrer les valeurs depuis    │
  │    app-config/${CALEOPE_APP_ID}/secrets.env (_SMTP_*)            │
  │                                                                  │
  │  Application mobile : "Immich" sur App Store / Play Store        │
  │    → Entrer https://${CALEOPE_DOMAIN}/ comme URL serveur         │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "✓ Immich configuré"
echo "  → Créer le premier compte sur https://${CALEOPE_DOMAIN}/"
