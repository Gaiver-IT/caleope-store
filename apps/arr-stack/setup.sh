#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"

# ── Chemin de stockage média ──────────────────────────────────────────
# Par défaut : stockage local dans app-data/arr-stack
# Personnalisable via : caleope install arr-stack --param storage_path=/mnt/nas/media
STORAGE_PATH="${CALEOPE_PARAM_STORAGE_PATH:-${CALEOPE_BASE_DIR}/app-data/arr-stack/data}"

mkdir -p "${CONFIG_DIR}"

# ── Créer la structure de dossiers ───────────────────────────────────
echo "→ Création de la structure de dossiers..."
mkdir -p "${STORAGE_PATH}/downloads/complete/"{movies,tv,music,books}
mkdir -p "${STORAGE_PATH}/downloads/incomplete"
mkdir -p "${STORAGE_PATH}/media/"{movies,tv,music,books}

# Lien symbolique si stockage externe (NAS)
if [[ "${STORAGE_PATH}" != "${CALEOPE_BASE_DIR}/app-data/arr-stack/data" ]]; then
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack"
    ln -sfn "${STORAGE_PATH}" "${CALEOPE_BASE_DIR}/app-data/arr-stack/data"
    echo "   ✓ Données liées vers : ${STORAGE_PATH}"
fi

# ── Dossiers de config par app ───────────────────────────────────────
for app in prowlarr radarr sonarr lidarr readarr bazarr qbittorrent sabnzbd jellyseerr; do
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}"
done

# ── Détecter PUID/PGID ───────────────────────────────────────────────
PUID=$(id -u)
PGID=$(id -g)

# ── Générer les API keys ──────────────────────────────────────────────
gen_api_key() { openssl rand -hex 16; }
API_PROWLARR=$(gen_api_key)
API_RADARR=$(gen_api_key)
API_SONARR=$(gen_api_key)
API_LIDARR=$(gen_api_key)
API_READARR=$(gen_api_key)

# ── Écrire secrets.env (fusionné dans app.env) ───────────────────────
cat > "${CONFIG_DIR}/secrets.env" <<EOF
ARR_PUID=${PUID}
ARR_PGID=${PGID}
ARR_TZ=Europe/Paris
ARR_STORAGE_PATH=${STORAGE_PATH}
# API keys (à utiliser dans Prowlarr pour connecter les apps)
ARR_API_PROWLARR=${API_PROWLARR}
ARR_API_RADARR=${API_RADARR}
ARR_API_SONARR=${API_SONARR}
ARR_API_LIDARR=${API_LIDARR}
ARR_API_READARR=${API_READARR}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── Pré-configurer les URL base de chaque *arr ───────────────────────
# Les apps lisent config.xml au premier démarrage
write_arr_config() {
    local app=$1 port=$2 urlbase=$3 apikey=$4
    local config_dir="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}"
    mkdir -p "${config_dir}"
    # Ne pas écraser si déjà configuré (réinstall)
    [[ -f "${config_dir}/config.xml" ]] && return 0
    cat > "${config_dir}/config.xml" <<XMLEOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${port}</Port>
  <UrlBase>${urlbase}</UrlBase>
  <EnableSsl>False</EnableSsl>
  <ApiKey>${apikey}</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
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

# Bazarr : config ini
BAZARR_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/bazarr/config.ini"
if [[ ! -f "${BAZARR_CFG}" ]]; then
    mkdir -p "$(dirname "${BAZARR_CFG}")"
    cat > "${BAZARR_CFG}" <<INICFG
[general]
base_url = /bazarr
INICFG
fi

# ── post-install.txt ─────────────────────────────────────────────────
cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════════╗
║               Arr Stack — Accès                                  ║
╠══════════════════════════════════════════════════════════════════╣
║  Jellyseerr   : https://${CALEOPE_DOMAIN}          (demandes)    ║
║  Jellyfin Vue : https://${CALEOPE_DOMAIN}/vue       (lecture)    ║
║  Prowlarr     : https://${CALEOPE_DOMAIN}/prowlarr               ║
║  Radarr       : https://${CALEOPE_DOMAIN}/radarr                 ║
║  Sonarr       : https://${CALEOPE_DOMAIN}/sonarr                 ║
║  Lidarr       : https://${CALEOPE_DOMAIN}/lidarr                 ║
║  Readarr      : https://${CALEOPE_DOMAIN}/readarr                ║
║  Bazarr       : https://${CALEOPE_DOMAIN}/bazarr                 ║
║  qBittorrent  : https://${CALEOPE_DOMAIN}/qbt                    ║
║  SABnzbd      : https://${CALEOPE_DOMAIN}/sabnzbd                ║
╠══════════════════════════════════════════════════════════════════╣
║  Stockage média : ${STORAGE_PATH}                                ║
╠══════════════════════════════════════════════════════════════════╣
║  API keys (pour connecter les apps entre elles) :                ║
║    Prowlarr : ${API_PROWLARR}  ║
║    Radarr   : ${API_RADARR}  ║
║    Sonarr   : ${API_SONARR}  ║
║    Lidarr   : ${API_LIDARR}  ║
║    Readarr  : ${API_READARR}  ║
╠══════════════════════════════════════════════════════════════════╣
║  ORDRE DE CONFIGURATION :                                        ║
║  1. Prowlarr → ajouter tes indexeurs                             ║
║  2. Prowlarr → Apps → connecter Radarr/Sonarr/Lidarr/Readarr    ║
║  3. Radarr/Sonarr → Download Clients → qBittorrent              ║
║     Host: qbittorrent  Port: 8080                                ║
║  4. Jellyseerr → connecter Jellyfin + Radarr + Sonarr            ║
║  5. Jellyfin → ajouter bibliothèque : ${STORAGE_PATH}/media      ║
╚══════════════════════════════════════════════════════════════════╝

NAS custom : caleope install arr-stack --param storage_path=/mnt/nas/media
EOF

echo "✓ Arr Stack préparé (${STORAGE_PATH})"
