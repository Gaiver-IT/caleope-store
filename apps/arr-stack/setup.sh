#!/bin/bash
set -euo pipefail

# Trap pour identifier la ligne exacte en cas d'erreur
trap 'echo "❌ setup.sh : erreur ligne ${LINENO} — ${BASH_COMMAND}" >&2' ERR

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"

# ── Chemin de stockage média ──────────────────────────────────────────
STORAGE_PATH="${CALEOPE_PARAM_STORAGE_PATH:-${CALEOPE_BASE_DIR}/app-data/arr-stack/data}"

mkdir -p "${CONFIG_DIR}"

# ── Structure de dossiers ─────────────────────────────────────────────
echo "→ Création de la structure de dossiers..."
mkdir -p "${STORAGE_PATH}/downloads/complete/movies" \
         "${STORAGE_PATH}/downloads/complete/tv" \
         "${STORAGE_PATH}/downloads/complete/music" \
         "${STORAGE_PATH}/downloads/complete/books" \
         "${STORAGE_PATH}/downloads/incomplete" \
         "${STORAGE_PATH}/media/movies" \
         "${STORAGE_PATH}/media/tv" \
         "${STORAGE_PATH}/media/music" \
         "${STORAGE_PATH}/media/books"

if [[ "${STORAGE_PATH}" != "${CALEOPE_BASE_DIR}/app-data/arr-stack/data" ]]; then
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack"
    ln -sfn "${STORAGE_PATH}" "${CALEOPE_BASE_DIR}/app-data/arr-stack/data"
    echo "   ✓ Données liées vers : ${STORAGE_PATH}"
fi

for app in prowlarr radarr sonarr lidarr bazarr qbittorrent sabnzbd jellyseerr; do
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}"
done

# ── Détecter PUID/PGID ───────────────────────────────────────────────
PUID=$(id -u)
PGID=$(id -g)

# ── Générer les secrets ───────────────────────────────────────────────
API_PROWLARR=$(openssl rand -hex 16)
API_RADARR=$(openssl rand -hex 16)
API_SONARR=$(openssl rand -hex 16)
API_LIDARR=$(openssl rand -hex 16)
API_SABNZBD=$(openssl rand -hex 16)
QBT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-14)

# ── Détection mode interactif ─────────────────────────────────────────
# Sans terminal (binaire non mis à jour), on applique les valeurs par défaut.
INTERACTIVE=false
if [ -t 0 ]; then
    INTERACTIVE=true
fi

# ══════════════════════════════════════════════════════════════════════
# JELLYFIN — WIZARD
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  🎬 Jellyfin — serveur multimédia                               │"
echo "└─────────────────────────────────────────────────────────────────┘"

JELLYFIN_EMBEDDED=false
JELLYFIN_INT_URL=""
JELLYFIN_PASSWORD=""
JELLYFIN_USER="admin"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^jellyfin$'; then
    # Jellyfin déjà en cours
    echo "  ℹ  Jellyfin détecté (container existant)"
    _JF_REUSE="O"
    if [[ "${INTERACTIVE}" == "true" ]]; then
        read -rp "  Utiliser ce Jellyfin existant ? [O/n] : " _JF_REUSE || _JF_REUSE="O"
    fi
    if [[ "${_JF_REUSE,,}" == "n" || "${_JF_REUSE,,}" == "non" ]]; then
        JELLYFIN_EMBEDDED=true
        JELLYFIN_INT_URL="http://jellyfin:8096"
    else
        _JF_IP=$(docker inspect jellyfin 2>/dev/null \
            | grep '"IPAddress"' | grep -v '""' | head -1 \
            | grep -o '[0-9.]*') || _JF_IP=""
        if [[ -n "${_JF_IP}" ]]; then
            JELLYFIN_INT_URL="http://${_JF_IP}:8096"
            echo "  ✓ Jellyfin existant utilisé : ${JELLYFIN_INT_URL}"
        else
            JELLYFIN_INT_URL=""
            if [[ "${INTERACTIVE}" == "true" ]]; then
                read -rp "  URL interne Jellyfin (ex: http://192.168.1.x:8096) : " \
                    JELLYFIN_INT_URL || JELLYFIN_INT_URL=""
            fi
            echo "  ✓ Jellyfin externe : ${JELLYFIN_INT_URL}"
        fi
    fi
