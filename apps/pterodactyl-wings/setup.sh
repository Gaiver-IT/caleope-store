#!/bin/bash
# setup.sh — Pterodactyl Wings (daemon de serveurs de jeux)
set -euo pipefail
echo "→ Préparation de Pterodactyl Wings..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/pterodactyl-wings"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{tmp,logs}
mkdir -p /var/lib/pterodactyl

# ── Params ──────────────────────────────────────────────────────────────────
PARAM_PANEL_URL="${PARAM_PANEL_URL:-}"
PARAM_PANEL_API_KEY="${PARAM_PANEL_API_KEY:-}"
NODE_NAME="${PARAM_NODE_NAME:-Node-01}"
NODE_FQDN="${PARAM_NODE_FQDN:-}"

if [ -z "${NODE_FQDN}" ]; then
    echo "❌ NODE_FQDN (IP ou domaine public de ce serveur Wings) est requis" >&2
    exit 1
fi

# ── Auto-détection du panel local ────────────────────────────────────────────
PANEL_SECRETS="${CALEOPE_BASE_DIR}/app-config/pterodactyl-panel/secrets.env"
PANEL_URL="${PARAM_PANEL_URL}"
PANEL_API_KEY="${PARAM_PANEL_API_KEY}"

if [ -f "${PANEL_SECRETS}" ]; then
    echo "  → Panel détecté localement, lecture de la configuration..."
    if [ -z "${PANEL_URL}" ]; then
        PANEL_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2- || echo "")
        # Récupérer le domaine du panel depuis ses secrets si différent
        LOCAL_PANEL_URL=$(grep "^APP_URL=" "${PANEL_SECRETS}" 2>/dev/null | cut -d= -f2- || echo "")
        [ -n "${LOCAL_PANEL_URL}" ] && PANEL_URL="${LOCAL_PANEL_URL}"
        [ -z "${PANEL_URL}" ] && PANEL_URL="https://${PANEL_DOMAIN}"
    fi
    # Récupérer la clé API générée par le bootstrap du panel
    BOOTSTRAP_ENV="${CALEOPE_BASE_DIR}/app-config/pterodactyl-panel/bootstrap.env"
    if [ -z "${PANEL_API_KEY}" ] && [ -f "${BOOTSTRAP_ENV}" ]; then
        PANEL_API_KEY=$(grep "^PTERODACTYL_API_KEY=" "${BOOTSTRAP_ENV}" | cut -d= -f2- || echo "")
    fi
fi

# ── UFW : ouvrir les ports jeux ──────────────────────────────────────────────
# Défini tôt pour être utilisable dans le chemin sans-panel
_open_game_ports() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 8080/tcp comment "pterodactyl-wings-api" 2>/dev/null || true
        ufw allow 2022/tcp comment "pterodactyl-wings-sftp" 2>/dev/null || true
        ufw allow 25500:25600/tcp comment "pterodactyl-game-servers-tcp" 2>/dev/null || true
        ufw allow 25500:25600/udp comment "pterodactyl-game-servers-udp" 2>/dev/null || true
        echo "  ✓ Ports UFW ouverts: 8080/tcp, 2022/tcp, 25500-25600/tcp+udp"
    fi
}

if [ -z "${PANEL_URL}" ] || [ -z "${PANEL_API_KEY}" ]; then
    echo "⚠ Panel URL ou clé API manquante — Wings sera configuré manuellement"
    echo "  Créer le nœud dans Panel → Admin → Nodes et copier le config.yml"
    echo "  dans : ${CONFIG_DIR}/config.yml"

    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')

    cat > "${CONFIG_DIR}/config.yml" << EOF
debug: false
uuid: ${UUID}
token_id: ""
token: ""
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
  upload_limit: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
EOF
    cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │         Pterodactyl Wings — Configuration manuelle requise       │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⚠ Wings n'a pas pu se connecter au panel automatiquement.      │
  │                                                                  │
  │  Étapes manuelles :                                              │
  │    1. Ouvrir le Pterodactyl Panel → Admin → Nodes               │
  │    2. Créer un nouveau nœud avec FQDN : ${NODE_FQDN}            │
  │    3. Onglet "Configuration" → Copier le contenu YAML           │
  │    4. Coller dans : ${CONFIG_DIR}/config.yml                    │
  │    5. Redémarrer Wings : caleope restart pterodactyl-wings       │
  │                                                                  │
  │  Ports ouverts dans UFW :                                        │
  │    8080/TCP  — API Wings                                         │
  │    2022/TCP  — SFTP                                              │
  │    25500-25600/TCP+UDP — Serveurs de jeux (plage réservée)      │
  └──────────────────────────────────────────────────────────────────┘
