#!/bin/bash
# setup.sh — Matrix / Synapse (serveur fermé, Postgres)
set -euo pipefail
echo "→ Préparation de Matrix (Synapse)..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/data"
_SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/db"

SERVER_NAME="${CALEOPE_DOMAIN}"

# ── Secrets idempotents ──────────────────────────────────────────────────────
read_secret() { [ -f "${_SECRETS}" ] && grep "^$1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- || true; }
DB_PASS="$(read_secret POSTGRES_PASSWORD)"; [ -z "${DB_PASS}" ] && DB_PASS=$(openssl rand -hex 24)
REG_SECRET="$(read_secret SYNAPSE_REG_SECRET)"; [ -z "${REG_SECRET}" ] && REG_SECRET=$(openssl rand -hex 32)

cat > "${_SECRETS}" <<ENV
POSTGRES_USER=synapse
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_DB=synapse
SYNAPSE_REG_SECRET=${REG_SECRET}
ENV
chmod 600 "${_SECRETS}"

# ── Config Synapse : générée par l'image (crée aussi la clé de signature) ─────
if [ ! -f "${DATA_DIR}/homeserver.yaml" ]; then
    echo "  → Génération de la config Synapse (server_name=${SERVER_NAME})..."
    docker run --rm \
        -e SYNAPSE_SERVER_NAME="${SERVER_NAME}" \
        -e SYNAPSE_REPORT_STATS=no \
        -v "${DATA_DIR}:/data" \
        matrixdotorg/synapse:latest generate >/dev/null 2>&1 || {
            echo "  ⚠ Échec de la génération de config Synapse"; exit 1; }
fi

# ── Patch : sqlite → postgres, serveur fermé, secret d'enregistrement ─────────
python3 - "${DATA_DIR}/homeserver.yaml" "${DB_PASS}" "${REG_SECRET}" <<'PY'
import sys, re
path, dbpass, reg = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()

pg = f"""database:
  name: psycopg2
  args:
    user: synapse
    password: "{dbpass}"
    database: synapse
    host: matrix-db
    port: 5432
    cp_min: 5
    cp_max: 10
"""
# Remplace le bloc database (sqlite ou déjà postgres) par le bloc postgres.
s = re.sub(r"(?ms)^database:\n(?:[ \t]+.*\n?)*", pg, s, count=1)

# Réglages « serveur fermé » (idempotents : on retire d'abord une éventuelle clé).
def set_key(txt, key, line):
    txt = re.sub(rf"(?m)^{re.escape(key)}:.*$\n?", "", txt)
    return txt.rstrip() + "\n" + line + "\n"

s = set_key(s, "registration_shared_secret", f'registration_shared_secret: "{reg}"')
s = set_key(s, "enable_registration", "enable_registration: false")
s = set_key(s, "suppress_key_server_warning", "suppress_key_server_warning: true")
s = set_key(s, "report_stats", "report_stats: false")
s = set_key(s, "media_store_path", "media_store_path: /data/media_store")
open(path, "w").write(s)
print("  ✓ homeserver.yaml patché (postgres + serveur fermé)")
PY

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              Matrix / Synapse — Serveur de messagerie           │
  ├──────────────────────────────────────────────────────────────────┤
  │  Domaine serveur : ${SERVER_NAME}                                │
  │  API client      : https://${CALEOPE_DOMAIN}/                    │
  │  Fédération      : DÉSACTIVÉE (serveur fermé)                    │
  │  Inscription     : fermée. Crée le 1er compte admin :           │
  │    docker exec -it synapse register_new_matrix_user \\           │
  │      -u admin -a -c /data/homeserver.yaml http://localhost:8008 │
  │  Client conseillé : app « Element » (pointe sur ce serveur).    │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Matrix (Synapse) configuré — serveur ${SERVER_NAME}"