else
    # Pas de Jellyfin détecté
    echo "  Jellyfin n'est pas installé."
    _JF_INSTALL="O"
    if [[ "${INTERACTIVE}" == "true" ]]; then
        read -rp "  L'inclure dans la stack ? [O/n] : " _JF_INSTALL || _JF_INSTALL="O"
    else
        echo "  (mode non-interactif → Jellyfin inclus par défaut)"
    fi
    if [[ "${_JF_INSTALL,,}" != "n" && "${_JF_INSTALL,,}" != "non" ]]; then
        JELLYFIN_EMBEDDED=true
        JELLYFIN_INT_URL="http://jellyfin:8096"
        JELLYFIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-14)
        echo "  ✓ Jellyfin sera installé dans la stack"
        echo "    Compte admin : ${JELLYFIN_USER} / ${JELLYFIN_PASSWORD}"
    else
        JELLYFIN_INT_URL=""
        if [[ "${INTERACTIVE}" == "true" ]]; then
            read -rp "  URL de ton Jellyfin (ex: http://192.168.1.x:8096) : " \
                JELLYFIN_INT_URL || JELLYFIN_INT_URL=""
        fi
        echo "  ✓ Jellyfin externe : ${JELLYFIN_INT_URL}"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
# VPN — WIZARD INTERACTIF
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  🔒 VPN pour qBittorrent                                        │"
echo "│                                                                 │"
echo "│  Recommandé pour isoler le trafic torrent derrière un VPN.     │"
echo "│  Utilise Gluetun — compatible ProtonVPN, Mullvad, NordVPN…     │"
echo "└─────────────────────────────────────────────────────────────────┘"

VPN_ENABLED=false
VPN_PROVIDER=""
VPN_TYPE=""
VPN_WG_PRIVATE_KEY=""
VPN_WG_ADDRESSES=""
VPN_OPENVPN_USER=""
VPN_OPENVPN_PASSWORD=""
VPN_SERVER_COUNTRIES=""
COMPOSE_PROFILES="novpn"
QBT_HOST="qbittorrent"

_VPN_ANSWER="N"
if [[ "${INTERACTIVE}" == "true" ]]; then
    read -rp "  Activer un VPN ? [o/N] : " _VPN_ANSWER || _VPN_ANSWER="N"
else
    echo "  (mode non-interactif → VPN désactivé par défaut)"
fi

if [[ "${_VPN_ANSWER,,}" == "o" || "${_VPN_ANSWER,,}" == "oui" || \
      "${_VPN_ANSWER,,}" == "y" || "${_VPN_ANSWER,,}" == "yes" ]]; then

    VPN_ENABLED=true
    COMPOSE_PROFILES="vpn"
    QBT_HOST="arr-gluetun"

    echo ""
    echo "  Fournisseur VPN :"
    echo "    1) ProtonVPN  (recommandé)"
    echo "    2) Mullvad"
    echo "    3) NordVPN"
    echo "    4) Private Internet Access (PIA)"
    echo "    5) Surfshark"
    echo "    6) ExpressVPN"
    echo "    7) Autre (compatible Gluetun)"
    _PROVIDER_CHOICE="1"
    if [[ "${INTERACTIVE}" == "true" ]]; then
        read -rp "  Choix [1-7] : " _PROVIDER_CHOICE || _PROVIDER_CHOICE="1"
    fi

    case "${_PROVIDER_CHOICE}" in
        1) VPN_PROVIDER="protonvpn" ;;
        2) VPN_PROVIDER="mullvad" ;;
        3) VPN_PROVIDER="nordvpn" ;;
        4) VPN_PROVIDER="private internet access" ;;
        5) VPN_PROVIDER="surfshark" ;;
        6) VPN_PROVIDER="expressvpn" ;;
        7)
            VPN_PROVIDER=""
            if [[ "${INTERACTIVE}" == "true" ]]; then
                read -rp "  Nom du fournisseur Gluetun (ex: ivpn) : " VPN_PROVIDER || VPN_PROVIDER=""
            fi
            ;;
        *) VPN_PROVIDER="protonvpn" ;;
    esac

    echo ""
    echo "  Protocole :"
    echo "    1) WireGuard  (recommandé — plus rapide, plus simple)"
    echo "    2) OpenVPN    (plus compatible, légèrement plus lent)"
    _PROTO_CHOICE="1"
    if [[ "${INTERACTIVE}" == "true" ]]; then
        read -rp "  Choix [1/2] : " _PROTO_CHOICE || _PROTO_CHOICE="1"
    fi

    if [[ "${_PROTO_CHOICE}" == "2" ]]; then
        VPN_TYPE="openvpn"
        echo ""
        echo "  ── Identifiants OpenVPN ──────────────────────────────────────"
        if [[ "${INTERACTIVE}" == "true" ]]; then
            read -rp "  Nom d'utilisateur : " VPN_OPENVPN_USER || VPN_OPENVPN_USER=""
            read -rsp "  Mot de passe      : " VPN_OPENVPN_PASSWORD || VPN_OPENVPN_PASSWORD=""
            echo ""
        fi
    else
        VPN_TYPE="wireguard"
        echo ""
        echo "  ── Clé WireGuard ─────────────────────────────────────────────"
        if [[ "${VPN_PROVIDER}" == "protonvpn" ]]; then
            echo "  → account.proton.me → VPN → Télécharger → WireGuard"
            echo "    Sélectionne le serveur souhaité (SecureCore inclus)"
            echo "    Copie les champs PrivateKey et Address de la section [Interface]"
        elif [[ "${VPN_PROVIDER}" == "mullvad" ]]; then
            echo "  → mullvad.net/account/wireguard-config"
        fi
        echo ""
        if [[ "${INTERACTIVE}" == "true" ]]; then
            read -rp "  Clé privée WireGuard (PrivateKey) : " VPN_WG_PRIVATE_KEY || VPN_WG_PRIVATE_KEY=""
            read -rp "  Adresse WireGuard (Address, ex: 10.2.0.2/32) : " \
                VPN_WG_ADDRESSES || VPN_WG_ADDRESSES=""
        fi
    fi

    echo ""
    if [[ "${INTERACTIVE}" == "true" ]]; then
        echo "  Pays de sortie VPN — nom complet en anglais (ex: Germany, France, Netherlands)"
        if [[ "${VPN_PROVIDER}" == "protonvpn" ]]; then
            echo "  → SecureCore IS→DE : entrer 'Germany'  (pays de sortie uniquement)"
        fi
        read -rp "  Pays du serveur VPN (optionnel, Entrée pour ignorer) : " \
            VPN_SERVER_COUNTRIES || VPN_SERVER_COUNTRIES=""
    fi
    echo "  ✓ VPN configuré : ${VPN_PROVIDER} / ${VPN_TYPE}"