EOF
    _open_game_ports
    echo "⚠ Wings démarré sans panel — configuration manuelle requise"
    exit 0
fi

# ── Création du nœud via l'API Panel ─────────────────────────────────────────
echo "  → Connexion au panel ${PANEL_URL}..."

# Attendre que le panel soit joignable (max 120s)
MAX_WAIT=120
WAITED=0
until curl -sf --max-time 5 \
    -H "Authorization: Bearer ${PANEL_API_KEY}" \
    -H "Accept: application/json" \
    "${PANEL_URL}/api/application/nodes" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Panel non joignable après ${MAX_WAIT}s" >&2
        exit 1
    fi
done
echo "  ✓ Panel joignable"

# Créer ou récupérer la location par défaut
LOCATION_ID=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer ${PANEL_API_KEY}" \
    -H "Accept: application/json" \
    "${PANEL_URL}/api/application/locations" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('data',[])
print(r[0]['attributes']['id'] if r else '')
" 2>/dev/null || echo "")

if [ -z "${LOCATION_ID}" ]; then
    echo "  → Création d'une location par défaut..."
    LOCATION_ID=$(curl -sf --max-time 10 -X POST \
        -H "Authorization: Bearer ${PANEL_API_KEY}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "${PANEL_URL}/api/application/locations" \
        -d '{"short":"local","long":"Local Node"}' \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['attributes']['id'])" 2>/dev/null || echo "")
fi

[ -n "${LOCATION_ID}" ] || { echo "❌ Impossible de créer/récupérer une location"; exit 1; }
echo "  ✓ Location ID: ${LOCATION_ID}"

# Créer le nœud
echo "  → Création du nœud '${NODE_NAME}'..."
NODE_RESP=$(curl -sf --max-time 10 -X POST \
    -H "Authorization: Bearer ${PANEL_API_KEY}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "${PANEL_URL}/api/application/nodes" \
    -d "{
        \"name\":\"${NODE_NAME}\",
        \"location_id\":${LOCATION_ID},
        \"fqdn\":\"${NODE_FQDN}\",
        \"scheme\":\"http\",
        \"memory\":8192,
        \"memory_overallocate\":0,
        \"disk\":51200,
        \"disk_overallocate\":0,
        \"upload_size\":100,
        \"daemon_sftp\":2022,
        \"daemon_listen\":8080
    }" 2>/dev/null || echo "")

NODE_ID=$(echo "${NODE_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['attributes']['id'])" 2>/dev/null || echo "")

if [ -z "${NODE_ID}" ]; then
    echo "❌ Erreur création du nœud dans le panel" >&2
    echo "  Réponse: ${NODE_RESP}"
    exit 1
fi
echo "  ✓ Nœud créé (ID: ${NODE_ID})"

# Récupérer le config.yml généré par le panel
echo "  → Téléchargement de la configuration Wings..."
NODE_CONFIG=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer ${PANEL_API_KEY}" \
    -H "Accept: text/plain" \
    "${PANEL_URL}/api/application/nodes/${NODE_ID}/configuration" 2>/dev/null || echo "")

if [ -z "${NODE_CONFIG}" ]; then
    echo "❌ Impossible de récupérer la configuration Wings depuis le panel" >&2
    exit 1
fi

echo "${NODE_CONFIG}" > "${CONFIG_DIR}/config.yml"
chmod 600 "${CONFIG_DIR}/config.yml"
echo "  ✓ config.yml Wings écrit"

_open_game_ports

# ── secrets.env Wings ─────────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/secrets.env" << EOF
# Wings — aucune variable secrète requise (config dans config.yml)
# Panel URL de référence (info seulement)
PTERODACTYL_PANEL_URL=${PANEL_URL}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │         Pterodactyl Wings — Daemon de serveurs de jeux           │
  ├──────────────────────────────────────────────────────────────────┤
  │  Wings est enregistré dans le panel : ${PANEL_URL}               │
  │  Nœud : ${NODE_NAME} (FQDN: ${NODE_FQDN})                       │
  │                                                                  │
  │  Ports ouverts dans UFW :                                        │
  │    8080/TCP  — API Wings (communication avec le panel)           │
  │    2022/TCP  — SFTP (transfert de fichiers serveurs)             │
  │    25500-25600/TCP+UDP — Ports serveurs de jeux                  │
  │                                                                  │
  │  Minecraft : port 25565 (à ouvrir via Admin → Nodes)            │
  │  Satisfactory : port 7777 (UDP)                                  │
  │  Sons of the Forest : port 8766/27016 (UDP)                     │
  │                                                                  │
  │  Créer des serveurs dans : ${PANEL_URL}/admin/servers           │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/                    │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "✓ Pterodactyl Wings configuré et enregistré dans le panel"
