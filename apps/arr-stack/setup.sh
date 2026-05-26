#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"

# ── Chemin de stockage média ──────────────────────────────────────────
STORAGE_PATH="${CALEOPE_PARAM_STORAGE_PATH:-${CALEOPE_BASE_DIR}/app-data/arr-stack/data}"

mkdir -p "${CONFIG_DIR}"

# ── Structure de dossiers ─────────────────────────────────────────────
echo "→ Création de la structure de dossiers..."
mkdir -p "${STORAGE_PATH}/downloads/complete/"{movies,tv,music,books}
mkdir -p "${STORAGE_PATH}/downloads/incomplete"
mkdir -p "${STORAGE_PATH}/media/"{movies,tv,music,books}

if [[ "${STORAGE_PATH}" != "${CALEOPE_BASE_DIR}/app-data/arr-stack/data" ]]; then
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack"
    ln -sfn "${STORAGE_PATH}" "${CALEOPE_BASE_DIR}/app-data/arr-stack/data"
    echo "   ✓ Données liées vers : ${STORAGE_PATH}"
fi

for app in prowlarr radarr sonarr lidarr readarr bazarr qbittorrent sabnzbd jellyseerr; do
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}"
done

# ── Détecter PUID/PGID ───────────────────────────────────────────────
PUID=$(id -u)
PGID=$(id -g)

# ── Générer les secrets ───────────────────────────────────────────────
gen_key() { openssl rand -hex 16; }
API_PROWLARR=$(gen_key)
API_RADARR=$(gen_key)
API_SONARR=$(gen_key)
API_LIDARR=$(gen_key)
API_READARR=$(gen_key)
API_SABNZBD=$(gen_key)
QBT_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 14)

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
read -rp "  Activer un VPN ? [o/N] : " _VPN_ANSWER

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

if [[ "${_VPN_ANSWER,,}" == "o" || "${_VPN_ANSWER,,}" == "oui" || \
      "${_VPN_ANSWER,,}" == "y" || "${_VPN_ANSWER,,}" == "yes" ]]; then

    VPN_ENABLED=true
    COMPOSE_PROFILES="vpn"
    QBT_HOST="arr-gluetun"

    # ── Choix du fournisseur ──────────────────────────────────────────
    echo ""
    echo "  Fournisseur VPN :"
    echo "    1) ProtonVPN  (recommandé)"
    echo "    2) Mullvad"
    echo "    3) NordVPN"
    echo "    4) Private Internet Access (PIA)"
    echo "    5) Surfshark"
    echo "    6) ExpressVPN"
    echo "    7) Autre (compatible Gluetun)"
    read -rp "  Choix [1-7] : " _PROVIDER_CHOICE

    case "${_PROVIDER_CHOICE}" in
        1) VPN_PROVIDER="protonvpn" ;;
        2) VPN_PROVIDER="mullvad" ;;
        3) VPN_PROVIDER="nordvpn" ;;
        4) VPN_PROVIDER="private internet access" ;;
        5) VPN_PROVIDER="surfshark" ;;
        6) VPN_PROVIDER="expressvpn" ;;
        7) read -rp "  Nom du fournisseur Gluetun (ex: ivpn) : " VPN_PROVIDER ;;
        *) VPN_PROVIDER="protonvpn" ;;
    esac

    # ── Choix du protocole ────────────────────────────────────────────
    echo ""
    echo "  Protocole :"
    echo "    1) WireGuard  (recommandé — plus rapide, plus simple)"
    echo "    2) OpenVPN    (plus compatible, légèrement plus lent)"
    read -rp "  Choix [1/2] : " _PROTO_CHOICE

    if [[ "${_PROTO_CHOICE}" == "2" ]]; then
        VPN_TYPE="openvpn"
        echo ""
        echo "  ── Identifiants OpenVPN ──────────────────────────────────────"
        read -rp "  Nom d'utilisateur : " VPN_OPENVPN_USER
        read -rsp "  Mot de passe      : " VPN_OPENVPN_PASSWORD
        echo ""
    else
        VPN_TYPE="wireguard"
        echo ""
        echo "  ── Clé WireGuard ─────────────────────────────────────────────"

        if [[ "${VPN_PROVIDER}" == "protonvpn" ]]; then
            echo "  → ProtonVPN : télécharge ta config WireGuard sur"
            echo "    account.proton.me → VPN → Télécharger → WireGuard"
            echo "    La clé privée est dans le champ [Interface] PrivateKey"
        elif [[ "${VPN_PROVIDER}" == "mullvad" ]]; then
            echo "  → Mullvad : génère une clé sur mullvad.net/account/wireguard-config"
        fi

        echo ""
        read -rp "  Clé privée WireGuard (PrivateKey) : " VPN_WG_PRIVATE_KEY

        if [[ "${VPN_PROVIDER}" == "mullvad" ]]; then
            read -rp "  Adresse WireGuard (Address, ex: 10.68.x.x/32) : " VPN_WG_ADDRESSES
        fi
    fi

    # ── Pays / serveur (optionnel) ────────────────────────────────────
    echo ""
    read -rp "  Pays du serveur VPN (optionnel, Entrée pour ignorer, ex: France) : " VPN_SERVER_COUNTRIES

    echo ""
    echo "  ✓ VPN configuré : ${VPN_PROVIDER} / ${VPN_TYPE}"
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
ARR_API_READARR=${API_READARR}
ARR_API_SABNZBD=${API_SABNZBD}
ARR_QBT_PASSWORD=${QBT_PASSWORD}
ARR_QBT_HOST=${QBT_HOST}