fi

# Ajouter le profil jellyfin si embarqué
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    COMPOSE_PROFILES="${COMPOSE_PROFILES},jellyfin"
fi

# ── secrets.env ──────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/secrets.env" <<EOF
ARR_PUID=${PUID}
ARR_PGID=${PGID}
ARR_TZ=Europe/Paris
ARR_STORAGE_PATH=${STORAGE_PATH}
ARR_API_PROWLARR=${API_PROWLARR}
ARR_API_RADARR=${API_RADARR}
ARR_API_SONARR=${API_SONARR}
ARR_API_LIDARR=${API_LIDARR}
ARR_API_SABNZBD=${API_SABNZBD}
ARR_QBT_PASSWORD=${QBT_PASSWORD}
ARR_QBT_HOST=${QBT_HOST}

# Profils Docker Compose actifs
COMPOSE_PROFILES=${COMPOSE_PROFILES}

# Jellyfin
ARR_JELLYFIN_EMBEDDED=${JELLYFIN_EMBEDDED}
ARR_JELLYFIN_INT_URL=${JELLYFIN_INT_URL}
ARR_JELLYFIN_USER=${JELLYFIN_USER}
ARR_JELLYFIN_PASSWORD=${JELLYFIN_PASSWORD}

# VPN (Gluetun) — vide si désactivé
ARR_VPN_PROVIDER=${VPN_PROVIDER}
ARR_VPN_TYPE=${VPN_TYPE}
ARR_VPN_WG_PRIVATE_KEY=${VPN_WG_PRIVATE_KEY}
ARR_VPN_WG_ADDRESSES=${VPN_WG_ADDRESSES}
ARR_VPN_OPENVPN_USER=${VPN_OPENVPN_USER}
ARR_VPN_OPENVPN_PASSWORD=${VPN_OPENVPN_PASSWORD}
ARR_VPN_SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── config.xml *arr ───────────────────────────────────────────────────
write_arr_config() {
    local app=$1 port=$2 apikey=$3
    local cfg="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}/config.xml"
    [[ -f "${cfg}" ]] && return 0
    # UrlBase vide = pas de préfixe (sous-domaine).
    # AuthenticationMethod=External = auth déléguée au reverse proxy.
    # Pas de AuthenticationRequired → évite les incompatibilités DryIoc v2.x.
    cat > "${cfg}" <<XMLEOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${port}</Port>
  <UrlBase></UrlBase>
  <EnableSsl>False</EnableSsl>
  <ApiKey>${apikey}</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <UpdateMechanism>Docker</UpdateMechanism>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
</Config>
XMLEOF
}

write_arr_config prowlarr 9696 "${API_PROWLARR}"
write_arr_config radarr   7878 "${API_RADARR}"
write_arr_config sonarr   8989 "${API_SONARR}"
write_arr_config lidarr   8686 "${API_LIDARR}"

# ── Jellyfin network.xml ──────────────────────────────────────────────
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack/config/jellyfin/config"
    JF_NET_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/jellyfin/config/network.xml"
    if [[ ! -f "${JF_NET_CFG}" ]]; then
        cat > "${JF_NET_CFG}" <<JFNET
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration>
  <BaseUrl></BaseUrl>
  <EnableHttps>false</EnableHttps>
  <RequireHttps>false</RequireHttps>
  <EnableRemoteAccess>true</EnableRemoteAccess>
