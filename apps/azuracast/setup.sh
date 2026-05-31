#!/bin/bash
set -euo pipefail

trap 'echo "❌ setup.sh : erreur ligne ${LINENO} — ${BASH_COMMAND}" >&2' ERR

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"

# ── Nettoyage des containers défaillants ─────────────────────────────
# Si une installation précédente a échoué (ex: conflit de ports), les containers
# peuvent rester en état "exited" ou "created" avec des ports toujours réservés.
# On les supprime proprement avant de recréer.
for _ct in azuracast azuracast-bootstrap; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${_ct}$"; then
        echo "→ Nettoyage du container '${_ct}' (installation précédente)..."
        docker stop "${_ct}" 2>/dev/null || true
        docker rm   "${_ct}" 2>/dev/null || true
        echo "  ✓ Container '${_ct}' supprimé"
    fi
done

# ── Dossiers de données ───────────────────────────────────────────────
echo "→ Création de la structure de dossiers..."
mkdir -p "${CALEOPE_BASE_DIR}/app-data/azuracast/stations"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/azuracast/geoip"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/azuracast/backups"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/azuracast/acme"
chmod -R 777 "${CALEOPE_BASE_DIR}/app-data/azuracast"
echo "  ✓ Dossiers créés"

# ── Génération des secrets ────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MYSQL_PASSWORD=$(openssl rand -hex 20)
ADMIN_EMAIL="admin@azuracast.local"
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-16)

# ── Mode d'accès ─────────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  🌐 Mode d'accès                                                │"
echo "│                                                                 │"
echo "│  Domaine  → AzuraCast accessible sur https://azuracast.ton-    │"
echo "│             domaine.com (via Traefik, recommandé en prod)       │"
echo "│  Local    → AzuraCast accessible sur http://IP:PORT (sans       │"
echo "│             domaine, parfait pour tester en local)              │"
echo "└─────────────────────────────────────────────────────────────────┘"

USE_DOMAIN=true
SERVER_IP=""

INTERACTIVE=false
if [ -t 0 ]; then
    INTERACTIVE=true
fi

if [[ "${INTERACTIVE}" == "true" ]]; then
    read -rp "  Utiliser un nom de domaine ? [O/n] : " _DOM_ANSWER || _DOM_ANSWER="O"
    if [[ "${_DOM_ANSWER,,}" == "n" || "${_DOM_ANSWER,,}" == "non" ]]; then
        USE_DOMAIN=false
        read -rp "  Adresse IP du serveur (ex: 192.168.1.10) : " SERVER_IP || SERVER_IP=""
    fi
else
    echo "  (mode non-interactif → accès via domaine par défaut)"
fi

# Ports alloués par Caleope — passés via env vars CALEOPE_PORT_<NOM>
# Fallbacks raisonnables si jamais le script tourne hors Caleope.
WEB_PORT="${CALEOPE_PORT_WEB:-8099}"
SFTP_PORT="${CALEOPE_PORT_SFTP:-2022}"
ICECAST_PORT="${CALEOPE_PORT_ICECAST:-8500}"

if [[ "${USE_DOMAIN}" == "true" ]]; then
    AZURACAST_BASE_URL="https://${CALEOPE_DOMAIN}"
    echo "  ✓ URL publique  : ${AZURACAST_BASE_URL}"
    echo "  ✓ Accès direct  : http://${SERVER_IP:-<IP>}:${WEB_PORT} (si pas de domaine disponible)"
else
    AZURACAST_BASE_URL="http://${SERVER_IP:-<IP-DU-SERVEUR>}:${WEB_PORT}"
    echo "  ✓ Accès local : ${AZURACAST_BASE_URL}"
fi

# ── Station par défaut ────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  📻 Infos de ta radio                                           │"
echo "└─────────────────────────────────────────────────────────────────┘"

STATION_NAME="Ma Radio"
STATION_SHORT="maradio"

