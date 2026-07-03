#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/filebrowser"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/filebrowser/db"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/filebrowser/conf"

cat > "${_SECRETS}" <<ENV
ENV
chmod 600 "${_SECRETS}"

# Créer le fichier de config filebrowser
FB_CONF="${CALEOPE_BASE_DIR}/app-data/filebrowser/conf/.filebrowser.json"
cat > "${FB_CONF}" <<CONF
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database/filebrowser.db",
  "root": "/srv"
}
CONF
chmod 644 "${FB_CONF}"

# Supprimer la DB pour forcer la réinitialisation
rm -f "${CALEOPE_BASE_DIR}/app-data/filebrowser/db/filebrowser.db"

# bootstrap.sh: attend le démarrage puis récupère le mot de passe généré
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh

# Filebrowser génère un mot de passe aléatoire au 1er démarrage
# On attend puis on le capture depuis les logs

MAX_WAIT=60
WAITED=0
CONTAINER_NAME="filebrowser"

echo "→ Filebrowser bootstrap : attente du démarrage..."
until docker inspect --format="{{.State.Running}}" "${CONTAINER_NAME}" 2>/dev/null | grep -q "true"; do
    sleep 3
    WAITED=$((WAITED + 3))
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        echo "❌ Timeout"
        exit 1
    fi
done

sleep 2
RANDOM_PASS=$(docker logs "${CONTAINER_NAME}" 2>&1 | grep "randomly generated password:" | grep -oP "password: \K\S+" | tail -1)
if [ -n "${RANDOM_PASS}" ]; then
    echo "  ✓ Filebrowser admin password: ${RANDOM_PASS}"
    echo "    (noté ci-dessus — à changer dans Admin → User Management)"
fi
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              File Browser — Gestionnaire de fichiers             │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Login : admin                                                   │
  │  Pass  : voir sortie ci-dessus (mot de passe aléatoire)          │
  │          ou : docker logs filebrowser | grep randomly            │
  │                                                                  │
  │  Changez le mot de passe : Admin → User Management              │
  └──────────────────────────────────────────────────────────────────┘
INFO

# Afficher le mot de passe après le démarrage du conteneur
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║            File Browser — En démarrage...            ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL   : https://${CALEOPE_DOMAIN}/"
echo "  ║  Login : admin"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  → Mot de passe : docker logs filebrowser | grep randomly"
echo ""
echo "✓ File Browser configuré"