</NetworkConfiguration>
JFNET
    fi
fi

# ── Bazarr config ─────────────────────────────────────────────────────
# Sonarr + Radarr pré-connectés au démarrage (config.ini lu par Bazarr à l'init)
BAZARR_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/bazarr/config.ini"
if [[ ! -f "${BAZARR_CFG}" ]]; then
    cat > "${BAZARR_CFG}" <<BAZARRCFG
[general]
base_url = /
ip = 0.0.0.0
port = 6767

[sonarr]
enabled = True
ip = sonarr
port = 8989
base_url = /
apikey = ${API_SONARR}
full_update = Weekly

[radarr]
enabled = True
ip = radarr
port = 7878
base_url = /
apikey = ${API_RADARR}
full_update = Weekly
BAZARRCFG
fi

# ── qBittorrent config ────────────────────────────────────────────────
QBT_CFG_DIR="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/qbittorrent/qBittorrent"
mkdir -p "${QBT_CFG_DIR}"
if [[ ! -f "${QBT_CFG_DIR}/qBittorrent.conf" ]]; then
    cat > "${QBT_CFG_DIR}/qBittorrent.conf" <<QBTCFG
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray()"
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=172.0.0.0/8, 10.0.0.0/8, 192.168.0.0/16
WebUI\LocalHostAuth=false
Downloads\SavePath=/data/downloads/complete
Downloads\TempPath=/data/downloads/incomplete
Downloads\TempPathEnabled=true
QBTCFG
fi

# ── SABnzbd config ────────────────────────────────────────────────────
SABNZBD_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/sabnzbd/sabnzbd.ini"
if [[ ! -f "${SABNZBD_CFG}" ]]; then
    cat > "${SABNZBD_CFG}" <<SABCFG
[misc]
api_key = ${API_SABNZBD}
nzb_key = ${API_SABNZBD}
url_base = /
host = 0.0.0.0
port = 8080
complete_dir = /data/downloads/complete
incomplete_dir = /data/downloads/incomplete
host_whitelist = sabnzbd.${CALEOPE_DOMAIN}
SABCFG
fi

# ── Bootstrap script ──────────────────────────────────────────────────
cat > "${CONFIG_DIR}/bootstrap.sh" <<BOOTSTRAP
#!/bin/bash
# Pas de set -e : on veut continuer même si une étape optionnelle échoue.
# Chaque appel API utilise || true pour ne pas bloquer.

# Flush immédiat vers Docker logs (évite le buffering ligne)
exec > /dev/stdout 2>&1

P_URL="http://prowlarr:9696"
R_URL="http://radarr:7878"
S_URL="http://sonarr:8989"
L_URL="http://lidarr:8686"
QBT_URL="http://\${ARR_QBT_HOST:-${QBT_HOST}}:8080"
JF_URL="${JELLYFIN_INT_URL}"

# ── wait_arr : attend qu'un service *arr réponde (timeout 10 min) ──────
wait_arr() {
    local name=\$1 url=\$2 key=\$3
    local tries=0 maxTries=120  # 120 * 5s = 10 min max
    echo "→ Attente \${name}..."
    until curl -sf -H "X-Api-Key: \$key" "\$url/api/v3/system/status" >/dev/null 2>&1 \
       || curl -sf -H "X-Api-Key: \$key" "\$url/api/v1/system/status" >/dev/null 2>&1; do
        sleep 5
        tries=\$((tries + 1))
        [[ \$tries -ge \$maxTries ]] && { echo "  ⚠ \${name} : timeout (10 min) — on continue quand même"; return 0; }
        [[ \$(( tries % 12 )) -eq 0 ]] && echo "  ... \${name} pas encore prêt (\$(( tries * 5 ))s)..."
    done
    echo "  ✓ \${name} prêt"
}

# ── wait_url : attend qu'une URL HTTP réponde (timeout 10 min) ─────────
wait_url() {
    local name=\$1 url=\$2
    local tries=0 maxTries=120
    echo "→ Attente \${name}..."
    until curl -sf "\$url" >/dev/null 2>&1; do
        sleep 5
        tries=\$((tries + 1))
        [[ \$tries -ge \$maxTries ]] && { echo "  ⚠ \${name} : timeout — on continue quand même"; return 0; }
        [[ \$(( tries % 12 )) -eq 0 ]] && echo "  ... \${name} pas encore prêt (\$(( tries * 5 ))s)..."
    done
    echo "  ✓ \${name} prêt"
}

api_post() {
    curl -sf -X POST "\$1" \
        -H "X-Api-Key: \$2" \
        -H "Content-Type: application/json" \
        -d "\$3" >/dev/null 2>&1 || true
}