if [[ "${INTERACTIVE}" == "true" ]]; then
    read -rp "  Nom de ta station (ex: Radio Caleope) : " _STATION || _STATION=""
    if [[ -n "${_STATION}" ]]; then
        STATION_NAME="${_STATION}"
        # Générer un slug court : minuscules, sans espaces ni accents
        STATION_SHORT=$(echo "${STATION_NAME}" | tr '[:upper:]' '[:lower:]' \
            | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null \
            | sed 's/[^a-z0-9]//g' | cut -c1-16) || STATION_SHORT="maradio"
        [[ -z "${STATION_SHORT}" ]] && STATION_SHORT="maradio"
    fi
else
    echo "  (mode non-interactif → nom par défaut : ${STATION_NAME})"
fi

echo "  ✓ Station : ${STATION_NAME} (slug: ${STATION_SHORT})"

# ── secrets.env ──────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/secrets.env" <<EOF
# ── AzuraCast — généré par Caleope le $(date +%Y-%m-%d) ──────────────

# Environnement
APPLICATION_ENV=production
AZURACAST_VERSION=latest

# Ports internes AzuraCast (côté container — ne pas modifier)
AZURACAST_HTTP_PORT=80
# AZURACAST_HTTPS_PORT=443 : nginx a besoin d'une valeur valide pour générer sa config.
# Le port 443 n'est PAS exposé sur l'hôte (Traefik gère le SSL), AzuraCast utilise
# ses certs auto-signés internes — les auditeurs/admin passent uniquement par le port 80.
AZURACAST_HTTPS_PORT=443
AZURACAST_SFTP_PORT=2022

# Port Icecast alloué dynamiquement par Caleope.
# IMPORTANT : ce port doit être identique côté hôte ET côté container
# car Icecast annonce ce numéro de port dans les URLs de flux aux auditeurs.
# Le bootstrap crée la station AzuraCast avec ce port pour que Icecast l'écoute.
CALEOPE_PORT_ICECAST=${ICECAST_PORT}

# URL publique — utilisée pour les liens de flux et les emails
AZURACAST_BASE_URL=${AZURACAST_BASE_URL}

# Base de données (MariaDB interne)
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_USER=azuracast
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_DATABASE=azuracast

# Compte administrateur initial (utilisé par le bootstrap)
AZURACAST_ADMIN_EMAIL=${ADMIN_EMAIL}
AZURACAST_ADMIN_PASSWORD=${ADMIN_PASSWORD}

# Station par défaut (créée par le bootstrap)
AZURACAST_STATION_NAME=${STATION_NAME}
AZURACAST_STATION_SHORT=${STATION_SHORT}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"
echo "  ✓ Secrets générés"

# ── bootstrap.sh ─────────────────────────────────────────────────────
# Tourne dans un container alpine sur le réseau azuracast-internal.
# Attend qu'AzuraCast soit prêt, crée l'admin et configure la station initiale.
cat > "${CONFIG_DIR}/bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash
set -euo pipefail

AZ_URL="http://azuracast:80"
ADMIN_EMAIL="${AZURACAST_ADMIN_EMAIL:-admin@azuracast.local}"
ADMIN_PASSWORD="${AZURACAST_ADMIN_PASSWORD:-changeme}"
STATION_NAME="${AZURACAST_STATION_NAME:-Ma Radio}"
STATION_SHORT="${AZURACAST_STATION_SHORT:-maradio}"
# Port Icecast : lu depuis secrets.env (écrit par setup.sh via CALEOPE_PORT_ICECAST)
# Doit correspondre au port exposé côté hôte (host=container dans docker-compose).
ICECAST_PORT="${CALEOPE_PORT_ICECAST:-8500}"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  🎙 AzuraCast — Bootstrap automatique                            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

# ── Attente du démarrage ─────────────────────────────────────────────
# AzuraCast initialise MariaDB + Redis + Liquidsoap à la première exécution.
# Ça peut prendre 2-5 minutes → on attend jusqu'à 10 minutes.
echo "  ⏳ Attente du démarrage d'AzuraCast (peut prendre 3-5 min)..."
AZ_STATUS="000"
for _i in $(seq 1 60); do
    AZ_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${AZ_URL}/" 2>/dev/null) || AZ_STATUS="000"
    if [[ "${AZ_STATUS}" != "000" && "${AZ_STATUS}" != "502" && "${AZ_STATUS}" != "503" ]]; then
        echo "  ✓ AzuraCast répond (HTTP ${AZ_STATUS}) après ${_i}×10s"
        break
    fi
    echo "  ⏳  pas encore prêt (HTTP ${AZ_STATUS}) — attente 10s... (${_i}/60)"
    sleep 10
