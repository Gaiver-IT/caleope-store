#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/gotify"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/gotify/data"

# Preserve existing password on reinstall
GOTIFY_DEFAULTUSER_PASS=""
if [ -f "${_SECRETS}" ]; then
    GOTIFY_DEFAULTUSER_PASS=$(grep "^GOTIFY_DEFAULTUSER_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${GOTIFY_DEFAULTUSER_PASS}" ] && GOTIFY_DEFAULTUSER_PASS="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)"

cat > "${_SECRETS}" <<ENV
GOTIFY_DEFAULTUSER_PASS=${GOTIFY_DEFAULTUSER_PASS}
ENV
chmod 600 "${_SECRETS}"

# Gotify ne supporte pas nativement OIDC → ForwardAuth Authentik acceptable
# (dernier recours per règle SSO : apps sans OIDC natif)

# ── Token client Gotify pour Caleope ─────────────────────────────────────────
echo "→ Attente démarrage Gotify (max 60s)..."
_gt_ready=false
for _i in $(seq 1 20); do
    if curl -sf --max-time 3 "http://localhost:${CALEOPE_PORT_WEB}/version" >/dev/null 2>&1; then
        _gt_ready=true; break
    fi
    sleep 3
done
if ${_gt_ready}; then
    _client_resp=$(curl -sf --max-time 10 -u "admin:${GOTIFY_DEFAULTUSER_PASS}" -X POST \
        "http://localhost:${CALEOPE_PORT_WEB}/client" \
        -H "Content-Type: application/json" \
        -d '{"name":"caleope-panel"}' 2>/dev/null) || _client_resp=""
    _token=$(echo "${_client_resp}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null) || _token=""
    if [ -n "${_token}" ]; then
        sed -i '/^GOTIFY_CLIENT_TOKEN/d' "${_SECRETS}"
        echo "GOTIFY_CLIENT_TOKEN=${_token}" >> "${_SECRETS}"
        echo "  ✓ Token client Gotify généré"
    else
        echo "  ⚠ Token Gotify non obtenu (login admin/password?)"
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Gotify — Notifications push                        │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Login : admin                                                   │
  │  Pass  : ${GOTIFY_DEFAULTUSER_PASS}                              │
  │    → Changer dans Settings → User Management                     │
  │                                                                  │
  │  App Android/iOS : Gotify (open source)                          │
  │  URL serveur pour l'app : https://${CALEOPE_DOMAIN}/             │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Gotify — Notifications push                ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL   : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login : admin"
echo "  ║  Pass  : ${GOTIFY_DEFAULTUSER_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Gotify configuré"