api_post_v3() { api_post "\${1}/api/v3/\${3}" "\$2" "\$4"; }
api_post_v1() { api_post "\${1}/api/v1/\${3}" "\$2" "\$4"; }

echo "╔════════════════════════════════════════╗"
echo "║   Arr Stack — Bootstrap automatique    ║"
echo "╚════════════════════════════════════════╝"
echo ""

echo "── [1/6] Attente du démarrage des services..."
wait_arr "Prowlarr"    "\$P_URL"  "\$ARR_API_PROWLARR"
wait_arr "Radarr"      "\$R_URL"  "\$ARR_API_RADARR"
wait_arr "Sonarr"      "\$S_URL"  "\$ARR_API_SONARR"
wait_arr "Lidarr"      "\$L_URL"  "\$ARR_API_LIDARR"
wait_url "qBittorrent" "\$QBT_URL/api/v2/app/version"
wait_url "Bazarr"      "http://bazarr:6767"

echo ""
echo "── [2/6] Connexion Prowlarr → *arr + FlareSolverr..."

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Radarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Radarr\",\"implementation\":\"Radarr\",\"configContract\":\"RadarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://radarr:7878\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_RADARR\"},{\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060]}]}"
echo "  ✓ Prowlarr → Radarr"

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Sonarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Sonarr\",\"implementation\":\"Sonarr\",\"configContract\":\"SonarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://sonarr:8989\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_SONARR\"},{\"name\":\"syncCategories\",\"value\":[5000,5010,5020,5030,5040,5045,5050]}]}"
echo "  ✓ Prowlarr → Sonarr"

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Lidarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Lidarr\",\"implementation\":\"Lidarr\",\"configContract\":\"LidarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://lidarr:8686\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_LIDARR\"},{\"name\":\"syncCategories\",\"value\":[3000,3010,3020,3030,3040]}]}"
echo "  ✓ Prowlarr → Lidarr"

# FlareSolverr — proxy pour contourner Cloudflare sur les indexeurs protégés
api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "indexerproxy" \
    "{\"name\":\"FlareSolverr\",\"implementationName\":\"FlareSolverr\",\"implementation\":\"FlareSolverr\",\"configContract\":\"FlareSolverrSettings\",\"supportsRss\":false,\"supportsSearch\":false,\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"http://arr-flaresolverr:8191\"},{\"name\":\"requestTimeout\",\"value\":60}]}"
echo "  ✓ Prowlarr → FlareSolverr (http://arr-flaresolverr:8191)"

echo ""
echo "── [3/6] Clients de téléchargement + dossiers racine..."

qbt_client() {
    echo "{\"name\":\"qBittorrent\",\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"implementationName\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"${QBT_HOST}\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"username\",\"value\":\"\"},{\"name\":\"password\",\"value\":\"\"},{\"name\":\"\${1}Category\",\"value\":\"\$2\"},{\"name\":\"initialState\",\"value\":0}]}"
}

sab_client() {
    echo "{\"name\":\"SABnzbd\",\"enable\":true,\"protocol\":\"usenet\",\"priority\":1,\"implementationName\":\"SABnzbd\",\"implementation\":\"Sabnzbd\",\"configContract\":\"SabnzbdSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"sabnzbd\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_SABNZBD\"},{\"name\":\"urlBase\",\"value\":\"/\"},{\"name\":\"\${1}Category\",\"value\":\"\$1\"}]}"
}

api_post_v3 "\$R_URL" "\$ARR_API_RADARR" "downloadclient" "\$(qbt_client movie movies)"
api_post_v3 "\$R_URL" "\$ARR_API_RADARR" "downloadclient" "\$(sab_client movie)"
api_post_v3 "\$R_URL" "\$ARR_API_RADARR" "rootfolder"     "{\"path\":\"/data/media/movies\"}"
echo "  ✓ Radarr configuré"

api_post_v3 "\$S_URL" "\$ARR_API_SONARR" "downloadclient" "\$(qbt_client series tv)"
api_post_v3 "\$S_URL" "\$ARR_API_SONARR" "downloadclient" "\$(sab_client series)"
api_post_v3 "\$S_URL" "\$ARR_API_SONARR" "rootfolder"     "{\"path\":\"/data/media/tv\"}"
echo "  ✓ Sonarr configuré"

api_post_v1 "\$L_URL" "\$ARR_API_LIDARR" "downloadclient" "\$(qbt_client music music)"
api_post_v1 "\$L_URL" "\$ARR_API_LIDARR" "downloadclient" "\$(sab_client music)"
api_post_v1 "\$L_URL" "\$ARR_API_LIDARR" "rootfolder"     "{\"path\":\"/data/media/music\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\"}"
echo "  ✓ Lidarr configuré"

echo ""
echo "── [4/6] Langue française..."

