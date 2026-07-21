#!/bin/bash
# setup.sh — Element (client web Matrix)
set -euo pipefail
echo "→ Préparation d'Element..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"

# ── Détecter le serveur Matrix installé ──────────────────────────────────────
MX_DIR="${CALEOPE_BASE_DIR}/apps-installed/matrix"
MX_DOMAIN=""
if [ -d "${MX_DIR}" ]; then
    MX_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${MX_DIR}/app.env" 2>/dev/null | cut -d= -f2-) || true
fi
if [ -z "${MX_DOMAIN}" ]; then
    # Repli : convention matrix.<domaine de base>
    MX_DOMAIN="matrix.${CALEOPE_DOMAIN#*.}"
    echo "  ⚠ App Matrix non détectée — Element pointera sur https://${MX_DOMAIN}"
    echo "    (installe l'app « Matrix » ; sinon règle le serveur au 1er écran d'Element)"
else
    echo "  ✓ Serveur Matrix détecté : ${MX_DOMAIN}"
fi

cat > "${CONFIG_DIR}/config.json" <<JSON
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${MX_DOMAIN}",
      "server_name": "${MX_DOMAIN}"
    }
  },
  "brand": "Element",
  "disable_guests": true,
  "disable_3pid_login": true,
  "default_theme": "dark"
}
JSON
chmod 644 "${CONFIG_DIR}/config.json"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                 Element — Client web Matrix                     │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │  Serveur   : https://${MX_DOMAIN}                                │
  │  Connexion avec un compte créé sur le serveur Matrix.           │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Element configuré (serveur ${MX_DOMAIN})"
