#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/calibre-web"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/calibre-web/config"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/calibre-web/books"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Calibre-Web configuré"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Calibre-Web — Gestionnaire de livres               │
  ├──────────────────────────────────────────────────────────────────┤
  │  ⏳ Premier démarrage lent (~5 min) : installation du mod Calibre │
  │                                                                  │
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Identifiants par défaut :                                       │
  │    Login    : admin                                              │
  │    Password : admin123                                           │
  │                                                                  │
  │  ⚠ Changez le mot de passe immédiatement après connexion !        │
  │                                                                  │
  │  Bibliothèque Calibre :                                          │
  │    ${CALEOPE_BASE_DIR}/app-data/calibre-web/books/               │
  │  Configurez ce chemin dans Admin → Paramètres → Config DB        │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          Calibre-Web — Identifiants par défaut       ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login: admin"
echo "  ║  Pass : admin123  (à changer !)"
echo "  ║"
echo "  ║  ⚠ Premier boot ~5 min (téléchargement mod Calibre)  ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Calibre-Web configuré"