done

if [[ "${AZ_STATUS}" == "000" || "${AZ_STATUS}" == "503" ]]; then
    echo "  ⚠ AzuraCast ne répond toujours pas après 10 min — bootstrap ignoré"
    echo "    Configure le compte admin manuellement via l'interface web."
    exit 0
fi

# ── Vérifier si le setup est déjà fait ──────────────────────────────
sleep 3
REDIRECT_URL=$(curl -sf -o /dev/null -w "%{redirect_url}" "${AZ_URL}/" 2>/dev/null) || REDIRECT_URL=""

if echo "${REDIRECT_URL}" | grep -q "/setup"; then
    echo "  → Wizard de setup détecté — création du compte admin..."

    # Étape 1 : créer le compte administrateur via l'API de setup
    SETUP_RESP=$(curl -sf -X POST "${AZ_URL}/api/frontend/setup/registration" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"Admin\",
            \"email\": \"${ADMIN_EMAIL}\",
            \"password\": \"${ADMIN_PASSWORD}\",
            \"password_confirm\": \"${ADMIN_PASSWORD}\"
        }" 2>/dev/null) || SETUP_RESP=""

    if [[ -n "${SETUP_RESP}" ]]; then
        echo "  ✓ Compte admin créé (${ADMIN_EMAIL})"
    else
        echo "  ⚠ L'API de setup n'a pas répondu — le compte devra être créé via le wizard web"
        echo "    → Utilise les identifiants affichés dans post-install.txt"
    fi
else
    echo "  ℹ AzuraCast déjà configuré (pas de redirect vers /setup)"
fi