# Profil Docker Compose (novpn ou vpn)
COMPOSE_PROFILES=${COMPOSE_PROFILES}

# VPN (Gluetun) — vide si VPN désactivé
ARR_VPN_PROVIDER=${VPN_PROVIDER}
ARR_VPN_TYPE=${VPN_TYPE}
ARR_VPN_WG_PRIVATE_KEY=${VPN_WG_PRIVATE_KEY}
ARR_VPN_WG_ADDRESSES=${VPN_WG_ADDRESSES}
ARR_VPN_OPENVPN_USER=${VPN_OPENVPN_USER}
ARR_VPN_OPENVPN_PASSWORD=${VPN_OPENVPN_PASSWORD}
ARR_VPN_SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── config.xml *arr (UrlBase + ApiKey + Auth désactivée) ─────────────
write_arr_config() {
    local app=$1 port=$2 urlbase=$3 apikey=$4
    local cfg="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}/config.xml"
    [[ -f "${cfg}" ]] && return 0
    cat > "${cfg}" <<XMLEOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${port}</Port>
  <UrlBase>${urlbase}</UrlBase>
  <EnableSsl>False</EnableSsl>
  <ApiKey>${apikey}</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <AuthenticationRequired>Disabled</AuthenticationRequired>
  <UpdateMechanism>Docker</UpdateMechanism>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
</Config>
XMLEOF
}

write_arr_config prowlarr 9696 /prowlarr "${API_PROWLARR}"
write_arr_config radarr   7878 /radarr   "${API_RADARR}"
write_arr_config sonarr   8989 /sonarr   "${API_SONARR}"
write_arr_config lidarr   8686 /lidarr   "${API_LIDARR}"
write_arr_config readarr  8787 /readarr  "${API_READARR}"

# ── Bazarr config ────────────────────────────────────────────────────
BAZARR_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/bazarr/config.ini"
if [[ ! -f "${BAZARR_CFG}" ]]; then
    cat > "${BAZARR_CFG}" <<INICFG
[general]
base_url = /bazarr
INICFG
fi

# ── qBittorrent : config pré-générée (whitelist réseau Docker) ────────
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

# ── SABnzbd : API key pré-configurée ─────────────────────────────────
SABNZBD_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/sabnzbd/sabnzbd.ini"
if [[ ! -f "${SABNZBD_CFG}" ]]; then
    cat > "${SABNZBD_CFG}" <<SABCFG
[misc]
api_key = ${API_SABNZBD}
nzb_key = ${API_SABNZBD}
url_base = /sabnzbd
host = 0.0.0.0
port = 8080
complete_dir = /data/downloads/complete
incomplete_dir = /data/downloads/incomplete
SABCFG
fi

# ── Bootstrap script ──────────────────────────────────────────────────
# QBT_HOST est injecté ici selon VPN (arr-gluetun) ou non (qbittorrent)
cat > "${CONFIG_DIR}/bootstrap.sh" <<BOOTSTRAP
#!/bin/bash
set -e

P_URL="http://prowlarr:9696/prowlarr"
R_URL="http://radarr:7878/radarr"
S_URL="http://sonarr:8989/sonarr"
L_URL="http://lidarr:8686/lidarr"
RD_URL="http://readarr:8787/readarr"
QBT_URL="http://${QBT_HOST}:8080"
SAB_URL="http://sabnzbd:8080/sabnzbd"

wait_arr() {
    local name=\$1 url=\$2 key=\$3
    printf "→ Attente %s..." "\$name"
    until curl -sf -H "X-Api-Key: \$key" "\$url/api/v3/system/status" >/dev/null 2>&1 \
       || curl -sf -H "X-Api-Key: \$key" "\$url/api/v1/system/status" >/dev/null 2>&1; do
        printf "."
        sleep 5
    done
    echo " ✓"
}

