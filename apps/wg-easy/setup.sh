#!/bin/bash
# setup.sh — WG-Easy (WireGuard VPN + interface web)
set -euo pipefail
echo "→ Préparation de WG-Easy..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/wg-easy"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/data"

# ── Params ──────────────────────────────────────────────────────────────────
WG_HOST="${CALEOPE_PARAM_WG_HOST:-}"
WG_DEFAULT_DNS="${CALEOPE_PARAM_WG_DEFAULT_DNS:-1.1.1.1}"

if [ -z "${WG_HOST}" ]; then
    echo "❌ WG_HOST (IP ou domaine public) est requis" >&2
    exit 1
fi

# ── Mot de passe admin (hashé bcrypt — wg-easy v14+ exige PASSWORD_HASH) ──────
ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)
# wgpw sort : PASSWORD_HASH='$2a$12$...' — les guillemets simples évitent l'interpolation
# Docker Compose env_file respecte les valeurs entre guillemets simples ($VAR non interpolé)
ADMIN_HASH_LINE=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "${ADMIN_PASS}" 2>/dev/null | grep "^PASSWORD_HASH=" || echo "")
if [ -z "${ADMIN_HASH_LINE}" ]; then
    # Fallback: générer le hash avec node + bcryptjs si disponible
    HASH_VAL=$(node -e "const bcrypt=require('bcryptjs'); console.log(bcrypt.hashSync('${ADMIN_PASS}', 12));" 2>/dev/null || echo "")
    if [ -n "${HASH_VAL}" ]; then
        ADMIN_HASH_LINE="PASSWORD_HASH='${HASH_VAL}'"
    fi
fi
if [ -z "${ADMIN_HASH_LINE}" ]; then
    echo "❌ Impossible de générer le hash bcrypt du mot de passe" >&2
    exit 1
fi

cat > "${CONFIG_DIR}/secrets.env" << EOF
# WG-Easy
WG_HOST=${WG_HOST}
${ADMIN_HASH_LINE}
WG_ADMIN_PASSWORD=${ADMIN_PASS}
WG_DEFAULT_DNS=${WG_DEFAULT_DNS}
WG_DEFAULT_ADDRESS=10.8.0.x
WG_ALLOWED_IPS=0.0.0.0/0
WG_PERSISTENT_KEEPALIVE=25
PORT=51821
WG_PORT=51820
UI_TRAFFIC_STATS=true
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │               WG-Easy — WireGuard VPN + Interface web            │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface d'administration :                                    │
  │    URL      : https://${CALEOPE_DOMAIN}/                         │
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  Serveur VPN : ${WG_HOST}:51820 (UDP)                            │
  │                                                                  │
  │  Pour ajouter un client VPN :                                    │
  │    1. Ouvrir l'interface web                                     │
  │    2. Cliquer "+ New client"                                     │
  │    3. Scanner le QR code ou télécharger le fichier .conf         │
  │                                                                  │
  │  ⚠ PORTS À OUVRIR/FORWARDER :                                    │
  │    • Sur ce serveur : UFW UDP 51820 (fait automatiquement)       │
  │    • Si WG_HOST = IP d'un routeur/box/NPM différent de ce        │
  │      serveur → configurer une redirection NAT/port-forward :     │
  │      ${WG_HOST}:51820/UDP  →  <IP_CE_SERVEUR>:51820/UDP          │
  │    • Les clients WireGuard se connectent à ${WG_HOST}:51820/UDP  │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

# ── Authentik ForwardAuth ─────────────────────────────────────────────────────
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -n "${AK_TOKEN}" ]; then
            AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null)
            AK_PORT="${AK_PORT:-9000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
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
                    -d "{\"name\":\"WG-Easy\",\"authorization_flow\":\"${AUTH_FLOW}\",\"invalidation_flow\":\"${INVAL_FLOW}\",\"external_host\":\"https://${CALEOPE_DOMAIN}\",\"mode\":\"forward_single\"}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"WG-Easy\",\"slug\":\"wgeasy-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
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
/traefik.http.routers.wg-easy.entrypoints/ && !done {
    print
    indent = substr($0, 1, index($0, "-") - 1) "- "
    print indent "\"traefik.http.routers.wg-easy.middlewares=authentik@docker\""
    done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/wg_compose_sso.yml && \
                    mv /tmp/wg_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true

                    echo "  ✓ WG-Easy ForwardAuth configuré dans Authentik (PK=${PROV_PK})"
                fi
            fi
        fi
    fi
fi

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║             WG-Easy — Mot de passe admin             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL     : https://${CALEOPE_DOMAIN}/"
echo "  ║  Password: ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ WG-Easy configuré (VPN: ${WG_HOST}:51820/UDP)"