# set_lang_fr <url> <apikey> <apiversion>
# Récupère l'ID de "French" dans l'API de l'app et met à jour l'UI language.
set_lang_fr() {
    local url=\$1 key=\$2 ver=\$3
    local fr_id
    fr_id=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/language" 2>/dev/null \
        | jq -r '.[] | select(.name == "French") | .id // empty' 2>/dev/null)
    [[ -z "\$fr_id" || "\$fr_id" == "null" ]] && return 0
    local ui_cfg
    ui_cfg=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/config/ui" 2>/dev/null)
    [[ -z "\$ui_cfg" ]] && return 0
    echo "\$ui_cfg" | jq --argjson lang "\$fr_id" '.uiLanguage = \$lang' \
    | curl -sf -X PUT "\$url/api/\$ver/config/ui" \
        -H "X-Api-Key: \$key" -H "Content-Type: application/json" \
        -d @- >/dev/null 2>&1 || true
}

set_lang_fr "\$P_URL" "\$ARR_API_PROWLARR" v1 && echo "  ✓ Prowlarr → français"
set_lang_fr "\$R_URL" "\$ARR_API_RADARR"   v3 && echo "  ✓ Radarr → français"
set_lang_fr "\$S_URL" "\$ARR_API_SONARR"   v3 && echo "  ✓ Sonarr → français"
set_lang_fr "\$L_URL" "\$ARR_API_LIDARR"   v1 && echo "  ✓ Lidarr → français"

# Bazarr — créer un profil de sous-titres Français + Anglais
BAZARR_URL="http://bazarr:6767"
curl -sf -X POST "\$BAZARR_URL/api/bazarr/languagesprofiles" \
    -H "Content-Type: application/json" \
    -d '{"name":"Français + Anglais","cutoff":null,"items":[{"id":1,"language":"fr","hi":"False","forced":"False","audio_exclude":"False"},{"id":2,"language":"en","hi":"False","forced":"False","audio_exclude":"False"}]}' \
    >/dev/null 2>&1 || true
# Récupérer l'ID du profil créé
BAZARR_PROFILE_ID=\$(curl -sf "\$BAZARR_URL/api/bazarr/languagesprofiles" 2>/dev/null \
    | jq -r '.[] | select(.name == "Français + Anglais") | .profileid // empty' 2>/dev/null) || BAZARR_PROFILE_ID=""
if [[ -n "\$BAZARR_PROFILE_ID" && "\$BAZARR_PROFILE_ID" != "null" ]]; then
    # Appliquer à toutes les séries et films existants (et futurs via défaut)
    curl -sf -X POST "\$BAZARR_URL/api/bazarr/series/all" \
        -H "Content-Type: application/json" \
        -d "{\"profileid\": \$BAZARR_PROFILE_ID}" >/dev/null 2>&1 || true
    curl -sf -X POST "\$BAZARR_URL/api/bazarr/movies/all" \
        -H "Content-Type: application/json" \
        -d "{\"profileid\": \$BAZARR_PROFILE_ID}" >/dev/null 2>&1 || true
    echo "  ✓ Bazarr → profil sous-titres Français + Anglais"
else
    echo "  ⚠ Bazarr : profil de langue non créé (configuration manuelle)"
fi

echo ""
echo "── [5/6] Jellyfin — configuration des bibliothèques..."

if [[ -z "\$JF_URL" ]]; then
    echo "  ⚠ Pas d'URL Jellyfin — étape ignorée"