wait_url() {
    local name=\$1 url=\$2
    printf "→ Attente %s..." "\$name"
    until curl -sf "\$url" >/dev/null 2>&1; do printf "."; sleep 5; done
    echo " ✓"
}

api_post() {
    local url=\$1 key=\$2 data=\$3
    curl -sf -X POST "\$url" \
        -H "X-Api-Key: \$key" \
        -H "Content-Type: application/json" \
        -d "\$data" >/dev/null 2>&1 || true
}

api_post_v3() { api_post "\${1}/api/v3/\${3}" "\$2" "\$4"; }
api_post_v1() { api_post "\${1}/api/v1/\${3}" "\$2" "\$4"; }

echo "╔════════════════════════════════════════╗"
echo "║   Arr Stack — Bootstrap automatique    ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "── [1/3] Attente du démarrage des services..."

wait_arr "Prowlarr"    "\$P_URL"  "\$ARR_API_PROWLARR"
wait_arr "Radarr"      "\$R_URL"  "\$ARR_API_RADARR"
wait_arr "Sonarr"      "\$S_URL"  "\$ARR_API_SONARR"
wait_arr "Lidarr"      "\$L_URL"  "\$ARR_API_LIDARR"
wait_arr "Readarr"     "\$RD_URL" "\$ARR_API_READARR"
wait_url "qBittorrent" "\$QBT_URL/api/v2/app/version"

echo ""
echo "── [2/3] Connexion Prowlarr → *arr..."

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Radarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Radarr\",\"implementation\":\"Radarr\",\"configContract\":\"RadarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"\$P_URL\"},{\"name\":\"baseUrl\",\"value\":\"\$R_URL\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_RADARR\"},{\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060]},{\"name\":\"animeSyncCategories\",\"value\":[5070]}]}"
echo "  ✓ Prowlarr → Radarr"

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Sonarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Sonarr\",\"implementation\":\"Sonarr\",\"configContract\":\"SonarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"\$P_URL\"},{\"name\":\"baseUrl\",\"value\":\"\$S_URL\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_SONARR\"},{\"name\":\"syncCategories\",\"value\":[5000,5010,5020,5030,5040,5045,5050]},{\"name\":\"animeSyncCategories\",\"value\":[5070]}]}"
echo "  ✓ Prowlarr → Sonarr"

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Lidarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Lidarr\",\"implementation\":\"Lidarr\",\"configContract\":\"LidarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"\$P_URL\"},{\"name\":\"baseUrl\",\"value\":\"\$L_URL\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_LIDARR\"},{\"name\":\"syncCategories\",\"value\":[3000,3010,3020,3030,3040]}]}"
echo "  ✓ Prowlarr → Lidarr"

api_post_v1 "\$P_URL" "\$ARR_API_PROWLARR" "applications" \
    "{\"name\":\"Readarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Readarr\",\"implementation\":\"Readarr\",\"configContract\":\"ReadarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"\$P_URL\"},{\"name\":\"baseUrl\",\"value\":\"\$RD_URL\"},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_READARR\"},{\"name\":\"syncCategories\",\"value\":[7000,7020]}]}"
echo "  ✓ Prowlarr → Readarr"

echo ""
echo "── [3/3] Clients de téléchargement + dossiers racine..."

qbt_client() {
    local name=\$1 category=\$2
    echo "{\"name\":\"qBittorrent\",\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"implementationName\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"${QBT_HOST}\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"username\",\"value\":\"\"},{\"name\":\"password\",\"value\":\"\"},{\"name\":\"\${name}Category\",\"value\":\"\$category\"},{\"name\":\"recentMoviePriority\",\"value\":0},{\"name\":\"olderMoviePriority\",\"value\":0},{\"name\":\"initialState\",\"value\":0}]}"
}

sab_client() {
    local category=\$1
    echo "{\"name\":\"SABnzbd\",\"enable\":true,\"protocol\":\"usenet\",\"priority\":1,\"implementationName\":\"SABnzbd\",\"implementation\":\"Sabnzbd\",\"configContract\":\"SabnzbdSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"sabnzbd\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"apiKey\",\"value\":\"\$ARR_API_SABNZBD\"},{\"name\":\"urlBase\",\"value\":\"/sabnzbd\"},{\"name\":\"\${category}Category\",\"value\":\"\$category\"}]}"
}