# ── Obtenir un token API ─────────────────────────────────────────────
sleep 2
AZ_TOKEN=$(curl -sf -X POST "${AZ_URL}/api/user/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null \
    | jq -r '.api_key // empty' 2>/dev/null) || AZ_TOKEN=""

if [[ -z "${AZ_TOKEN}" ]]; then
    echo "  ⚠ Impossible d'obtenir le token API — configuration de la station ignorée"
    echo "    (Si le compte admin n'a pas été créé, complète le wizard web puis ajoute ta station)"
else
    echo "  ✓ Authentification API réussie"

    # ── Vérifier si une station existe déjà ─────────────────────────
    EXISTING_STATIONS=$(curl -sf "${AZ_URL}/api/stations" \
        -H "X-API-Key: ${AZ_TOKEN}" 2>/dev/null \
        | jq 'length' 2>/dev/null) || EXISTING_STATIONS="0"

    if [[ "${EXISTING_STATIONS}" -gt 0 ]]; then
        echo "  ℹ Station(s) déjà configurée(s) — aucune création"
    else
        # ── Créer la station par défaut ──────────────────────────────
        echo "  → Création de la station '${STATION_NAME}'..."
        # frontend_config.port : port Icecast de la station.
        # Doit correspondre exactement au port exposé dans docker-compose (8500:8500).
        # Si host port ≠ container port, l'URL annoncée par AzuraCast serait incorrecte.
        STATION_RESP=$(curl -sf -X POST "${AZ_URL}/api/admin/stations" \
            -H "Content-Type: application/json" \
            -H "X-API-Key: ${AZ_TOKEN}" \
            -d "{
                \"name\": \"${STATION_NAME}\",
                \"short_name\": \"${STATION_SHORT}\",
                \"frontend_type\": \"icecast\",
                \"backend_type\": \"liquidsoap\",
                \"frontend_config\": {\"port\": ${ICECAST_PORT}},
                \"is_public\": false,
                \"enable_requests\": true,
                \"request_delay\": 5,
                \"request_threshold\": 15
            }" 2>/dev/null) || STATION_RESP=""

        if [[ -n "${STATION_RESP}" ]]; then
            STATION_ID=$(echo "${STATION_RESP}" | jq -r '.id // empty' 2>/dev/null) || STATION_ID=""
            echo "  ✓ Station '${STATION_NAME}' créée (ID: ${STATION_ID:-?})"
            echo "    Port Icecast : ${ICECAST_PORT} (HTTP) — accessible par tes auditeurs"
        else
            echo "  ⚠ Création de station échouée — à créer manuellement dans l'interface"
        fi
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ Bootstrap AzuraCast terminé !                                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"
echo "  ✓ Bootstrap créé"

# ── post-install.txt ─────────────────────────────────────────────────
if [[ "${USE_DOMAIN}" == "true" ]]; then
    ACCESS_URL="https://${CALEOPE_DOMAIN}"
    ACCESS_NOTE="(via Traefik)"
    ACCESS_DIRECT="http://${SERVER_IP:-<IP-serveur>}:${WEB_PORT}"
    ACCESS_DIRECT_NOTE="(accès direct sans domaine)"
else
    ACCESS_URL="http://${SERVER_IP:-<IP-serveur>}:${WEB_PORT}"
    ACCESS_NOTE="(accès direct — pas de domaine)"
    ACCESS_DIRECT=""
    ACCESS_DIRECT_NOTE=""
fi

cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════════════╗
║              🎙 AzuraCast — Premiers accès                           ║
╠══════════════════════════════════════════════════════════════════════╣
║  URL web         : ${ACCESS_URL}
║                    ${ACCESS_NOTE}
$([ -n "${ACCESS_DIRECT}" ] && echo "║  Accès direct    : ${ACCESS_DIRECT}")
$([ -n "${ACCESS_DIRECT}" ] && echo "║                    ${ACCESS_DIRECT_NOTE}")
║
║  Login admin     : ${ADMIN_EMAIL}
║  Mot de passe    : ${ADMIN_PASSWORD}
╠══════════════════════════════════════════════════════════════════════╣
║  📻 Station radio : ${STATION_NAME}
║
║  Ports alloués dynamiquement (voir aussi : caleope list) :
║    Web   : ${WEB_PORT}   → interface admin
║    SFTP  : ${SFTP_PORT}  → upload de musique (FileZilla, etc.)
║    Radio : ${ICECAST_PORT}  → flux Icecast (à ouvrir dans le pare-feu)
║
║  Exemple flux : http://<IP-serveur>:${ICECAST_PORT}/${STATION_SHORT}.mp3
║
║  Upload de musique via SFTP :
║    Hôte  : <IP-du-serveur>   Port : ${SFTP_PORT}
║    Login : (défini dans AzuraCast → Station → SFTP Users)
╠══════════════════════════════════════════════════════════════════════╣
║  ⚠️  PREMIER DÉMARRAGE                                               ║
║                                                                      ║
║  AzuraCast initialise sa base de données au démarrage (3-5 min).    ║
║  Si le wizard s'affiche, entre les identifiants ci-dessus.           ║
║                                                                      ║
║  Si la station n'a pas été créée automatiquement :                   ║
║    Administration → Stations → + Ajouter une station                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  🎛 COMMANDES UTILES                                                 ║
║                                                                      ║
║  Voir les logs     : docker logs azuracast -f                        ║
║  Restart           : docker restart azuracast                        ║
║  CLI AzuraCast     : docker exec -it azuracast azuracast_cli help    ║
║  Backup manuel     : docker exec azuracast azuracast_cli backup:run  ║
╚══════════════════════════════════════════════════════════════════════╝

Secrets sauvegardés dans : ${CONFIG_DIR}/secrets.env
EOF

echo ""
echo "✅ AzuraCast préparé avec succès !"
echo ""
echo "   Station     : ${STATION_NAME}"
echo "   Admin email : ${ADMIN_EMAIL}"
echo "   Admin mdp   : ${ADMIN_PASSWORD}"
echo ""
echo "   Ports alloués :"
echo "     Web   (UI admin)   : ${WEB_PORT}"
echo "     SFTP  (upload)     : ${SFTP_PORT}"
echo "     Radio (Icecast)    : ${ICECAST_PORT}"
echo ""
echo "   ⚠  Le premier démarrage prend 3-5 minutes (init base de données)."