else
    printf "→ Attente Jellyfin..."
    until curl -sf "\$JF_URL/health" >/dev/null 2>&1 \
       || curl -sf "\$JF_URL/jellyfin/health" >/dev/null 2>&1; do
        printf "."; sleep 5
    done
    echo " ✓"

    if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
        curl -sf -X POST "\$JF_URL/Startup/User" \
            -H "Content-Type: application/json" \
            -d "{\"Name\":\"${JELLYFIN_USER}\",\"Password\":\"${JELLYFIN_PASSWORD}\"}" \
            >/dev/null 2>&1 || true
        curl -sf -X POST "\$JF_URL/Startup/RemoteAccess" \
            -H "Content-Type: application/json" \
            -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
            >/dev/null 2>&1 || true
        curl -sf -X POST "\$JF_URL/Startup/Complete" >/dev/null 2>&1 || true
        echo "  ✓ Wizard Jellyfin complété"

        JF_AUTH=\$(curl -sf -X POST "\$JF_URL/Users/AuthenticateByName" \
            -H "Content-Type: application/json" \
            -H 'X-Emby-Authorization: MediaBrowser Client="Bootstrap", Device="Bootstrap", DeviceId="arr-bootstrap-1", Version="1.0.0"' \
            -d "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASSWORD}\"}" 2>/dev/null) || JF_AUTH=""
        JF_TOKEN=\$(echo "\$JF_AUTH" | grep -o '"AccessToken":"[^"]*"' | head -1 | cut -d'"' -f4) || JF_TOKEN=""
    else
        JF_TOKEN=""
    fi

    add_jf_lib() {
        local name=\$1 type=\$2 path=\$3
        if [[ -n "\$JF_TOKEN" ]]; then
            curl -sf -X POST "\$JF_URL/Library/VirtualFolders?refreshLibrary=false" \
                -H "Content-Type: application/json" \
                -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" \
                -d "{\"Name\":\"\$name\",\"CollectionType\":\"\$type\",\"Paths\":[\"\$path\"],\"LibraryOptions\":{}}" \
                >/dev/null 2>&1 || true
        else
            curl -sf -X POST "\$JF_URL/Library/VirtualFolders?refreshLibrary=false" \
                -H "Content-Type: application/json" \
                -d "{\"Name\":\"\$name\",\"CollectionType\":\"\$type\",\"Paths\":[\"\$path\"],\"LibraryOptions\":{}}" \
                >/dev/null 2>&1 || true
        fi
    }

    add_jf_lib "Films"   "movies"  "/media/movies"
    add_jf_lib "Séries"  "tvshows" "/media/tv"
    add_jf_lib "Musique" "music"   "/media/music"
    echo "  ✓ Bibliothèques Jellyfin configurées"

    # Langue française : métadonnées + interface
    if [[ -n "\$JF_TOKEN" ]]; then
        JF_SYS_CFG=\$(curl -sf "\$JF_URL/System/Configuration" \
            -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" 2>/dev/null) || JF_SYS_CFG=""
        if [[ -n "\$JF_SYS_CFG" ]]; then
            echo "\$JF_SYS_CFG" \
            | jq '.MetadataCountryCode = "FR" | .PreferredMetadataLanguage = "fr" | .UICulture = "fr-FR"' \
            | curl -sf -X POST "\$JF_URL/System/Configuration" \
                -H "Content-Type: application/json" \
                -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" \
                -d @- >/dev/null 2>&1 || true
            echo "  ✓ Jellyfin → langue française (métadonnées + interface)"
        fi
    fi
fi

echo ""
echo "── [6/6] Jellyseerr — configuration automatique..."

JS_URL="http://jellyseerr:5055"
printf "→ Attente Jellyseerr..."
until curl -sf "\${JS_URL}/api/v1/settings/public" >/dev/null 2>&1; do
    printf "."; sleep 5
done
echo " ✓"

JS_INIT=\$(curl -sf "\${JS_URL}/api/v1/settings/public" 2>/dev/null \
    | grep -o '"initialized":[^,}]*' | cut -d: -f2 | tr -d ' "') || JS_INIT="false"

if [[ "\${JS_INIT}" == "true" ]]; then
    echo "  ℹ Jellyseerr déjà initialisé — ignoré"
elif [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    # Connexion Jellyseerr via le compte Jellyfin admin créé à l'install
    curl -sf -X POST "\${JS_URL}/api/v1/auth/jellyfin" \
        -H "Content-Type: application/json" \
        -c /tmp/js.cookies -b /tmp/js.cookies \
        -d '{"hostname":"jellyfin","port":8096,"useSsl":false,"urlBase":"","username":"${JELLYFIN_USER}","password":"${JELLYFIN_PASSWORD}"}' \
        >/dev/null 2>&1 || true

    # Récupérer l'API key Jellyseerr (disponible après login)
    JS_KEY=\$(curl -sf "\${JS_URL}/api/v1/settings/main" \
        -b /tmp/js.cookies 2>/dev/null \
        | grep -o '"apiKey":"[^"]*"' | head -1 | cut -d'"' -f4) || JS_KEY=""

    if [[ -n "\${JS_KEY}" ]]; then
        # Ajouter Radarr dans Jellyseerr
        curl -sf -X POST "\${JS_URL}/api/v1/settings/radarr" \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: \${JS_KEY}" \
            -d "{\"name\":\"Radarr\",\"hostname\":\"radarr\",\"port\":7878,\"apiKey\":\"\$ARR_API_RADARR\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeDirectory\":\"/data/media/movies\",\"is4kServer\":false,\"isDefault\":true,\"syncEnabled\":true,\"preventSearch\":false}" \
            >/dev/null 2>&1 || true

        # Ajouter Sonarr dans Jellyseerr
        curl -sf -X POST "\${JS_URL}/api/v1/settings/sonarr" \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: \${JS_KEY}" \
            -d "{\"name\":\"Sonarr\",\"hostname\":\"sonarr\",\"port\":8989,\"apiKey\":\"\$ARR_API_SONARR\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeAnimeProfileId\":1,\"activeDirectory\":\"/data/media/tv\",\"activeAnimeDirectory\":\"/data/media/tv\",\"is4kServer\":false,\"isDefault\":true,\"syncEnabled\":true,\"preventSearch\":false}" \
            >/dev/null 2>&1 || true

        # Langue française pour Jellyseerr
        JS_MAIN_CFG=\$(curl -sf "\${JS_URL}/api/v1/settings/main" \
            -H "X-Api-Key: \${JS_KEY}" -b /tmp/js.cookies 2>/dev/null) || JS_MAIN_CFG=""
        if [[ -n "\${JS_MAIN_CFG}" ]]; then
            echo "\${JS_MAIN_CFG}" | jq '.locale = "fr"' \
            | curl -sf -X POST "\${JS_URL}/api/v1/settings/main" \
                -H "Content-Type: application/json" \
                -H "X-Api-Key: \${JS_KEY}" -b /tmp/js.cookies \
                -d @- >/dev/null 2>&1 || true
        fi

        echo "  ✓ Jellyseerr configuré (Jellyfin + Radarr + Sonarr + langue française)"
    else
        echo "  ⚠ Jellyseerr : API key non récupérée — configuration manuelle requise"
        echo "    Connecte-toi sur https://jellyseerr.${CALEOPE_DOMAIN}"
        echo "    URL Jellyfin à entrer : http://jellyfin:8096"
    fi
else
    echo "  ℹ Jellyfin externe — configure Jellyseerr manuellement"
    echo "    URL Jellyfin à entrer dans le wizard : ${JELLYFIN_INT_URL:-http://<ip-jellyfin>:8096}"
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅  Bootstrap terminé avec succès !             ║"
echo "║                                                  ║"
echo "║  Reste à faire manuellement :                    ║"
echo "║  • Prowlarr → ajouter tes indexeurs             ║"
echo "╚══════════════════════════════════════════════════╝"
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"

# ── post-install.txt ─────────────────────────────────────────────────
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    JF_LINE="║  Jellyfin     : https://jellyfin.${CALEOPE_DOMAIN}                  ║"
    JF_CRED="║  Jellyfin admin : ${JELLYFIN_USER} / ${JELLYFIN_PASSWORD}            ║"
elif [[ -n "${JELLYFIN_INT_URL}" ]]; then
    JF_LINE="║  Jellyfin     : ${JELLYFIN_INT_URL} (externe)                        ║"
    JF_CRED=""
else
    JF_LINE=""
    JF_CRED=""
fi

if [[ "${VPN_ENABLED}" == "true" ]]; then
    VPN_LINE="║  🔒 VPN : ${VPN_PROVIDER} / ${VPN_TYPE}                              ║"
else
    VPN_LINE="║  🔓 VPN : désactivé                                                  ║"
fi

# Item "Jellyseerr → configurer" affiché seulement si Jellyfin est externe
# (si Jellyfin est embarqué, le bootstrap l'auto-configure)
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    JS_TODO=""
else
    JS_TODO="║  3. Jellyseerr → connecter Jellyfin (http://<ip>:8096)               ║"
fi

cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔════════════════════════════════════════════════════════════════════════╗
║                       Arr Stack — Accès                               ║
╠════════════════════════════════════════════════════════════════════════╣
║  Jellyseerr   : https://jellyseerr.${CALEOPE_DOMAIN}                 ║
║  Jellyfin Vue : https://vue.${CALEOPE_DOMAIN}                        ║
${JF_LINE}
║  Prowlarr     : https://prowlarr.${CALEOPE_DOMAIN}                   ║
║  Radarr       : https://radarr.${CALEOPE_DOMAIN}                     ║
║  Sonarr       : https://sonarr.${CALEOPE_DOMAIN}                     ║
║  Lidarr       : https://lidarr.${CALEOPE_DOMAIN}                     ║
║  Bazarr       : https://bazarr.${CALEOPE_DOMAIN}                     ║
║  qBittorrent  : https://qbt.${CALEOPE_DOMAIN}                        ║
║  SABnzbd      : https://sabnzbd.${CALEOPE_DOMAIN}                    ║
╠════════════════════════════════════════════════════════════════════════╣
║  🤖 CONNEXIONS CONFIGURÉES AUTOMATIQUEMENT                            ║
${VPN_LINE}
╠════════════════════════════════════════════════════════════════════════╣
║  À FAIRE :                                                            ║
║  1. DNS : *.${CALEOPE_DOMAIN} → IP du serveur (ou entrées par app)   ║
║  2. Prowlarr → Indexers → Add                                         ║
${JS_TODO}
╠════════════════════════════════════════════════════════════════════════╣
${JF_CRED}
║  qBittorrent password : ${QBT_PASSWORD}                              ║
╚════════════════════════════════════════════════════════════════════════╝
EOF

echo "✓ Arr Stack préparé — bootstrap configuré"