api_post_v3 "\$R_URL" "\$ARR_API_RADARR" "downloadclient" "\$(qbt_client movie movies)"
api_post_v3 "\$R_URL" "\$ARR_API_RADARR" "downloadclient" "\$(sab_client movie)"
api_post_v3 "\$R_URL" "\$ARR_API_RADARR" "rootfolder"     "{\"path\":\"/data/media/movies\"}"
echo "  ✓ Radarr → qBittorrent + SABnzbd + /data/media/movies"

api_post_v3 "\$S_URL" "\$ARR_API_SONARR" "downloadclient" "\$(qbt_client series tv)"
api_post_v3 "\$S_URL" "\$ARR_API_SONARR" "downloadclient" "\$(sab_client series)"
api_post_v3 "\$S_URL" "\$ARR_API_SONARR" "rootfolder"     "{\"path\":\"/data/media/tv\"}"
echo "  ✓ Sonarr → qBittorrent + SABnzbd + /data/media/tv"

api_post_v1 "\$L_URL" "\$ARR_API_LIDARR" "downloadclient" "\$(qbt_client music music)"
api_post_v1 "\$L_URL" "\$ARR_API_LIDARR" "downloadclient" "\$(sab_client music)"
api_post_v1 "\$L_URL" "\$ARR_API_LIDARR" "rootfolder"     "{\"path\":\"/data/media/music\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\"}"
echo "  ✓ Lidarr → qBittorrent + SABnzbd + /data/media/music"

api_post_v1 "\$RD_URL" "\$ARR_API_READARR" "downloadclient" "\$(qbt_client book books)"
api_post_v1 "\$RD_URL" "\$ARR_API_READARR" "downloadclient" "\$(sab_client book)"
api_post_v1 "\$RD_URL" "\$ARR_API_READARR" "rootfolder"     "{\"path\":\"/data/media/books\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\"}"
echo "  ✓ Readarr → qBittorrent + SABnzbd + /data/media/books"

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  ✅  Bootstrap terminé avec succès !   ║"
echo "║                                        ║"
echo "║  Reste à faire manuellement :          ║"
echo "║  • Prowlarr → ajouter tes indexeurs   ║"
echo "║  • Jellyseerr → connecter Jellyfin    ║"
echo "╚════════════════════════════════════════╝"
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"

# ── post-install.txt ─────────────────────────────────────────────────
if [[ "${VPN_ENABLED}" == "true" ]]; then
    VPN_STATUS_LINE="║  🔒 VPN actif : ${VPN_PROVIDER} / ${VPN_TYPE}                              ║"
else
    VPN_STATUS_LINE="║  🔓 VPN : désactivé (configurable à la réinstallation)               ║"
fi

cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════════════╗
║                    Arr Stack — Accès                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  Jellyseerr   : https://${CALEOPE_DOMAIN}           (demandes)      ║
║  Jellyfin Vue : https://${CALEOPE_DOMAIN}/vue        (lecture)      ║
║  Prowlarr     : https://${CALEOPE_DOMAIN}/prowlarr                  ║
║  Radarr       : https://${CALEOPE_DOMAIN}/radarr                    ║
║  Sonarr       : https://${CALEOPE_DOMAIN}/sonarr                    ║
║  Lidarr       : https://${CALEOPE_DOMAIN}/lidarr                    ║
║  Readarr      : https://${CALEOPE_DOMAIN}/readarr                   ║
║  Bazarr       : https://${CALEOPE_DOMAIN}/bazarr                    ║
║  qBittorrent  : https://${CALEOPE_DOMAIN}/qbt                       ║
║  SABnzbd      : https://${CALEOPE_DOMAIN}/sabnzbd                   ║
╠══════════════════════════════════════════════════════════════════════╣
║  🤖 CONNEXIONS CONFIGURÉES AUTOMATIQUEMENT :                         ║
║     ✓ Prowlarr → Radarr, Sonarr, Lidarr, Readarr                   ║
║     ✓ Radarr/Sonarr/Lidarr/Readarr → qBittorrent + SABnzbd         ║
║     ✓ Dossiers média : /data/media/{movies,tv,music,books}          ║
║     ✓ Auth désactivée (réseau local)                                ║
${VPN_STATUS_LINE}
╠══════════════════════════════════════════════════════════════════════╣
║  À FAIRE MANUELLEMENT (2 étapes seulement) :                        ║
║  1. Prowlarr → Indexers → Add  (ajouter tes sources)                ║
║  2. Jellyseerr → connecter Jellyfin + Radarr + Sonarr               ║
╠══════════════════════════════════════════════════════════════════════╣
║  Stockage : ${STORAGE_PATH}                                          ║
║  qBittorrent password : ${QBT_PASSWORD}  (si besoin)                ║
╚══════════════════════════════════════════════════════════════════════╝
EOF

echo "✓ Arr Stack préparé — bootstrap configuré"
