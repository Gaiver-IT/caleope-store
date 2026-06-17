#!/bin/bash
# setup.sh — Restic (outil de backup déduplication)
set -euo pipefail
echo "→ Installation de Restic..."

# Vérifier si déjà installé
if command -v restic >/dev/null 2>&1; then
    CURRENT_VERSION=$(restic version 2>/dev/null | head -1 || echo "inconnu")
    echo "  ✓ Restic déjà installé : ${CURRENT_VERSION}"
    cat > "${CALEOPE_APP_DIR}/post-install.txt" << 'POSTEOF'

  ┌──────────────────────────────────────────────────────────────────┐
  │                   Restic — Outil de backup                       │
  ├──────────────────────────────────────────────────────────────────┤
  │  Déjà installé. Prêt pour les backups Caleope.                  │
  │                                                                  │
  │  Usage :                                                         │
  │    caleope backup <app> --restic --repo sftp:user@host:/path    │
  │    caleope backup <app> --restic --repo /chemin/local            │
  │                                                                  │
  │  Requis : RESTIC_PASSWORD=<mot-de-passe> dans l'environnement   │
  └──────────────────────────────────────────────────────────────────┘
POSTEOF
    exit 0
fi

# ── Tentative via apt (Debian/Ubuntu) ────────────────────────────────────────
if command -v apt-get >/dev/null 2>&1; then
    echo "  → Tentative via apt..."
    if apt-get install -y restic >/dev/null 2>&1; then
        echo "  ✓ Restic installé via apt"
    else
        echo "  → apt échoué, téléchargement du binaire officiel..."
        _install_restic_binary
    fi
else
    _install_restic_binary
fi

# ── Fonction d'installation via binaire officiel ──────────────────────────────
_install_restic_binary() {
    local RESTIC_VERSION
    RESTIC_VERSION=$(curl -fsSL "https://api.github.com/repos/restic/restic/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null \
        || echo "0.17.3")

    local RESTIC_URL="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"

    echo "  → Téléchargement de restic v${RESTIC_VERSION}..."
    local TMP
    TMP=$(mktemp)
    curl -fsSL "${RESTIC_URL}" -o "${TMP}.bz2"
    bunzip2 "${TMP}.bz2"
    install -m 755 "${TMP}" /usr/local/bin/restic
    rm -f "${TMP}"
    echo "  ✓ Restic v${RESTIC_VERSION} installé dans /usr/local/bin/restic"
}

# ── Vérification finale ───────────────────────────────────────────────────────
INSTALLED_VERSION=$(restic version 2>/dev/null | head -1 || echo "inconnu")
echo "  ✓ Restic installé : ${INSTALLED_VERSION}"

cat > "${CALEOPE_APP_DIR}/post-install.txt" << 'POSTEOF'

  ┌──────────────────────────────────────────────────────────────────┐
  │                   Restic — Outil de backup                       │
  ├──────────────────────────────────────────────────────────────────┤
  │  Restic est installé et prêt pour les backups Caleope.          │
  │                                                                  │
  │  Usage :                                                         │
  │    caleope backup <app> --restic --repo sftp:user@host:/path    │
  │    caleope backup <app> --restic --repo /chemin/local            │
  │                                                                  │
  │  Variables d'environnement requises :                            │
  │    RESTIC_PASSWORD=<mot-de-passe>                                │
  │    ou RESTIC_PASSWORD_FILE=/chemin/vers/fichier-password         │
  │                                                                  │
  │  Initialiser un dépôt manuellement :                             │
  │    restic -r sftp:user@host:/backups/caleope init                │
  │                                                                  │
  │  Caleope initialise le dépôt automatiquement si nécessaire.     │
  └──────────────────────────────────────────────────────────────────┘
POSTEOF

echo ""
echo "✓ Restic prêt pour les backups Caleope"
