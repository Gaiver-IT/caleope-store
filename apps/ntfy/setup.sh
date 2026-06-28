#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/ntfy"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/ntfy/data"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/ntfy/config"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"

# ntfy config
NTFY_CONF="${CALEOPE_BASE_DIR}/app-data/ntfy/config/server.yml"
if [ ! -f "${NTFY_CONF}" ]; then
    cat > "${NTFY_CONF}" <<CONF
base-url: "https://${CALEOPE_DOMAIN}"
listen-http: ":80"
cache-file: "/var/lib/ntfy/cache.db"
auth-file: "/var/lib/ntfy/auth.db"
auth-default-access: "deny-all"
behind-proxy: true
CONF
    chmod 644 "${NTFY_CONF}"
fi

# ntfy ne supporte pas nativement OIDC → ForwardAuth Authentik acceptable

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               ntfy — Notifications push                          │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Créer un compte admin via CLI :                                 │
  │    docker exec ntfy ntfy user add --role=admin <username>        │
  │                                                                  │
  │  Envoyer une notification :                                      │
  │    curl -d "Hello" https://${CALEOPE_DOMAIN}/alerts              │
  │  Docs : https://docs.ntfy.sh/                                    │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           ntfy — Notifications push                  ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL : https://${CALEOPE_DOMAIN}/"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ ntfy configuré"
