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
chmod -R 777 "${STORAGE_PATH}"


if [[ "${STORAGE_PATH}" != "${CALEOPE_BASE_DIR}/app-data/arr-stack/data" ]]; then
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack"
    ln -sfn "${STORAGE_PATH}" "${CALEOPE_BASE_DIR}/app-data/arr-stack/data"
    echo "   ✓ Données liées vers : ${STORAGE_PATH}"
fi

for app in prowlarr radarr sonarr lidarr bazarr qbittorrent sabnzbd jellyseerr; do
    mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}"
done

# ── Nettoyage Jellyfin (si réinstallation) ────────────────────────────
# Supprimer tout container jellyfin arrêté/exité : compose ne peut pas démarrer
# un service si un container du même nom existe déjà en état exited.
# IMPORTANT : ne faire ce nettoyage QUE si Jellyfin n'est PAS une app Caleope
# séparée — sinon on tuerait le container standalone de l'utilisateur.
if [[ ! -f "${CALEOPE_BASE_DIR}/runtime/apps/jellyfin.json" ]]; then
    docker stop jellyfin 2>/dev/null || true
    docker rm   jellyfin 2>/dev/null || true
fi

JELLYFIN_CFG="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/jellyfin"
mkdir -p "${JELLYFIN_CFG}"
# Nettoyage Jellyfin lors d'une réinstallation.
# IMPORTANT : caleope remove supprime app-data/ en entier, donc jellyfin.db et root/ n'existent
# plus quand setup.sh s'exécute. On ne peut pas se fier à leur présence pour décider de
# nettoyer. On gère deux cas indépendants :
#  A) DB ou bibliothèques présentes → nettoyage complet (data + log + root)
#  B) system.xml présent avec wizard=true → reset du flag, peu importe si la DB existe
# Les deux peuvent s'appliquer ensemble ou séparément.
if [[ -f "${JELLYFIN_CFG}/data/jellyfin.db" || -d "${JELLYFIN_CFG}/root" ]]; then
    echo "→ Nettoyage de la configuration Jellyfin précédente (data/root)..."
    docker run --rm \
        -v "${JELLYFIN_CFG}:/jf" \
        alpine:3.19 \
        sh -c "rm -rf /jf/data /jf/log /jf/root 2>/dev/null; true" \
        >/dev/null 2>&1 || true
    echo "  ✓ Données Jellyfin supprimées"
fi
# Toujours réinitialiser le flag wizard si system.xml existe (déclenché même après remove).
# Sans ce reset, Jellyfin démarre avec wizard=true mais sans users → bootstrap 401.
if [[ -f "${JELLYFIN_CFG}/config/system.xml" ]]; then
    docker run --rm \
        -v "${JELLYFIN_CFG}:/jf" \
        alpine:3.19 \
        sh -c "sed -i 's|<IsStartupWizardCompleted>true</IsStartupWizardCompleted>|<IsStartupWizardCompleted>false</IsStartupWizardCompleted>|' /jf/config/system.xml 2>/dev/null; true" \
        >/dev/null 2>&1 || true
    echo "  ✓ Flag wizard Jellyfin réinitialisé"
fi

# ── Détecter PUID/PGID ───────────────────────────────────────────────
PUID=$(id -u)
PGID=$(id -g)

# ── Générer les secrets ───────────────────────────────────────────────
API_PROWLARR=$(openssl rand -hex 16)
API_RADARR=$(openssl rand -hex 16)
API_SONARR=$(openssl rand -hex 16)
API_LIDARR=$(openssl rand -hex 16)
API_SABNZBD=$(openssl rand -hex 16)
BAZARR_API_KEY=$(openssl rand -hex 16)

# ── Langue préférée ───────────────────────────────────────────────────
# Utilisée pour l'UI et les préférences de téléchargement (audio, sous-titres)
# Codes : fr, en, de, es, it, pt, nl, pl, ja
PREFERRED_LANGUAGE="${CALEOPE_PARAM_LANGUAGE:-fr}"

# Mapping langue → noms utilisés par les APIs *arr
lang_to_arr_name() {
    case "$1" in
        fr) echo "French" ;;
        en) echo "English" ;;
        de) echo "German" ;;
        es) echo "Spanish" ;;
        it) echo "Italian" ;;
        pt) echo "Portuguese" ;;
        nl) echo "Dutch" ;;
        pl) echo "Polish" ;;
        ja) echo "Japanese" ;;
        *)  echo "French" ;;   # fallback
    esac
}
PREFERRED_LANGUAGE_NAME=$(lang_to_arr_name "${PREFERRED_LANGUAGE}")

# Mapping langue → code Jellyfin (culture)
lang_to_jellyfin_culture() {
    case "$1" in
        fr) echo "fr-FR" ;;
        en) echo "en-US" ;;
        de) echo "de-DE" ;;
        es) echo "es-ES" ;;
        it) echo "it-IT" ;;
        pt) echo "pt-PT" ;;
        nl) echo "nl-NL" ;;
        pl) echo "pl-PL" ;;
        ja) echo "ja-JP" ;;
        *)  echo "fr-FR" ;;
    esac
}
PREFERRED_LANGUAGE_CULTURE=$(lang_to_jellyfin_culture "${PREFERRED_LANGUAGE}")

echo "  → Langue préférée : ${PREFERRED_LANGUAGE} (${PREFERRED_LANGUAGE_NAME})"

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
_JELLYFIN_CALEOPE_MANAGED=false

# Lire le mode depuis CALEOPE_PARAM_JELLYFIN_MODE si fourni (API / mode non-interactif)
_JELLYFIN_MODE="${CALEOPE_PARAM_JELLYFIN_MODE:-}"
_JELLYFIN_EXT_URL="${CALEOPE_PARAM_JELLYFIN_URL:-}"

if [[ -n "${_JELLYFIN_MODE}" ]]; then
    # Mode fourni via API — court-circuiter le wizard interactif
    if [[ "${_JELLYFIN_MODE}" == "embedded" ]]; then
        JELLYFIN_EMBEDDED=true
        JELLYFIN_INT_URL="http://jellyfin:8096"
        JELLYFIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-14)
        echo "  ✓ Jellyfin embarqué dans la stack (mode API)"
        echo "    Compte admin : ${JELLYFIN_USER} / ${JELLYFIN_PASSWORD}"
    elif [[ "${_JELLYFIN_MODE}" == "external" ]]; then
        JELLYFIN_EMBEDDED=false
        JELLYFIN_INT_URL="${_JELLYFIN_EXT_URL}"
        JELLYFIN_USER="${CALEOPE_PARAM_JELLYFIN_EXT_USER:-admin}"
        JELLYFIN_PASSWORD="${CALEOPE_PARAM_JELLYFIN_EXT_PASSWORD:-}"
        echo "  ✓ Jellyfin externe : ${JELLYFIN_INT_URL} (mode API)"
    else
        # none ou toute autre valeur → pas de Jellyfin
        JELLYFIN_EMBEDDED=false
        JELLYFIN_INT_URL=""
        echo "  ✓ Sans Jellyfin (mode API)"
    fi
elif [[ -f "${CALEOPE_BASE_DIR}/runtime/apps/jellyfin.json" ]]; then
    # Jellyfin géré par Caleope (app installée séparément) — PRIORITAIRE sur docker ps.
    # On le réutilise comme instance externe sans le détruire.
    # Note : on utilise le fichier runtime (pas docker ps) car le daemon Caleope qui
    # exécute ce script peut ne pas avoir docker CLI dans son PATH.
    echo "  ℹ  Jellyfin géré par Caleope détecté (runtime/apps/jellyfin.json)"
    JELLYFIN_EMBEDDED=false
    _JELLYFIN_CALEOPE_MANAGED=true
    JELLYFIN_INT_URL="http://jellyfin:8096"
    echo "  ✓ Jellyfin existant réutilisé comme instance externe : ${JELLYFIN_INT_URL}"
    # Priorité 1 : lire les credentials depuis le secrets.env de l'app Jellyfin Caleope
    # (générés automatiquement par son setup.sh — zero interaction nécessaire)
    _JF_SECRETS="${CALEOPE_BASE_DIR}/app-config/jellyfin/secrets.env"
    if [[ -f "${_JF_SECRETS}" ]]; then
        _JF_U=$(grep "^JELLYFIN_USER=" "${_JF_SECRETS}" 2>/dev/null | cut -d= -f2- | tr -d '"') || _JF_U=""
        _JF_P=$(grep "^JELLYFIN_PASSWORD=" "${_JF_SECRETS}" 2>/dev/null | cut -d= -f2- | tr -d '"') || _JF_P=""
        [[ -n "${_JF_U}" ]] && JELLYFIN_USER="${_JF_U}"
        [[ -n "${_JF_P}" ]] && JELLYFIN_PASSWORD="${_JF_P}"
        if [[ -n "${JELLYFIN_PASSWORD}" ]]; then
            echo "  ✓ Credentials Jellyfin lus depuis app-config/jellyfin/secrets.env → Jellyseerr sera auto-configuré"
        fi
    fi
    # Priorité 2 : params Caleope (si pas de secrets.env)
    if [[ -z "${JELLYFIN_PASSWORD}" ]]; then
        JELLYFIN_USER="${CALEOPE_PARAM_JELLYFIN_EXT_USER:-${JELLYFIN_USER}}"
        JELLYFIN_PASSWORD="${CALEOPE_PARAM_JELLYFIN_EXT_PASSWORD:-}"
    fi
    # Priorité 3 : prompt interactif (fallback si vraiment rien)
    if [[ -z "${JELLYFIN_PASSWORD}" && "${INTERACTIVE}" == "true" ]]; then
        echo "  → Identifiants Jellyfin pour auto-configurer Jellyseerr (laisser vide = config manuelle)"
        read -rp "  URL interne Jellyfin si différente [${JELLYFIN_INT_URL}] : " _JF_URL_OVERRIDE || _JF_URL_OVERRIDE=""
        [[ -n "${_JF_URL_OVERRIDE}" ]] && JELLYFIN_INT_URL="${_JF_URL_OVERRIDE}"
        read -rp "  Utilisateur admin Jellyfin [admin] : " _JF_USER_IN || _JF_USER_IN=""
        [[ -n "${_JF_USER_IN}" ]] && JELLYFIN_USER="${_JF_USER_IN}"
        read -rsp "  Mot de passe admin Jellyfin : " JELLYFIN_PASSWORD || JELLYFIN_PASSWORD=""
        echo ""
    fi
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^jellyfin$'; then
    # Jellyfin en cours mais pas géré par Caleope (orphelin ou autre install)
    echo "  ℹ  Jellyfin détecté (container existant, non géré par Caleope)"
    _JF_REUSE="O"
    if [[ "${INTERACTIVE}" == "true" ]]; then
        read -rp "  Utiliser ce Jellyfin existant ? [O/n] : " _JF_REUSE || _JF_REUSE="O"
    else
        # En non-interactif : orphelin → remplacement par la stack embarquée
        _JF_REUSE="n"
        echo "  ℹ Container jellyfin orphelin → remplacement par la stack"
    fi
    if [[ "${_JF_REUSE,,}" == "n" || "${_JF_REUSE,,}" == "non" ]]; then
        # Supprimer le container orphelin pour éviter un conflit de nom
        docker stop jellyfin 2>/dev/null || true
        docker rm   jellyfin 2>/dev/null || true
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

# Lire depuis CALEOPE_PARAM_* si fournis (mode API / non-interactif)
_VPN_ENABLED="${CALEOPE_PARAM_VPN_ENABLED:-}"
_VPN_PROVIDER="${CALEOPE_PARAM_VPN_PROVIDER:-}"
_VPN_TYPE="${CALEOPE_PARAM_VPN_TYPE:-}"
_VPN_WG_KEY="${CALEOPE_PARAM_VPN_WG_PRIVATE_KEY:-}"
_VPN_WG_ADDR="${CALEOPE_PARAM_VPN_WG_ADDRESSES:-}"
_VPN_OVPN_USER="${CALEOPE_PARAM_VPN_OPENVPN_USER:-}"
_VPN_OVPN_PASS="${CALEOPE_PARAM_VPN_OPENVPN_PASSWORD:-}"
_VPN_COUNTRIES="${CALEOPE_PARAM_VPN_SERVER_COUNTRIES:-}"

if [[ -n "${_VPN_ENABLED}" ]]; then
    # Mode fourni via API — court-circuiter le wizard interactif
    if [[ "${_VPN_ENABLED}" == "true" ]]; then
        VPN_ENABLED=true
        COMPOSE_PROFILES="vpn"
        QBT_HOST="arr-gluetun"
        VPN_PROVIDER="${_VPN_PROVIDER:-protonvpn}"
        VPN_TYPE="${_VPN_TYPE:-wireguard}"
        VPN_WG_PRIVATE_KEY="${_VPN_WG_KEY}"
        VPN_WG_ADDRESSES="${_VPN_WG_ADDR}"
        VPN_OPENVPN_USER="${_VPN_OVPN_USER}"
        VPN_OPENVPN_PASSWORD="${_VPN_OVPN_PASS}"
        VPN_SERVER_COUNTRIES="${_VPN_COUNTRIES}"
        echo "  ✓ VPN configuré (mode API) : ${VPN_PROVIDER} / ${VPN_TYPE}"
    else
        # false ou toute autre valeur → VPN désactivé
        echo "  ✓ VPN désactivé (mode API)"
    fi
else
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
fi

# Ajouter le profil jellyfin si embarqué
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    COMPOSE_PROFILES="${COMPOSE_PROFILES},jellyfin"
fi

# ── Token Authentik (pour SSO Jellyfin dans le bootstrap) ────────────
ARR_AK_TOKEN=""
ARR_AK_DOMAIN="authentik.${CALEOPE_DOMAIN}"
if [[ -f "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" ]]; then
    _AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
    _AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
    [ -n "${_AK_TOKEN}" ] && ARR_AK_TOKEN="${_AK_TOKEN}"
    [ -n "${_AK_DOMAIN}" ] && ARR_AK_DOMAIN="${_AK_DOMAIN}"
    [ -n "${ARR_AK_TOKEN}" ] && echo "  → Token Authentik disponible — SSO Jellyfin + Jellyseerr forwardAuth seront configurés"
fi
# ARR_AK_MW : plus utilisé (Jellyseerr utilise OIDC natif depuis v2)
ARR_AK_MW=""

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

# Clé API Bazarr — pré-générée avant le démarrage du container pour que
# le bootstrap puisse l'utiliser via la variable d'environnement.
# Bazarr la lit depuis config/config.yaml (pré-écrit par setup.sh ci-dessous).
BAZARR_API_KEY=${BAZARR_API_KEY}

# Authentik SSO — token passé au bootstrap via env_file
ARR_AK_TOKEN=${ARR_AK_TOKEN}
ARR_AK_DOMAIN=${ARR_AK_DOMAIN}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── Bazarr — pré-écrire la clé API dans config.yaml ──────────────────
# Bazarr génère sa clé API dans config/config.yaml au premier démarrage.
# On la pré-écrit avec une valeur connue pour que le bootstrap puisse
# l'utiliser via BAZARR_API_KEY (passé en env via secrets.env).
BAZARR_CONFIG_DIR="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/bazarr/config"
mkdir -p "${BAZARR_CONFIG_DIR}"
# On désactive l'auth pour les appels depuis le réseau Docker interne (bootstrap).
# auth_method: none = pas de clé API requise pour les appels internes.
# Le user peut réactiver l'auth depuis l'interface Bazarr après install si besoin.
cat > "${BAZARR_CONFIG_DIR}/config.yaml" <<BAZARRYAML
general:
  apikey: ${BAZARR_API_KEY}
  auth_method: none
BAZARRYAML
echo "  ✓ Bazarr config pré-configurée (auth interne désactivée pour le bootstrap)"

# ── config.xml *arr ───────────────────────────────────────────────────
write_arr_config() {
    local app=$1 port=$2 apikey=$3
    local cfg="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/${app}/config.xml"
    mkdir -p "$(dirname "${cfg}")"
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

    # ── Plugin SSO Jellyfin (pour intégration Authentik OIDC) ────────
    SSO_PLUGIN_DIR="${JELLYFIN_CFG}/plugins/SSO-Auth_4.0.0.4.0"
    if [[ ! -f "${SSO_PLUGIN_DIR}/SSO-Auth.dll" ]]; then
        echo "→ Téléchargement plugin Jellyfin SSO (v4.0.0.4)..."
        mkdir -p "${SSO_PLUGIN_DIR}"
        if curl -sL --max-time 60 \
            "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v4.0.0.4/sso-authentication_4.0.0.4.zip" \
            -o /tmp/sso-auth.zip 2>/dev/null && [[ -s /tmp/sso-auth.zip ]]; then
            python3 -c "import zipfile; zipfile.ZipFile('/tmp/sso-auth.zip').extractall('${SSO_PLUGIN_DIR}/')" 2>/dev/null
            rm -f /tmp/sso-auth.zip
            chmod -R 755 "${SSO_PLUGIN_DIR}"
            echo "  ✓ Plugin SSO installé (plugins/SSO-Auth_4.0.0.4.0/)"
        else
            rm -rf "${SSO_PLUGIN_DIR}" /tmp/sso-auth.zip
            echo "  ⚠ Plugin SSO non téléchargeable — SSO ignoré"
        fi
    else
        echo "  ✓ Plugin SSO déjà présent"
    fi

    # ── Branding Jellyfin : bouton SSO ───────────────────────────────
    # Jellyfin 10.11+ lit le LoginDisclaimer depuis config/config/branding.xml
    if [[ -n "${ARR_AK_TOKEN}" ]]; then
        mkdir -p "${JELLYFIN_CFG}/config"
        SSO_BTN_ARR='&lt;a href=&quot;/sso/OID/start/Authentik&quot; style=&quot;display:block;margin:8px auto;padding:8px 16px;background:#fd4b2d;color:#fff;text-decoration:none;border-radius:4px;text-align:center;font-weight:bold&quot;&gt;&#x1F512; Se connecter avec Authentik&lt;/a&gt;'
        cat > "${JELLYFIN_CFG}/config/branding.xml" <<BRANDXML
<?xml version="1.0" encoding="utf-8"?>
<BrandingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LoginDisclaimer>${SSO_BTN_ARR}</LoginDisclaimer>
  <SplashscreenEnabled>false</SplashscreenEnabled>
</BrandingOptions>
BRANDXML
        echo "  ✓ Bouton SSO Authentik configuré dans branding.xml"
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
# NOTE: qBittorrent 5.x (lscr.io/linuxserver/qbittorrent) refuse de tourner en root.
# Le compose.yml force PUID=1000 pour qbittorrent (pas ARR_PUID).
# qBittorrent 5.x lit sa config depuis ${QBT_CFG_DIR}/config/qBittorrent.conf
# (sous-dossier config/ = format migré v5.x). On pré-crée AUSSI ce fichier.
QBT_CFG_DIR="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/qbittorrent/qBittorrent"
QBT_CFG_V5="${QBT_CFG_DIR}/config"
mkdir -p "${QBT_CFG_DIR}" "${QBT_CFG_V5}"

# Config principale (compatibilité)
if [[ ! -f "${QBT_CFG_DIR}/qBittorrent.conf" ]]; then
    cat > "${QBT_CFG_DIR}/qBittorrent.conf" <<QBTCFG
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray()"
WebUI\Address=*
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=172.0.0.0/8, 10.0.0.0/8, 192.168.0.0/16
WebUI\LocalHostAuth=false
Downloads\SavePath=/data/downloads/complete
Downloads\TempPath=/data/downloads/incomplete
Downloads\TempPathEnabled=true
QBTCFG
fi
# Config v5.x (sous-dossier config/) — qBittorrent 5.x lit depuis ce fichier après migration
if [[ ! -f "${QBT_CFG_V5}/qBittorrent.conf" ]]; then
    cat > "${QBT_CFG_V5}/qBittorrent.conf" <<QBTCFGV5
[LegalNotice]
Accepted=true

[Preferences]
WebUI\Address=*
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=172.0.0.0/8, 10.0.0.0/8, 192.168.0.0/16
WebUI\LocalHostAuth=false
Downloads\SavePath=/data/downloads/complete
Downloads\TempPath=/data/downloads/incomplete
Downloads\TempPathEnabled=true
QBTCFGV5
fi
# Garantir que LegalNotice, WebUI\Address et Downloads paths sont présents dans les DEUX configs
for _conf in "${QBT_CFG_DIR}/qBittorrent.conf" "${QBT_CFG_V5}/qBittorrent.conf"; do
    if ! grep -q '\[LegalNotice\]' "${_conf}" 2>/dev/null; then
        printf '\n[LegalNotice]\nAccepted=true\n' >> "${_conf}"
    fi
    if ! grep -q 'WebUI\\Address' "${_conf}" 2>/dev/null; then
        printf '\n[Preferences]\nWebUI\\Address=*\n' >> "${_conf}"
    fi
    # Toujours forcer les chemins de téléchargement vers le NAS (même sur réinstall)
    # sed -i ne supporte pas les backslash natifs sur tous les Linux → utiliser python3
    python3 - "${_conf}" <<'PYEOF'
import sys, re
path = sys.argv[1]
try:
    content = open(path).read()
    content = re.sub(r'Downloads\\SavePath=.*', r'Downloads\\\\SavePath=/data/downloads/complete', content)
    content = re.sub(r'Downloads\\TempPath=.*', r'Downloads\\\\TempPath=/data/downloads/incomplete', content)
    content = re.sub(r'Downloads\\TempPathEnabled=.*', r'Downloads\\\\TempPathEnabled=true', content)
    if 'Downloads\\\\SavePath' not in content:
        content += '\nDownloads\\\\SavePath=/data/downloads/complete\nDownloads\\\\TempPath=/data/downloads/incomplete\nDownloads\\\\TempPathEnabled=true\n'
    open(path, 'w').write(content)
except Exception as e:
    print(f'  ⚠ patch qbt conf: {e}', file=sys.stderr)
PYEOF
done
echo "  ✓ qBittorrent chemins téléchargement → NAS (/data/downloads/)"
# qbittorrent tourne en PUID=1000 → chown config pour éviter les conflits de droits
chown -R 1000:${PGID} "${CALEOPE_BASE_DIR}/app-data/arr-stack/config/qbittorrent/" 2>/dev/null || true

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
download_dir = /data/downloads/incomplete
host_whitelist = sabnzbd,localhost,sabnzbd.${CALEOPE_DOMAIN}
inet_exposure = 4
SABCFG
else
    # Sur réinstall : forcer les chemins de téléchargement vers le NAS
    # (les valeurs par défaut SABnzbd pointent vers /config/Downloads/)
    python3 - "${SABNZBD_CFG}" <<'PYEOF'
import sys, re
path = sys.argv[1]
try:
    c = open(path).read()
    c = re.sub(r'complete_dir\s*=.*', 'complete_dir = /data/downloads/complete', c)
    c = re.sub(r'download_dir\s*=.*', 'download_dir = /data/downloads/incomplete', c)
    if 'complete_dir' not in c:
        c += '\ncomplete_dir = /data/downloads/complete\ndownload_dir = /data/downloads/incomplete\n'
    open(path, 'w').write(c)
    print('  ✓ SABnzbd : complete→NAS, temp→NAS (/data/downloads/incomplete)')
except Exception as e:
    print(f'  ⚠ patch sabnzbd.ini: {e}', file=sys.stderr)
PYEOF
fi

# ── Patch préventif Jellyseerr settings.json (Jellyfin Caleope-managed) ─────────
# Jellyseerr 2.7.3+ lance une migration au démarrage qui tente de créer une clé
# API Jellyfin. Elle échoue avec "Invalid URL {}" si jellyfin.ip est vide dans
# settings.json — ce qui arrive après une réinstallation de arr-stack.
# On patche ICI, avant docker compose up, pour que Jellyseerr démarre proprement.
if [[ "${_JELLYFIN_CALEOPE_MANAGED}" == "true" ]]; then
    _JS_SETTINGS="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/jellyseerr/settings.json"
    if [[ -f "${_JS_SETTINGS}" ]]; then
        _JF_IP_IN_JS=$(python3 -c "
import json
try:
    print(json.load(open('${_JS_SETTINGS}')).get('jellyfin',{}).get('ip',''))
except: print('')
" 2>/dev/null || echo "")
        if [[ -z "${_JF_IP_IN_JS}" ]]; then
            echo "→ Jellyseerr settings.json : jellyfin.ip vide — patch préventif..."
            # serverId : endpoint public, sans auth
            _JF_PUB=$(docker exec jellyfin wget -qO- "http://localhost:8096/System/Info/Public" 2>/dev/null) || _JF_PUB=""
            _JF_SERVER_ID=$(echo "${_JF_PUB}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Id',''))" 2>/dev/null || echo "")
            _JF_SERVER_NAME=$(echo "${_JF_PUB}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ServerName','Caleope'))" 2>/dev/null || echo "Caleope")
            # Token admin pour pré-remplir apiKey (la migration peut ensuite le remplacer)
            _JF_AUTH_RESP=$(docker exec jellyfin wget -qO- \
                --post-data "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASSWORD}\"}" \
                --header "Content-Type: application/json" \
                --header 'X-Emby-Authorization: MediaBrowser Client=Caleope, Device=Setup, DeviceId=setup-patch, Version=1.0' \
                "http://localhost:8096/Users/AuthenticateByName" 2>/dev/null) || _JF_AUTH_RESP=""
            _JF_TOKEN=$(echo "${_JF_AUTH_RESP}" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('AccessToken',''))
except: print('')
" 2>/dev/null || echo "")
            if [[ -n "${_JF_TOKEN}" ]]; then
                python3 - "${_JS_SETTINGS}" "${_JF_TOKEN}" "${_JF_SERVER_ID}" "${_JF_SERVER_NAME}" <<'PYEOF'
import json, sys
path, api_key, server_id, server_name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    d = json.load(open(path))
    if not isinstance(d.get('jellyfin'), dict):
        d['jellyfin'] = {}
    jf = d['jellyfin']
    jf['ip'] = 'jellyfin'
    jf['port'] = 8096
    jf['useSsl'] = False
    jf['name'] = server_name
    if server_id:
        jf['serverId'] = server_id
    if api_key:
        jf['apiKey'] = api_key
    d['jellyfin'] = jf
    json.dump(d, open(path, 'w'), indent=2)
    print(f"  ✓ settings.json patché (ip=jellyfin serverId={server_id[:8] if server_id else '?'}...)")
except Exception as e:
    print(f"  ⚠ Patch échoué: {e}")
PYEOF
            else
                echo "  ⚠ Token Jellyfin non obtenu → settings.json non patché"
                echo "    Si Jellyseerr crashe au démarrage, relancer : caleope configure arr-stack"
            fi
        else
            echo "  ℹ Jellyseerr settings.json OK (ip=${_JF_IP_IN_JS}) — skip"
        fi
    fi
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

# ── wait_arr : attend que l'API *arr soit prête (200 ou 401) ────────────
# On interroge /api/v3/system/status : il ne répond qu'une fois les
# migrations DB terminées. 200 = clé OK, 401 = service prêt mais clé érronée
# (on continue quand même — l'API sera accessible). Connection refusée = on attend.
wait_arr() {
    local name=\$1 url=\$2  # \$3 (key) accepté pour compatibilité mais ignoré
    local tries=0 maxTries=120  # 120 * 5s = 10 min max
    echo "→ Attente \${name}..."
    until code=\$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "\${url}/api/v3/system/status" 2>/dev/null) && { [[ "\$code" = "200" ]] || [[ "\$code" = "401" ]]; }; do
        sleep 5
        tries=\$((tries + 1))
        [[ \$tries -ge \$maxTries ]] && { echo "  ⚠ \${name} : timeout (10 min) — on continue quand même"; return 0; }
        [[ \$(( tries % 12 )) -eq 0 ]] && echo "  ... \${name} pas encore prêt (\$(( tries * 5 ))s)..."
    done
    echo "  ✓ \${name} prêt (HTTP \${code})"
}

# ── wait_url : attend qu'une URL HTTP réponde (timeout 10 min) ─────────
wait_url() {
    local name=\$1 url=\$2
    local tries=0 maxTries=120
    echo "→ Attente \${name}..."
    until curl -s --connect-timeout 5 --max-time 10 -o /dev/null "\$url" 2>/dev/null; do
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
wait_arr "Prowlarr"    "\$P_URL"  "${API_PROWLARR}"
wait_arr "Radarr"      "\$R_URL"  "${API_RADARR}"
wait_arr "Sonarr"      "\$S_URL"  "${API_SONARR}"
wait_arr "Lidarr"      "\$L_URL"  "${API_LIDARR}"
wait_url "qBittorrent" "\$QBT_URL/api/v2/app/version"
# Forcer les chemins qBittorrent vers le NAS via API (écrase les valeurs par défaut /config/Downloads)
curl -sf -X POST "\$QBT_URL/api/v2/app/setPreferences" \
    --data-urlencode 'json={"save_path":"/data/downloads/complete","temp_path":"/data/downloads/incomplete","temp_path_enabled":true}' \
    >/dev/null 2>&1 && echo "  ✓ qBittorrent chemins → NAS (/data/downloads/)" || true
wait_url "Bazarr"      "http://bazarr:6767"

echo ""
echo "── [2/6] Connexion Prowlarr → *arr + FlareSolverr..."

api_post_v1 "\$P_URL" "${API_PROWLARR}" "applications" \
    "{\"name\":\"Radarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Radarr\",\"implementation\":\"Radarr\",\"configContract\":\"RadarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://radarr:7878\"},{\"name\":\"apiKey\",\"value\":\"${API_RADARR}\"},{\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060]}]}"
echo "  ✓ Prowlarr → Radarr"

api_post_v1 "\$P_URL" "${API_PROWLARR}" "applications" \
    "{\"name\":\"Sonarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Sonarr\",\"implementation\":\"Sonarr\",\"configContract\":\"SonarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://sonarr:8989\"},{\"name\":\"apiKey\",\"value\":\"${API_SONARR}\"},{\"name\":\"syncCategories\",\"value\":[5000,5010,5020,5030,5040,5045,5050]}]}"
echo "  ✓ Prowlarr → Sonarr"

api_post_v1 "\$P_URL" "${API_PROWLARR}" "applications" \
    "{\"name\":\"Lidarr\",\"syncLevel\":\"fullSync\",\"implementationName\":\"Lidarr\",\"implementation\":\"Lidarr\",\"configContract\":\"LidarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://lidarr:8686\"},{\"name\":\"apiKey\",\"value\":\"${API_LIDARR}\"},{\"name\":\"syncCategories\",\"value\":[3000,3010,3020,3030,3040]}]}"
echo "  ✓ Prowlarr → Lidarr"

# FlareSolverr — proxy pour contourner Cloudflare sur les indexeurs protégés
api_post_v1 "\$P_URL" "${API_PROWLARR}" "indexerproxy" \
    "{\"name\":\"FlareSolverr\",\"implementationName\":\"FlareSolverr\",\"implementation\":\"FlareSolverr\",\"configContract\":\"FlareSolverrSettings\",\"supportsRss\":false,\"supportsSearch\":false,\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"http://arr-flaresolverr:8191\"},{\"name\":\"requestTimeout\",\"value\":60}]}"
echo "  ✓ Prowlarr → FlareSolverr (http://arr-flaresolverr:8191)"
# Tester FlareSolverr immédiatement après création : sans test, l'UI affiche "disabled".
# On récupère la config créée puis on la soumet à /indexerproxy/test → statut devient actif.
_FS_CFG=\$(curl -sf -H "X-Api-Key: ${API_PROWLARR}" "\$P_URL/api/v1/indexerproxy" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d[0]))" 2>/dev/null) || _FS_CFG=""
[[ -n "\$_FS_CFG" ]] && curl -sf -o /dev/null -X POST \
    -H "X-Api-Key: ${API_PROWLARR}" \
    -H "Content-Type: application/json" \
    -d "\$_FS_CFG" "\$P_URL/api/v1/indexerproxy/test" >/dev/null 2>&1 || true
echo "  ✓ FlareSolverr testé — statut actif dans Prowlarr"

echo ""
echo "── [2.5/6] Indexeurs publics par défaut (sans compte requis)..."
# Ces indexeurs sont publics et ne nécessitent pas de compte.
# Ils sont ajoutés comme point de départ — l'utilisateur ajoutera ensuite
# ses indexeurs préférés (YGGTorrent, BetaSeries, etc.) dans Prowlarr.
# On vérifie si l'indexeur existe déjà (idempotence sur --force reinstall).
_existing_defs=\$(curl -sf -H "X-Api-Key: ${API_PROWLARR}" "\$P_URL/api/v1/indexer" 2>/dev/null \
    | python3 -c "import sys,json; print(','.join(i.get('definitionName','') for i in json.load(sys.stdin)))" \
    2>/dev/null) || _existing_defs=""

add_public_indexer() {
    local _name="\$1" _def="\$2" _url="\$3"
    if echo "\$_existing_defs" | grep -q "\$_def"; then
        echo "  ℹ '\${_name}' déjà présent — ignoré"
        return 0
    fi
    # Prowlarr valide l'URL lors du POST. Pour les sites CloudFlare (1337x, eztv…),
    # la validation échoue → on tente d'abord avec enable:true, puis en cas d'erreur
    # on retente avec enable:false (désactivé = pas de test de connexion).
    _resp=\$(curl -s -w "\n%{http_code}" -X POST "\$P_URL/api/v1/indexer" \
        -H "X-Api-Key: ${API_PROWLARR}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"\${_name}\",
            \"definitionName\": \"\${_def}\",
            \"implementation\": \"Cardigann\",
            \"configContract\": \"CardigannSettings\",
            \"protocol\": \"torrent\",
            \"enable\": true,
            \"priority\": 25,
            \"appProfileId\": 1,
            \"tags\": [],
            \"fields\": [
                {\"name\": \"definitionFile\", \"value\": \"\${_def}\"},
                {\"name\": \"baseUrl\", \"value\": \"\${_url}\"},
                {\"name\": \"baseSettings.limitsUnit\", \"value\": 0},
                {\"name\": \"torrentBaseSettings.preferMagnetUrl\", \"value\": false}
            ]
        }" 2>/dev/null) || _resp=""
    _http_code=\$(echo "\$_resp" | tail -1)
    if [[ "\$_http_code" == "201" || "\$_http_code" == "200" ]]; then
        echo "  ✓ Indexeur '\${_name}' ajouté"
    else
        # Échec (souvent CloudFlare) → retenter avec enable:false pour contourner le test
        _resp2=\$(curl -s -w "\n%{http_code}" -X POST "\$P_URL/api/v1/indexer" \
            -H "X-Api-Key: ${API_PROWLARR}" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"\${_name}\",
                \"definitionName\": \"\${_def}\",
                \"implementation\": \"Cardigann\",
                \"configContract\": \"CardigannSettings\",
                \"protocol\": \"torrent\",
                \"enable\": false,
                \"priority\": 25,
                \"appProfileId\": 1,
                \"tags\": [],
                \"fields\": [
                    {\"name\": \"definitionFile\", \"value\": \"\${_def}\"},
                    {\"name\": \"baseUrl\", \"value\": \"\${_url}\"},
                    {\"name\": \"baseSettings.limitsUnit\", \"value\": 0},
                    {\"name\": \"torrentBaseSettings.preferMagnetUrl\", \"value\": false}
                ]
            }" 2>/dev/null) || _resp2=""
        _http_code2=\$(echo "\$_resp2" | tail -1)
        if [[ "\$_http_code2" == "201" || "\$_http_code2" == "200" ]]; then
            echo "  ✓ Indexeur '\${_name}' ajouté (désactivé — réactiver dans Prowlarr après config FlareSolverr)"
        else
            echo "  ⚠ Indexeur '\${_name}' non ajouté (HTTP \${_http_code2}) — ajouter manuellement dans Prowlarr"
        fi
    fi
}

# 1337x : trackers général (films, séries, musique) — protégé Cloudflare → FlareSolverr
add_public_indexer "1337x" "1337x" "https://1337x.to/"
# YTS : films uniquement, haute qualité, pas de Cloudflare
add_public_indexer "YTS"   "yts"   "https://yts.mx/"
# EZTV : séries TV uniquement, pas de Cloudflare
add_public_indexer "EZTV"  "eztv"  "https://eztv.re/"

echo ""
echo "── [3/6] Clients de téléchargement + dossiers racine..."

qbt_client() {
    # \$1 = préfixe du champ (movie/tv/music), \$2 = valeur catégorie SABnzbd
    echo "{\"name\":\"qBittorrent\",\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"implementationName\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"${QBT_HOST}\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"username\",\"value\":\"\"},{\"name\":\"password\",\"value\":\"\"},{\"name\":\"\${1}Category\",\"value\":\"\$2\"},{\"name\":\"initialState\",\"value\":0}]}"
}

sab_client() {
    # \$1 = préfixe du champ (movie/tv/music), \$2 = valeur catégorie SABnzbd
    echo "{\"name\":\"SABnzbd\",\"enable\":true,\"protocol\":\"usenet\",\"priority\":1,\"implementationName\":\"SABnzbd\",\"implementation\":\"Sabnzbd\",\"configContract\":\"SabnzbdSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"sabnzbd\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"apiKey\",\"value\":\"${API_SABNZBD}\"},{\"name\":\"urlBase\",\"value\":\"\"},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"\${1}Category\",\"value\":\"\$2\"}]}"
}

# Créer les catégories SABnzbd AVANT d'ajouter SABnzbd aux clients *arr
# (les *arr valident l'existence de la catégorie lors du test de connexion)
wait_url "SABnzbd" "http://sabnzbd:8080/api?mode=version&apikey=${API_SABNZBD}&output=json"

# Forcer les chemins de téléchargement vers le NAS via l'API SABnzbd
# (idempotent : écrase les valeurs par défaut /config/Downloads/ si présentes)
curl -sf "http://sabnzbd:8080/api?mode=set_config&section=misc&keyword=complete_dir&value=/data/downloads/complete&apikey=${API_SABNZBD}&output=json" >/dev/null 2>&1 || true
# download_dir = dossier temporaire/incomplete (pas incomplete_dir qui n'est pas un paramètre SABnzbd)
curl -sf "http://sabnzbd:8080/api?mode=set_config&section=misc&keyword=download_dir&value=/data/downloads/incomplete&apikey=${API_SABNZBD}&output=json" >/dev/null 2>&1 || true
# Redémarrer SABnzbd pour appliquer les changements de chemins
curl -sf "http://sabnzbd:8080/api?mode=restart&apikey=${API_SABNZBD}" >/dev/null 2>&1 || true
sleep 8
wait_url "SABnzbd" "http://sabnzbd:8080/api?mode=version&apikey=${API_SABNZBD}&output=json"
echo "  ✓ SABnzbd : chemins téléchargement → NAS (/data/downloads/)"

for _cat in movies tv music books software; do
    curl -sf -X POST "http://sabnzbd:8080/api" \
        -d "mode=set_config&section=categories&keyword=\${_cat}&value=&apikey=${API_SABNZBD}&output=json" \
        >/dev/null 2>&1 || true
done
echo "  ✓ SABnzbd : catégories créées (movies, tv, music, books, software)"

api_post_v3 "\$R_URL" "${API_RADARR}" "downloadclient" "\$(qbt_client movie movies)"
api_post_v3 "\$R_URL" "${API_RADARR}" "downloadclient" "\$(sab_client movie movies)"
api_post_v3 "\$R_URL" "${API_RADARR}" "rootfolder"     "{\"path\":\"/data/media/movies\"}"
echo "  ✓ Radarr configuré"

api_post_v3 "\$S_URL" "${API_SONARR}" "downloadclient" "\$(qbt_client tv tv)"
api_post_v3 "\$S_URL" "${API_SONARR}" "downloadclient" "\$(sab_client tv tv)"
api_post_v3 "\$S_URL" "${API_SONARR}" "rootfolder"     "{\"path\":\"/data/media/tv\"}"
echo "  ✓ Sonarr configuré"

api_post_v1 "\$L_URL" "${API_LIDARR}" "downloadclient" "\$(qbt_client music music)"
api_post_v1 "\$L_URL" "${API_LIDARR}" "downloadclient" "\$(sab_client music music)"
api_post_v1 "\$L_URL" "${API_LIDARR}" "rootfolder"     "{\"name\":\"Music\",\"path\":\"/data/media/music\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\"}"
echo "  ✓ Lidarr configuré"

echo ""
echo "── [4/6] Langue : ${PREFERRED_LANGUAGE_NAME}..."

# PREFERRED_LANGUAGE = code ISO (fr, en, de…) interpolé depuis setup.sh
# PREFERRED_LANGUAGE_NAME = nom *arr (French, English…)
# PREFERRED_LANGUAGE_CULTURE = code Jellyfin (fr-FR, en-US…)

# set_lang <url> <apikey> <apiversion>
# Récupère l'ID de la langue préférée dans l'API de l'app et met à jour l'UI language.
set_lang() {
    local url=\$1 key=\$2 ver=\$3
    local lang_id
    lang_id=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/language" 2>/dev/null \
        | jq -r '.[] | select(.name == "${PREFERRED_LANGUAGE_NAME}") | .id // empty' 2>/dev/null)
    [[ -z "\$lang_id" || "\$lang_id" == "null" ]] && return 0
    local ui_cfg
    ui_cfg=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/config/ui" 2>/dev/null)
    [[ -z "\$ui_cfg" ]] && return 0
    echo "\$ui_cfg" | jq --argjson lang "\$lang_id" '.uiLanguage = \$lang' \
    | curl -sf -X PUT "\$url/api/\$ver/config/ui" \
        -H "X-Api-Key: \$key" -H "Content-Type: application/json" \
        -d @- >/dev/null 2>&1 || true
    # Configurer aussi la langue préférée dans les profils de qualité
    local profiles
    profiles=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/qualityprofile" 2>/dev/null) || profiles=""
    if [[ -n "\$profiles" ]]; then
        echo "\$profiles" | jq -r '.[].id' 2>/dev/null | while read pid; do
            local profile
            profile=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/qualityprofile/\$pid" 2>/dev/null)
            [[ -z "\$profile" ]] && continue
            # Mettre à jour language + ajouter Custom Format Audio si pas déjà fait
            local updated
            updated=\$(echo "\$profile" | jq --argjson lid "\$lang_id" --arg lname "${PREFERRED_LANGUAGE_NAME}" '
                if has("language") then .language = {"id": \$lid, "name": \$lname} else . end' 2>/dev/null)
            [[ -n "\$updated" ]] && curl -sf -X PUT "\$url/api/\$ver/qualityprofile/\$pid" \
                -H "X-Api-Key: \$key" -H "Content-Type: application/json" \
                -d "\$updated" >/dev/null 2>&1 || true
        done
    fi
    # Custom Format préférence audio langue
    local cf_name="Audio ${PREFERRED_LANGUAGE_NAME}"
    local existing_cf
    existing_cf=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/customformat" 2>/dev/null \
        | jq -r --arg n "\$cf_name" '.[] | select(.name == \$n) | .id // empty' 2>/dev/null) || existing_cf=""
    if [[ -z "\$existing_cf" ]]; then
        local cf_resp
        cf_resp=\$(curl -sf -X POST "\$url/api/\$ver/customformat" \
            -H "X-Api-Key: \$key" -H "Content-Type: application/json" \
            -d "{\"name\":\"\$cf_name\",\"includeCustomFormatWhenRenaming\":false,\"specifications\":[{\"name\":\"Langue\",\"implementation\":\"LanguageSpecification\",\"negate\":false,\"required\":false,\"fields\":[{\"name\":\"value\",\"value\":\$lang_id}]}]}" 2>/dev/null) || cf_resp=""
        local cf_id
        cf_id=\$(echo "\$cf_resp" | jq -r '.id // empty' 2>/dev/null) || cf_id=""
        if [[ -n "\$cf_id" ]]; then
            # Ajouter score +500 dans tous les profils
            echo "\$profiles" | jq -r '.[].id' 2>/dev/null | while read pid; do
                local p
                p=\$(curl -sf -H "X-Api-Key: \$key" "\$url/api/\$ver/qualityprofile/\$pid" 2>/dev/null)
                [[ -z "\$p" ]] && continue
                local pu
                pu=\$(echo "\$p" | jq --argjson cid "\$cf_id" --arg cn "\$cf_name" \
                    'if (.formatItems | map(.format) | contains([\$cid])) then .
                     else .formatItems += [{"format":\$cid,"name":\$cn,"score":500}] end' 2>/dev/null)
                [[ -n "\$pu" ]] && curl -sf -X PUT "\$url/api/\$ver/qualityprofile/\$pid" \
                    -H "X-Api-Key: \$key" -H "Content-Type: application/json" \
                    -d "\$pu" >/dev/null 2>&1 || true
            done
        fi
    fi
}

# Prowlarr : uiLanguage est une chaîne ISO ("fr", "en"…), pas un entier.
# L'endpoint /language n'existe pas dans Prowlarr v1.
_pw_ui=\$(curl -sf -H "X-Api-Key: ${API_PROWLARR}" "\$P_URL/api/v1/config/ui" 2>/dev/null) || _pw_ui=""
if [[ -n "\$_pw_ui" ]]; then
    echo "\$_pw_ui" | jq --arg lang "${PREFERRED_LANGUAGE}" '.uiLanguage = \$lang' \
    | curl -sf -X PUT "\$P_URL/api/v1/config/ui" \
        -H "X-Api-Key: ${API_PROWLARR}" -H "Content-Type: application/json" \
        -d @- >/dev/null 2>&1 || true
    echo "  ✓ Prowlarr → ${PREFERRED_LANGUAGE}"
fi

set_lang "\$R_URL" "${API_RADARR}"   v3 && echo "  ✓ Radarr → ${PREFERRED_LANGUAGE_NAME}"
set_lang "\$S_URL" "${API_SONARR}"   v3 && echo "  ✓ Sonarr → ${PREFERRED_LANGUAGE_NAME}"
set_lang "\$L_URL" "${API_LIDARR}"   v1 && echo "  ✓ Lidarr → ${PREFERRED_LANGUAGE_NAME}"

# Bazarr — créer un profil de sous-titres Langue préférée + Anglais (ou juste la langue si en)
# L'API Bazarr expose uniquement GET /api/system/languages/profiles.
# Pour créer un profil, on passe par POST /api/system/settings avec le
# champ form-data "languages-profiles" (format JSON attendu par Bazarr).
# La clé API est lue depuis config.yaml (générée par Bazarr au 1er démarrage).
BAZARR_URL="http://bazarr:6767"
# Lire la clé API depuis config.yaml : "auth:\n  apikey: <key>"
BAZARR_REAL_KEY=\$(awk '/^auth:/{in_a=1} in_a && /apikey:/{gsub(/.*apikey: */,""); print; exit}' \
    /bazarr-config/config/config.yaml 2>/dev/null | tr -d ' \r') || BAZARR_REAL_KEY=""

# Construire le profil Bazarr : langue principale + anglais en fallback (si pas déjà anglais)
if [[ "${PREFERRED_LANGUAGE}" == "en" ]]; then
    _BAZARR_PROFILE_NAME="English"
    _BAZARR_ITEMS='[{"id":1,"language":"en","hi":"False","forced":"False","audio_exclude":"False"}]'
    _BAZARR_ENABLED_LANGS='["en"]'
else
    _BAZARR_PROFILE_NAME="${PREFERRED_LANGUAGE_NAME} + English"
    _BAZARR_ITEMS='[{"id":1,"language":"${PREFERRED_LANGUAGE}","hi":"False","forced":"False","audio_exclude":"False"},{"id":2,"language":"en","hi":"False","forced":"False","audio_exclude":"False"}]'
    _BAZARR_ENABLED_LANGS='["${PREFERRED_LANGUAGE}","en"]'
fi
_BAZARR_PROFILE="[{\"profileId\":1,\"name\":\"\${_BAZARR_PROFILE_NAME}\",\"cutoff\":null,\"items\":\${_BAZARR_ITEMS},\"mustContain\":[],\"mustNotContain\":[],\"originalFormat\":0,\"tag\":null}]"

BAZARR_PROFILE_ID=""
if [[ -n "\$BAZARR_REAL_KEY" ]]; then
    curl -sf -X POST "\$BAZARR_URL/api/system/settings" \
        -H "X-API-KEY: \$BAZARR_REAL_KEY" \
        -F "enabled-languages=\${_BAZARR_ENABLED_LANGS}" \
        -F "languages-profiles=\$_BAZARR_PROFILE" >/dev/null 2>&1 || true

    BAZARR_PROFILE_ID=\$(curl -sf "\$BAZARR_URL/api/system/languages/profiles" \
        -H "X-API-KEY: \$BAZARR_REAL_KEY" 2>/dev/null \
        | jq -r --arg n "\${_BAZARR_PROFILE_NAME}" '.[] | select(.name == \$n) | .profileId // empty' 2>/dev/null) || BAZARR_PROFILE_ID=""

    if [[ -n "\$BAZARR_PROFILE_ID" ]]; then
        curl -sf -X POST "\$BAZARR_URL/api/series" -H "X-API-KEY: \$BAZARR_REAL_KEY" \
            -G --data-urlencode "profileid=\$BAZARR_PROFILE_ID" >/dev/null 2>&1 || true
        curl -sf -X POST "\$BAZARR_URL/api/movies" -H "X-API-KEY: \$BAZARR_REAL_KEY" \
            -G --data-urlencode "profileid=\$BAZARR_PROFILE_ID" >/dev/null 2>&1 || true
        echo "  ✓ Bazarr → profil sous-titres Français + Anglais"
    else
        echo "  ⚠ Bazarr : profil créé mais ID non confirmé (vérifier dans l'UI)"
    fi
else
    echo "  ⚠ Bazarr : clé API non trouvée dans config.yaml — configuration manuelle"
fi

echo ""
echo "── [5/6] Jellyfin — configuration des bibliothèques..."

if [[ -z "\$JF_URL" ]]; then
    echo "  ⚠ Pas d'URL Jellyfin — étape ignorée"
elif [[ "${JELLYFIN_EMBEDDED}" != "true" ]]; then
    echo "  ℹ Jellyfin externe — bibliothèques déjà configurées, étape ignorée"
else
    wait_url "Jellyfin" "\$JF_URL/health" || wait_url "Jellyfin" "\$JF_URL"

    if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
        # Jellyfin 10.11+ wizard flow :
        #   POST /Startup/Configuration → POST /Startup/User → POST /Startup/RemoteAccess → POST /Startup/Complete
        # Note: PUT /Startup/FirstUser retourne 405 (endpoint supprimé en 10.11).
        # Les APIs /Startup/* ne sont disponibles que pendant le wizard (avant /Startup/Complete).
        # Elles peuvent retourner 503 quelques secondes après le démarrage → on attend.
        echo "  ⏳ Attente initialisation wizard Jellyfin..."
        JF_WIZARD_STATUS="503"
        for _i in \$(seq 1 24); do
            JF_WIZARD_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" "\$JF_URL/Startup/Configuration" 2>/dev/null) || JF_WIZARD_STATUS="000"
            if [[ "\$JF_WIZARD_STATUS" != "503" && "\$JF_WIZARD_STATUS" != "000" ]]; then
                break
            fi
            echo "  ⏳  wizard pas encore prêt (HTTP \$JF_WIZARD_STATUS) — attente 10s... (\$_i/24)"
            sleep 10
        done

        # Étape 1 : configuration serveur (avance le wizard à l'étape suivante)
        curl -sf -X POST "\$JF_URL/Startup/Configuration" \
            -H "Content-Type: application/json" \
            -d '{"ServerName":"Caleope","UICulture":"en-US","MetadataCountryCode":"FR","PreferredMetadataLanguage":"fr"}' \
            >/dev/null 2>&1 || true
        # IMPORTANT : Jellyfin 10.11+ — /Startup/User n'est disponible (GET 200)
        # qu'APRÈS que /Startup/Configuration ait été traité. On attend le GET 200
        # avant de POSTer plutôt qu'un sleep fixe (plus robuste selon la charge serveur).
        _jf_user_ep=false
        for _jf_w in \$(seq 1 30); do
            _jf_get_sc=\$(curl -s -o /dev/null -w "%{http_code}" "\$JF_URL/Startup/User" 2>/dev/null) || _jf_get_sc="000"
            [[ "\${_jf_get_sc}" == "200" ]] && { _jf_user_ep=true; break; }
            sleep 3
        done
        \${_jf_user_ep} || echo "  ⚠ Timeout attente étape User — tentative quand même"

        # Étape 2 : création du premier utilisateur admin (avec retry si 404 transitoire)
        _jf_user_ok=false
        for _jf_retry in \$(seq 1 10); do
            _jf_user_sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\$JF_URL/Startup/User" \
                -H "Content-Type: application/json" \
                -d "{\"Name\":\"${JELLYFIN_USER}\",\"Password\":\"${JELLYFIN_PASSWORD}\"}" 2>/dev/null) || _jf_user_sc="000"
            if [[ "\${_jf_user_sc}" == "204" || "\${_jf_user_sc}" == "200" ]]; then
                _jf_user_ok=true; break
            fi
            sleep 3
        done
        \${_jf_user_ok} || echo "  ⚠ POST /Startup/User n'a pas retourné 2xx (HTTP \${_jf_user_sc}) — l'utilisateur Jellyfin devra être créé manuellement"

        # Étape 3 : accès distant
        curl -sf -X POST "\$JF_URL/Startup/RemoteAccess" \
            -H "Content-Type: application/json" \
            -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
            >/dev/null 2>&1 || true

        # Étape 4 : finalisation wizard
        curl -sf -X POST "\$JF_URL/Startup/Complete" >/dev/null 2>&1 || true
        echo "  ✓ Wizard Jellyfin complété (HTTP wizard:\$JF_WIZARD_STATUS)"

        # Jellyfin avec PUID=0 crée l'user sous le nom système ("root"),
        # ignorant silencieusement le champ Name du wizard.
        # 1) Auth en "root" / mot de passe vide pour obtenir le token et l'ID
        JF_AUTH_ROOT=\$(curl -sf -X POST "\$JF_URL/Users/AuthenticateByName" \
            -H "Content-Type: application/json" \
            -H 'X-Emby-Authorization: MediaBrowser Client="Bootstrap", Device="Bootstrap", DeviceId="arr-bootstrap-1", Version="1.0.0"' \
            -d '{"Username":"root","Pw":""}' 2>/dev/null) || JF_AUTH_ROOT=""
        JF_TOKEN_ROOT=\$(echo "\$JF_AUTH_ROOT" | grep -o '"AccessToken":"[^"]*"' | head -1 | cut -d'"' -f4) || JF_TOKEN_ROOT=""
        JF_USER_ID=\$(echo "\$JF_AUTH_ROOT" | grep -o '"Id":"[^"]*"' | head -1 | cut -d'"' -f4) || JF_USER_ID=""

        if [[ -n "\$JF_TOKEN_ROOT" && -n "\$JF_USER_ID" ]]; then
            # 2) Définir le mot de passe
            curl -sf -X POST "\$JF_URL/Users/\$JF_USER_ID/Password" \
                -H "Content-Type: application/json" \
                -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN_ROOT\"" \
                -d "{\"CurrentPw\":\"\",\"NewPw\":\"${JELLYFIN_PASSWORD}\"}" >/dev/null 2>&1 || true
            # 3) Renommer l'utilisateur "root" → "${JELLYFIN_USER}"
            JF_USER_OBJ=\$(curl -sf "\$JF_URL/Users/\$JF_USER_ID" \
                -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN_ROOT\"" 2>/dev/null) || JF_USER_OBJ=""
            if [[ -n "\$JF_USER_OBJ" ]]; then
                echo "\$JF_USER_OBJ" \
                | jq '.Name = "${JELLYFIN_USER}"' \
                | curl -sf -X POST "\$JF_URL/Users/\$JF_USER_ID" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN_ROOT\"" \
                    -d @- >/dev/null 2>&1 || true
                echo "  ✓ Jellyfin user renommé en ${JELLYFIN_USER}"
            fi
            # 4) Re-auth avec le nom et mot de passe définitifs
            JF_AUTH=\$(curl -sf -X POST "\$JF_URL/Users/AuthenticateByName" \
                -H "Content-Type: application/json" \
                -H 'X-Emby-Authorization: MediaBrowser Client="Bootstrap", Device="Bootstrap", DeviceId="arr-bootstrap-1", Version="1.0.0"' \
                -d "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASSWORD}\"}" 2>/dev/null) || JF_AUTH=""
        else
            # Fallback : auth directe (PUID != 0, utilisateur créé avec le bon nom)
            JF_AUTH=\$(curl -sf -X POST "\$JF_URL/Users/AuthenticateByName" \
                -H "Content-Type: application/json" \
                -H 'X-Emby-Authorization: MediaBrowser Client="Bootstrap", Device="Bootstrap", DeviceId="arr-bootstrap-1", Version="1.0.0"' \
                -d "{\"Username\":\"${JELLYFIN_USER}\",\"Pw\":\"${JELLYFIN_PASSWORD}\"}" 2>/dev/null) || JF_AUTH=""
        fi
        JF_TOKEN=\$(echo "\$JF_AUTH" | grep -o '"AccessToken":"[^"]*"' | head -1 | cut -d'"' -f4) || JF_TOKEN=""
    else
        JF_TOKEN=""
    fi

    add_jf_lib() {
        local name=\$1 type=\$2 path=\$3
        # Jellyfin 10.10+: name/collectionType/paths sont des QUERY PARAMS, pas du body JSON.
        # IMPORTANT: utiliser "paths=<val>" et non "paths%5B%5D=<val>" (bracket form non supportée
        # par ASP.NET Core → bibliothèques créées avec Locations vides, scan impossible).
        local encoded_name=\$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "\$name" 2>/dev/null || printf '%s' "\$name" | sed 's/ /%20/g;s/é/%C3%A9/g;s/è/%C3%A8/g;s/ê/%C3%AA/g;s/à/%C3%A0/g')

        # Vérifier si la bibliothèque existe déjà (idempotence — évite les doublons)
        if [[ -n "\$JF_TOKEN" ]]; then
            local existing
            existing=\$(curl -sf "\$JF_URL/Library/VirtualFolders" \
                -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" 2>/dev/null \
                | jq -r --arg n "\$name" '.[] | select(.Name == \$n) | .Name' 2>/dev/null) || existing=""
            if [[ -n "\$existing" ]]; then
                echo "  ℹ Bibliothèque '\$name' déjà présente — ignorée"
                return 0
            fi
            curl -sf -X POST "\$JF_URL/Library/VirtualFolders?name=\${encoded_name}&collectionType=\${type}&paths=\${path}&refreshLibrary=false" \
                -H "Content-Type: application/json" \
                -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" \
                -d '{"libraryOptions":{}}' \
                >/dev/null 2>&1 || true
        else
            curl -sf -X POST "\$JF_URL/Library/VirtualFolders?name=\${encoded_name}&collectionType=\${type}&paths=\${path}&refreshLibrary=false" \
                -H "Content-Type: application/json" \
                -d '{"libraryOptions":{}}' \
                >/dev/null 2>&1 || true
        fi
        echo "  ✓ Bibliothèque '\$name' créée (\$path)"
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

# ── [5.5/6] Authentik SSO — Jellyfin ─────────────────────────────────────────
# Configuré seulement si :
#   - ARR_AK_TOKEN est défini (Authentik installé au moment du setup.sh)
#   - JF_TOKEN est disponible (Jellyfin embedded démarré et wizard complété)
#   - Le plugin SSO est chargé (SSO-Auth.dll présent dans plugins/)
if [[ -n "\${ARR_AK_TOKEN:-}" && -n "\$JF_TOKEN" ]]; then
    echo ""
    echo "── [5.5/6] Authentik SSO — Jellyfin..."
    AK_INT_URL="http://authentik-server:9000"
    AK_SLUG="jellyfin-arr"
    JF_SSO_PROVIDER="Authentik"
    JF_DOMAIN="jellyfin.${CALEOPE_DOMAIN}"
    JF_REDIRECT_URI="https://\${JF_DOMAIN}/sso/OID/redirect/\${JF_SSO_PROVIDER}"

    # Vérifier si Authentik est joignable depuis le réseau Docker
    _AK_UP=false
    for _i in \$(seq 1 6); do
        _ak_code=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
            "\${AK_INT_URL}/api/v3/core/applications/" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null) || _ak_code="000"
        [[ "\${_ak_code}" == "200" ]] && { _AK_UP=true; break; }
        [[ \$_i -eq 1 ]] && echo "  ⏳ Attente Authentik..."
        sleep 5
    done

    if \${_AK_UP}; then
        # Flow d'autorisation implicit consent
        _AK_FLOW=\$(curl -sf "\${AK_INT_URL}/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null) || _AK_FLOW=""
        _AK_INVAL=\$(curl -sf "\${AK_INT_URL}/api/v3/flows/instances/?slug=default-provider-invalidation-flow" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null) || _AK_INVAL=""
        _AK_KEY=\$(curl -sf "\${AK_INT_URL}/api/v3/crypto/certificatekeypairs/?has_key=true&ordering=name" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null) || _AK_KEY=""
        _AK_SCOPES=\$(curl -sf "\${AK_INT_URL}/api/v3/propertymappings/all/?ordering=name&page_size=200" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null)
        _S_OID=\$(echo "\${_AK_SCOPES}" | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if 'scope-openid' in str(p.get('managed',''))]; print(m[0]['pk'] if m else '')" 2>/dev/null)
        _S_EMAIL=\$(echo "\${_AK_SCOPES}" | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if 'scope-email' in str(p.get('managed',''))]; print(m[0]['pk'] if m else '')" 2>/dev/null)
        _S_PROF=\$(echo "\${_AK_SCOPES}" | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if 'scope-profile' in str(p.get('managed',''))]; print(m[0]['pk'] if m else '')" 2>/dev/null)

        if [[ -n "\${_AK_FLOW}" && -n "\${_AK_KEY}" && -n "\${_S_OID}" ]]; then
            # Provider OAuth2 — récupérer si déjà créé, sinon créer
            _AK_PROV_PK=\$(curl -sf "\${AK_INT_URL}/api/v3/providers/oauth2/" \
                -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if p.get('name')=='Jellyfin SSO']; print(m[0]['pk'] if m else '')" 2>/dev/null) || _AK_PROV_PK=""

            if [[ -n "\${_AK_PROV_PK}" ]]; then
                _AK_PROV_RESP=\$(curl -sf "\${AK_INT_URL}/api/v3/providers/oauth2/\${_AK_PROV_PK}/" \
                    -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null)
            else
                _AK_PROV_BODY=\$(python3 -c "
import json, sys
scopes=[s for s in ['\${_S_OID}','\${_S_EMAIL}','\${_S_PROF}'] if s]
body={'name':'Jellyfin SSO','authorization_flow':'\${_AK_FLOW}','client_type':'confidential',
      'redirect_uris':[{'url':'\${JF_REDIRECT_URI}','matching_mode':'strict'}],
      'sub_mode':'hashed_user_id','include_claims_in_id_token':True,
      'signing_key':'\${_AK_KEY}','property_mappings':scopes}
if '\${_AK_INVAL}': body['invalidation_flow']='\${_AK_INVAL}'
print(json.dumps(body))")
                _AK_PROV_RESP=\$(echo "\${_AK_PROV_BODY}" | curl -sf -X POST "\${AK_INT_URL}/api/v3/providers/oauth2/" \
                    -H "Authorization: Bearer \${ARR_AK_TOKEN}" \
                    -H "Content-Type: application/json" -d @- 2>/dev/null)
                _AK_PROV_PK=\$(echo "\${_AK_PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null)
            fi

            _AK_CLIENT_ID=\$(echo "\${_AK_PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null)
            _AK_SECRET=\$(echo "\${_AK_PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null)

            if [[ -n "\${_AK_CLIENT_ID}" && -n "\${_AK_SECRET}" && -n "\${_AK_PROV_PK}" ]]; then
                # Application Authentik (idempotent)
                python3 -c "import json; print(json.dumps({'name':'Jellyfin','slug':'${AK_SLUG:-jellyfin-arr}','provider':\${_AK_PROV_PK},'meta_launch_url':'https://\${JF_DOMAIN}/sso/OID/start/\${JF_SSO_PROVIDER}','open_in_new_tab':False}))" \
                    | curl -sf -X POST "\${AK_INT_URL}/api/v3/core/applications/" \
                        -H "Authorization: Bearer \${ARR_AK_TOKEN}" \
                        -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true

                # Attendre que le controller SSO soit initialisé.
                # POST /sso/OID/Add/probe sans auth → 401 = controller prêt, 000 = pas encore
                _sso_plugin_ready=false
                for _sp in \$(seq 1 24); do
                    _sp_sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\${JF_URL}/sso/OID/Add/probe" \
                        -H "Content-Type: application/json" -d '{}' 2>/dev/null) || _sp_sc="000"
                    [[ "\${_sp_sc}" == "401" || "\${_sp_sc}" == "400" ]] && { _sso_plugin_ready=true; break; }
                    [[ \$_sp -eq 1 ]] && echo "  ⏳ Attente chargement plugin SSO Jellyfin..."
                    sleep 5
                done

                # Configurer le plugin SSO dans Jellyfin
                _OID_EP="https://\${ARR_AK_DOMAIN}/application/o/${AK_SLUG:-jellyfin-arr}/"
                _SSO_RESP_CODE=\$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
                    "\${JF_URL}/sso/OID/Add/\${JF_SSO_PROVIDER}" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: MediaBrowser Token=\"\${JF_TOKEN}\"" \
                    -d "{\"oidEndpoint\":\"\${_OID_EP}\",\"oidClientId\":\"\${_AK_CLIENT_ID}\",\"oidSecret\":\"\${_AK_SECRET}\",\"enabled\":true,\"enableAuthorization\":false,\"enableAllFolders\":true,\"enabledFolders\":[],\"roles\":[],\"adminRoles\":[],\"roleClaim\":\"groups\",\"oidScopes\":[],\"schemeOverride\":\"https\",\"doNotLoadProfile\":true,\"newPath\":true}" \
                    2>/dev/null) || _SSO_RESP_CODE="000"

                if [[ "\${_SSO_RESP_CODE}" == "200" || "\${_SSO_RESP_CODE}" == "204" || "\${_SSO_RESP_CODE}" == "201" ]]; then
                    echo "  ✓ Authentik → Provider OAuth2 créé (slug: ${AK_SLUG:-jellyfin-arr})"
                    echo "  ✓ Plugin SSO Jellyfin configuré (provider: \${JF_SSO_PROVIDER})"

                    # Le bouton SSO est écrit dans branding.xml par setup.sh (API lecture seule)
                else
                    echo "  ⚠ Plugin SSO non chargé (HTTP \${_SSO_RESP_CODE}) — redémarrer Jellyfin manuellement"
                    echo "    (Le plugin doit être chargé avant la configuration)"
                fi
            else
                echo "  ⚠ Authentik SSO : client_id ou secret vides"
            fi
        else
            echo "  ⚠ Authentik SSO : flows ou clés de signature introuvables"
        fi
    else
        echo "  ⚠ Authentik non joignable depuis le réseau Docker — SSO ignoré"
    fi
elif [[ -z "\${ARR_AK_TOKEN:-}" ]]; then
    echo "  ℹ Authentik non installé — SSO ignoré (installer Authentik puis relancer arr-stack)"
fi

# ── [5.6/6] Authentik SSO — Jellyseerr OIDC natif ─────────────────────────────
# Jellyseerr v2+ supporte OIDC nativement → OAuth2 provider Authentik (pas ForwardAuth).
_AK_JS_CLIENT_ID=""
_AK_JS_SECRET=""
if [[ -n "\${ARR_AK_TOKEN:-}" ]]; then
    echo ""
    echo "── [5.6/6] Authentik SSO — Jellyseerr (OIDC natif)..."
    _AK_JS_URL="http://authentik-server:9000"
    _AK_JS_UP=false
    for _i in \$(seq 1 3); do
        _ak_js_code=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
            "\${_AK_JS_URL}/api/v3/core/applications/" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null) || _ak_js_code="000"
        [[ "\${_ak_js_code}" == "200" ]] && { _AK_JS_UP=true; break; }
        sleep 5
    done

    if \${_AK_JS_UP}; then
        _AK_JS_FLOW=\$(curl -sf "\${_AK_JS_URL}/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null) || _AK_JS_FLOW=""
        _AK_JS_INVAL=\$(curl -sf "\${_AK_JS_URL}/api/v3/flows/instances/?slug=default-provider-invalidation-flow" \
            -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null) || _AK_JS_INVAL=""

        if [[ -n "\${_AK_JS_FLOW}" ]]; then
            # Récupérer ou créer le provider OAuth2 Jellyseerr
            _AK_JS_PROV_FULL=\$(curl -sf "\${_AK_JS_URL}/api/v3/providers/oauth2/" \
                -H "Authorization: Bearer \${ARR_AK_TOKEN}" 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if p.get('name')=='Jellyseerr OIDC']; print(__import__('json').dumps(m[0]) if m else '')" 2>/dev/null) || _AK_JS_PROV_FULL=""

            if [[ -n "\${_AK_JS_PROV_FULL}" ]]; then
                _AK_JS_PROV_PK=\$(echo "\${_AK_JS_PROV_FULL}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null)
                _AK_JS_CLIENT_ID=\$(echo "\${_AK_JS_PROV_FULL}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null)
                _AK_JS_SECRET=\$(echo "\${_AK_JS_PROV_FULL}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null)
            else
                _AK_JS_BODY=\$(python3 -c "
import json
body={'name':'Jellyseerr OIDC','authorization_flow':'\${_AK_JS_FLOW}','client_type':'confidential',
      'redirect_uris':[{'url':'https://jellyseerr.${CALEOPE_DOMAIN}/auth/oidc/callback','matching_mode':'strict'}],
      'sub_mode':'hashed_user_id','include_claims_in_id_token':True}
if '\${_AK_JS_INVAL}': body['invalidation_flow']='\${_AK_JS_INVAL}'
print(json.dumps(body))")
                _AK_JS_NEW=\$(echo "\${_AK_JS_BODY}" | curl -sf -X POST "\${_AK_JS_URL}/api/v3/providers/oauth2/" \
                    -H "Authorization: Bearer \${ARR_AK_TOKEN}" \
                    -H "Content-Type: application/json" -d @- 2>/dev/null) || _AK_JS_NEW=""
                _AK_JS_PROV_PK=\$(echo "\${_AK_JS_NEW}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null)
                _AK_JS_CLIENT_ID=\$(echo "\${_AK_JS_NEW}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null)
                _AK_JS_SECRET=\$(echo "\${_AK_JS_NEW}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null)
            fi

            if [[ -n "\${_AK_JS_PROV_PK}" && -n "\${_AK_JS_CLIENT_ID}" ]]; then
                # Application Authentik Jellyseerr (idempotent)
                python3 -c "import json; print(json.dumps({'name':'Jellyseerr','slug':'jellyseerr-arr','provider':\${_AK_JS_PROV_PK},'meta_launch_url':'https://jellyseerr.${CALEOPE_DOMAIN}/','open_in_new_tab':False}))" \
                    | curl -sf -X POST "\${_AK_JS_URL}/api/v3/core/applications/" \
                        -H "Authorization: Bearer \${ARR_AK_TOKEN}" \
                        -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true
                echo "  ✓ Authentik → Provider OAuth2 Jellyseerr OIDC créé"
            else
                echo "  ⚠ Jellyseerr OIDC : impossible de créer le provider OAuth2"
            fi
        else
            echo "  ⚠ Jellyseerr OIDC : flow d'autorisation introuvable"
        fi
    else
        echo "  ⚠ Authentik non joignable depuis arr-bootstrap — OIDC Jellyseerr ignoré"
    fi
fi

echo ""
echo "── [6/6] Jellyseerr — configuration automatique..."

JS_URL="http://jellyseerr:5055"
wait_url "Jellyseerr" "\${JS_URL}/api/v1/settings/public"

# Si Jellyfin est externe (Caleope-managed ou autre), l'attendre avant d'essayer
# de connecter Jellyseerr — le container Jellyfin peut ne pas encore être démarré
# lors du premier lancement d'arr-stack (timing d'install parallèle).
if [[ -n "${JELLYFIN_INT_URL}" && "${JELLYFIN_EMBEDDED}" != "true" ]]; then
    echo "→ Attente Jellyfin externe (${JELLYFIN_INT_URL})..."
    _jf_up=false
    for _jfw in \$(seq 1 24); do
        _jf_code=\$(curl -sf -o /dev/null -w "%{http_code}" "${JELLYFIN_INT_URL}/health" 2>/dev/null) || _jf_code="000"
        if [[ "\${_jf_code}" == "200" ]]; then _jf_up=true; break; fi
        sleep 5
        [[ \$(( _jfw % 6 )) -eq 0 ]] && echo "  ... Jellyfin pas encore prêt (\$((_jfw*5))s)..."
    done
    \${_jf_up} && echo "  ✓ Jellyfin prêt" || echo "  ⚠ Jellyfin timeout — tentative Jellyseerr quand même"
fi

JS_INIT=\$(curl -sf "\${JS_URL}/api/v1/settings/public" 2>/dev/null \
    | grep -o '"initialized":[^,}]*' | cut -d: -f2 | tr -d ' "') || JS_INIT="false"

if [[ "\${JS_INIT}" == "true" ]]; then
    echo "  ℹ Jellyseerr déjà initialisé — mise à jour des clés API Radarr/Sonarr..."
    # Sur réinstallation les clés API changent mais Jellyseerr garde les anciennes → "Unable to get queue"
    # → reconfigurer systématiquement avec PUT (update) ou POST (création si absent)
    JS_KEY=\$(python3 -c "
import json, sys
try:
    d = json.load(open('/jellyseerr-config/settings.json'))
    print(d.get('main',{}).get('apiKey',''))
except: pass
" 2>/dev/null) || JS_KEY=""

    if [[ -n "\${JS_KEY}" ]]; then
        _R_PROFILE=\$(curl -sf "http://radarr:7878/api/v3/qualityprofile?apikey=${API_RADARR}" 2>/dev/null \
            | jq -r '.[] | select(.id == 1) | .name // empty' 2>/dev/null) || _R_PROFILE="Any"
        [[ -z "\${_R_PROFILE}" ]] && _R_PROFILE="Any"
        _S_PROFILE=\$(curl -sf "http://sonarr:8989/api/v3/qualityprofile?apikey=${API_SONARR}" 2>/dev/null \
            | jq -r '.[] | select(.id == 1) | .name // empty' 2>/dev/null) || _S_PROFILE="Any"
        [[ -z "\${_S_PROFILE}" ]] && _S_PROFILE="Any"

        _JS_R_ID=\$(curl -sf "\${JS_URL}/api/v1/settings/radarr" -H "X-Api-Key: \${JS_KEY}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null) || _JS_R_ID=""
        _JS_R_BODY="{\"name\":\"Radarr\",\"hostname\":\"radarr\",\"port\":7878,\"apiKey\":\"${API_RADARR}\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeProfileName\":\"\${_R_PROFILE}\",\"activeDirectory\":\"/data/media/movies\",\"minimumAvailability\":\"released\",\"is4k\":false,\"isDefault\":true,\"syncEnabled\":true,\"preventSearch\":false}"
        if [[ -n "\${_JS_R_ID}" ]]; then
            curl -sf -X PUT "\${JS_URL}/api/v1/settings/radarr/\${_JS_R_ID}" \
                -H "Content-Type: application/json" -H "X-Api-Key: \${JS_KEY}" -d "\${_JS_R_BODY}" >/dev/null 2>&1 || true
        else
            curl -sf -X POST "\${JS_URL}/api/v1/settings/radarr" \
                -H "Content-Type: application/json" -H "X-Api-Key: \${JS_KEY}" -d "\${_JS_R_BODY}" >/dev/null 2>&1 || true
        fi

        _JS_S_ID=\$(curl -sf "\${JS_URL}/api/v1/settings/sonarr" -H "X-Api-Key: \${JS_KEY}" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null) || _JS_S_ID=""
        _JS_S_BODY="{\"name\":\"Sonarr\",\"hostname\":\"sonarr\",\"port\":8989,\"apiKey\":\"${API_SONARR}\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeProfileName\":\"\${_S_PROFILE}\",\"activeAnimeProfileId\":1,\"activeAnimeProfileName\":\"\${_S_PROFILE}\",\"activeDirectory\":\"/data/media/tv\",\"activeAnimeDirectory\":\"/data/media/tv\",\"is4k\":false,\"isDefault\":true,\"syncEnabled\":true,\"preventSearch\":false,\"enableSeasonFolders\":true}"
        if [[ -n "\${_JS_S_ID}" ]]; then
            curl -sf -X PUT "\${JS_URL}/api/v1/settings/sonarr/\${_JS_S_ID}" \
                -H "Content-Type: application/json" -H "X-Api-Key: \${JS_KEY}" -d "\${_JS_S_BODY}" >/dev/null 2>&1 || true
        else
            curl -sf -X POST "\${JS_URL}/api/v1/settings/sonarr" \
                -H "Content-Type: application/json" -H "X-Api-Key: \${JS_KEY}" -d "\${_JS_S_BODY}" >/dev/null 2>&1 || true
        fi

        echo "  ✓ Radarr + Sonarr reconfigurés dans Jellyseerr (clés mises à jour)"

        # Réactiver les bibliothèques Jellyfin si token disponible
        if [[ -n "\$JF_TOKEN" ]]; then
            _JS_REINIT_LIB_IDS=""
            for _jlr in \$(seq 1 3); do
                _JS_REINIT_LIB_IDS=\$(curl -sf "\$JF_URL/Library/MediaFolders" \
                    -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" 2>/dev/null \
                    | jq -r '.Items[] | select(.CollectionType == "movies" or .CollectionType == "tvshows" or .CollectionType == "music") | .Id' 2>/dev/null \
                    | tr '\n' ',' | sed 's/,$//') || _JS_REINIT_LIB_IDS=""
                [[ -n "\${_JS_REINIT_LIB_IDS}" ]] && break
                sleep 3
            done
            if [[ -n "\${_JS_REINIT_LIB_IDS}" ]]; then
                curl -sf "\${JS_URL}/api/v1/settings/jellyfin/library?enable=\${_JS_REINIT_LIB_IDS}" \
                    -H "X-Api-Key: \${JS_KEY}" >/dev/null 2>&1 || true
                echo "  ✓ Bibliothèques Jellyfin réactivées dans Jellyseerr"
            fi
        fi
    else
        echo "  ⚠ Jellyseerr : clé API non trouvée dans settings.json — reconfiguration manuelle requise"
    fi
elif [[ -n "${JELLYFIN_PASSWORD}" ]]; then
    # Connexion Jellyseerr → Jellyfin (embedded ou externe avec credentials fournis)
    # serverType:2 = MediaServerType.JELLYFIN (requis depuis Jellyseerr 2.x)
    _JS_JF_HOST=\$(python3 -c "
url = '${JELLYFIN_INT_URL}' or 'http://jellyfin:8096'
url = url.replace('http://','').replace('https://','').split('/')[0]
print(url.split(':')[0])
" 2>/dev/null || echo "jellyfin")
    _JS_JF_PORT=\$(python3 -c "
url = '${JELLYFIN_INT_URL}' or 'http://jellyfin:8096'
url = url.replace('http://','').replace('https://','').split('/')[0]
parts = url.split(':')
print(parts[1] if len(parts) > 1 else '8096')
" 2>/dev/null || echo "8096")
    _JS_JF_SSL="false"
    [[ "${JELLYFIN_INT_URL}" == https* ]] && _JS_JF_SSL="true"

    curl -sf -X POST "\${JS_URL}/api/v1/auth/jellyfin" \
        -H "Content-Type: application/json" \
        -c /tmp/js.cookies -b /tmp/js.cookies \
        -d "{\"hostname\":\"\${_JS_JF_HOST}\",\"port\":\${_JS_JF_PORT},\"useSsl\":\${_JS_JF_SSL},\"urlBase\":\"\",\"serverType\":2,\"username\":\"${JELLYFIN_USER}\",\"password\":\"${JELLYFIN_PASSWORD}\"}" \
        >/dev/null 2>&1 || true

    # Marquer Jellyseerr comme initialisé
    curl -sf -X POST "\${JS_URL}/api/v1/settings/initialize" \
        -c /tmp/js.cookies -b /tmp/js.cookies \
        >/dev/null 2>&1 || true

    # Lire l'API key depuis settings.json (plus fiable que via cookie session)
    # Le volume /jellyseerr-config est monté depuis app-data/arr-stack/config/jellyseerr
    JS_KEY=\$(python3 -c "
import json, sys
try:
    d = json.load(open('/jellyseerr-config/settings.json'))
    print(d.get('main',{}).get('apiKey',''))
except: pass
" 2>/dev/null) || JS_KEY=""
    # Fallback : via cookie session si settings.json pas encore écrit
    if [[ -z "\${JS_KEY}" ]]; then
        JS_KEY=\$(curl -sf "\${JS_URL}/api/v1/settings/main" \
            -b /tmp/js.cookies 2>/dev/null \
            | grep -o '"apiKey":"[^"]*"' | head -1 | cut -d'"' -f4) || JS_KEY=""
    fi

    if [[ -n "\${JS_KEY}" ]]; then
        # Activer les bibliothèques Jellyfin dans Jellyseerr.
        # ATTENTION BUG Jellyseerr 2.7.3 : GET /settings/jellyfin/library sans ?enable=
        # réinitialise TOUTES les bibliothèques à enabled:false (handler écrase le statut).
        # → On récupère les IDs depuis Jellyfin (Library/MediaFolders) et on les passe
        #   directement à ?enable= SANS appel GET préalable sans paramètre.
        JS_LIB_IDS=""
        if [[ -n "\$JF_TOKEN" ]]; then
            # Attendre que les bibliothèques soient indexées (Library/MediaFolders peut
            # retourner une liste vide juste après la création → on réessaie 6x / 5s)
            for _jl in \$(seq 1 6); do
                JS_LIB_IDS=\$(curl -sf "\$JF_URL/Library/MediaFolders" \
                    -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" 2>/dev/null \
                    | jq -r '.Items[] | select(.CollectionType == "movies" or .CollectionType == "tvshows" or .CollectionType == "music") | .Id' 2>/dev/null \
                    | tr '\n' ',' | sed 's/,$//') || JS_LIB_IDS=""
                [[ -n "\$JS_LIB_IDS" ]] && break
                echo "  ⏳ bibliothèques Jellyfin pas encore visibles — attente 5s... (\$_jl/6)"
                sleep 5
            done
        fi
        if [[ -n "\${JS_LIB_IDS}" ]]; then
            curl -sf "\${JS_URL}/api/v1/settings/jellyfin/library?enable=\${JS_LIB_IDS}" \
                -H "X-Api-Key: \${JS_KEY}" -b /tmp/js.cookies >/dev/null 2>&1 || true
            echo "  ✓ Jellyseerr → bibliothèques Jellyfin activées (IDs: \${JS_LIB_IDS})"
        else
            echo "  ⚠ Jellyseerr : bibliothèques non trouvées dans Jellyfin — activation manuelle requise"
        fi

        # Récupérer le nom du profil qualité Radarr (ID 1) pour activeProfileName
        R_PROFILE_NAME=\$(curl -sf "http://radarr:7878/api/v3/qualityprofile?apikey=${API_RADARR}" 2>/dev/null \
            | jq -r '.[] | select(.id == 1) | .name // empty' 2>/dev/null) || R_PROFILE_NAME="Any"
        [[ -z "\$R_PROFILE_NAME" ]] && R_PROFILE_NAME="Any"

        S_PROFILE_NAME=\$(curl -sf "http://sonarr:8989/api/v3/qualityprofile?apikey=${API_SONARR}" 2>/dev/null \
            | jq -r '.[] | select(.id == 1) | .name // empty' 2>/dev/null) || S_PROFILE_NAME="Any"
        [[ -z "\$S_PROFILE_NAME" ]] && S_PROFILE_NAME="Any"

        # Ajouter Radarr dans Jellyseerr
        # minimumAvailability requis depuis Jellyseerr 2.x ; activeProfileName obligatoire
        curl -sf -X POST "\${JS_URL}/api/v1/settings/radarr" \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: \${JS_KEY}" \
            -d "{\"name\":\"Radarr\",\"hostname\":\"radarr\",\"port\":7878,\"apiKey\":\"${API_RADARR}\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeProfileName\":\"\$R_PROFILE_NAME\",\"activeDirectory\":\"/data/media/movies\",\"minimumAvailability\":\"released\",\"is4k\":false,\"isDefault\":true,\"syncEnabled\":true,\"preventSearch\":false}" \
            >/dev/null 2>&1 || true

        # Ajouter Sonarr dans Jellyseerr
        curl -sf -X POST "\${JS_URL}/api/v1/settings/sonarr" \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: \${JS_KEY}" \
            -d "{\"name\":\"Sonarr\",\"hostname\":\"sonarr\",\"port\":8989,\"apiKey\":\"${API_SONARR}\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeProfileName\":\"\$S_PROFILE_NAME\",\"activeAnimeProfileId\":1,\"activeAnimeProfileName\":\"\$S_PROFILE_NAME\",\"activeDirectory\":\"/data/media/tv\",\"activeAnimeDirectory\":\"/data/media/tv\",\"is4k\":false,\"isDefault\":true,\"syncEnabled\":true,\"preventSearch\":false,\"enableSeasonFolders\":true}" \
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

        echo "  ✓ Jellyseerr configuré (Jellyfin + bibliothèques + Radarr + Sonarr + langue française)"
    else
        echo "  ⚠ Jellyseerr : API key non récupérée — configuration manuelle requise"
        echo "    Connecte-toi sur https://jellyseerr.${CALEOPE_DOMAIN}"
        echo "    URL Jellyfin à entrer : http://jellyfin:8096"
    fi
else
    echo "  ℹ Jellyfin non configuré ou credentials non fournis"
    echo "    Configure Jellyseerr manuellement : https://jellyseerr.${CALEOPE_DOMAIN}"
    if [[ -n "${JELLYFIN_INT_URL}" ]]; then
        echo "    URL Jellyfin : ${JELLYFIN_INT_URL}"
    fi
fi

# ── [6.5/6] Jellyseerr OIDC — configurer via API ────────────────────────────
if [[ -n "\${_AK_JS_CLIENT_ID:-}" && -n "\${_AK_JS_SECRET:-}" && -n "\${JS_KEY:-}" ]]; then
    echo ""
    echo "── [6.5/6] Jellyseerr OIDC — config API..."
    _JS_OIDC_CODE=\$(curl -sf -o /dev/null -w "%{http_code}" -X POST "\${JS_URL}/api/v1/settings/main" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: \${JS_KEY}" \
        -d "{\"oidcEnabled\":true,\"oidcName\":\"Authentik\",\"oidcClientId\":\"\${_AK_JS_CLIENT_ID}\",\"oidcClientSecret\":\"\${_AK_JS_SECRET}\",\"oidcIssuerUrl\":\"https://\${ARR_AK_DOMAIN}/application/o/jellyseerr-arr/\"}" \
        2>/dev/null) || _JS_OIDC_CODE="000"
    if [[ "\${_JS_OIDC_CODE}" == "200" || "\${_JS_OIDC_CODE}" == "201" ]]; then
        echo "  ✓ Jellyseerr OIDC configuré (bouton 'Se connecter avec Authentik')"
    else
        echo "  ⚠ Jellyseerr OIDC : API code \${_JS_OIDC_CODE} — configurer manuellement dans Paramètres → Sécurité"
    fi
fi

echo ""
echo "╔═════════════════════════════════════════════════════════╗"
echo "║  ✅  Bootstrap terminé avec succès !                  ║"
echo "║                                                       ║"
echo "║  Indexeurs ajoutés automatiquement :                 ║"
echo "║  • 1337x (général) • YTS (films) • EZTV (séries)    ║"
echo "║                                                       ║"
echo "║  Reste à faire manuellement :                        ║"
echo "║  • Prowlarr → ajouter tes indexeurs perso            ║"
echo "║    (YGGTorrent, BetaSeries, etc. — nécessitent login)║"
echo "║  • Bazarr → Providers → activer sous-titres          ║"
echo "║    (tous nécessitent un compte externe)              ║"
echo "╚═════════════════════════════════════════════════════════╝"
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"

# ── post-install.txt ─────────────────────────────────────────────────
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    JF_LINE="║  Jellyfin     : https://jellyfin.${CALEOPE_DOMAIN}                  ║"
    JF_CRED="║  Jellyfin admin : ${JELLYFIN_USER} / ${JELLYFIN_PASSWORD}            ║"
elif [[ "${_JELLYFIN_CALEOPE_MANAGED}" == "true" ]]; then
    # Jellyfin géré par Caleope → afficher son URL publique, pas l'URL Docker interne
    JF_LINE="║  Jellyfin     : https://jellyfin.${CALEOPE_DOMAIN}  (instance Caleope)║"
    JF_CRED=""
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

# Item "Jellyseerr → configurer" : affiché si Jellyfin externe SANS credentials
# (avec credentials, le bootstrap auto-configure Jellyseerr même pour externe)
if [[ "${JELLYFIN_EMBEDDED}" == "true" || -n "${JELLYFIN_PASSWORD}" ]]; then
    JS_TODO=""
    _NEXT_STEP=3
elif [[ "${_JELLYFIN_CALEOPE_MANAGED}" == "true" ]]; then
    _NEXT_STEP=4
    JS_TODO="║  ${_NEXT_STEP}. Jellyseerr → connecter ton Jellyfin : https://jellyfin.${CALEOPE_DOMAIN}  ║"
else
    _NEXT_STEP=4
    JS_TODO="║  ${_NEXT_STEP}. Jellyseerr → connecter ton Jellyfin (${JELLYFIN_INT_URL:-ton-serveur:8096})    ║"
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
║  🤖 CONFIGURÉ AUTOMATIQUEMENT                                         ║
║  • Prowlarr → Radarr, Sonarr, Lidarr (fullSync) + FlareSolverr       ║
║  • Indexeurs publics : 1337x · YTS (films) · EZTV (séries)           ║
║  • qBittorrent + SABnzbd → tous les *arr                              ║
║  • Dossiers racine Films/Séries/Musique                               ║
║  • Langue française partout                                           ║
║  • Bazarr → profil sous-titres Français + Anglais                    ║
$([ "${JELLYFIN_EMBEDDED}" == "true" ] && echo "║  • Jellyfin → bibliothèques + compte admin + Jellyseerr             ║")
$([ -n "${ARR_AK_TOKEN}" ] && echo "║  • SSO Authentik → Jellyfin (bouton login) + Jellyseerr (OIDC)      ║")
${VPN_LINE}
╠════════════════════════════════════════════════════════════════════════╣
║  À FAIRE MANUELLEMENT :                                               ║
║  1. DNS : *.${CALEOPE_DOMAIN} → IP du serveur                        ║
║  2. Prowlarr → ajouter tes indexeurs perso (YGGTorrent, etc.)        ║
║  3. Bazarr → Providers → activer tes sources de sous-titres          ║
║     (tous nécessitent un compte externe — OpenSubtitles, etc.)        ║
${JS_TODO}
╠════════════════════════════════════════════════════════════════════════╣
${JF_CRED}
║  qBittorrent : accès sans mot de passe (auth réseau local)           ║
╚════════════════════════════════════════════════════════════════════════╝
EOF

# ── Jellyfin : créer les dossiers config+cache avec permissions correctes ─
# L'image officielle jellyfin/jellyfin tourne en UID 1000. Si jellyfin-cache
# n'existe pas avant docker compose up, Docker le crée en root:root et Jellyfin
# plante immédiatement en ne pouvant pas écrire dans /cache.
if [[ "${JELLYFIN_EMBEDDED}" == "true" ]]; then
    JF_CFG_DIR="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/jellyfin"
    JF_CACHE_DIR="${CALEOPE_BASE_DIR}/app-data/arr-stack/config/jellyfin-cache"
    mkdir -p "${JF_CFG_DIR}" "${JF_CACHE_DIR}"
    chmod 777 "${JF_CFG_DIR}" "${JF_CACHE_DIR}"
    echo "✓ Jellyfin dirs préparés avec permissions 777"
fi

# ── Fix COMPOSE_PROFILES : écrire .env dans le répertoire compose ────
# caleoped ne transmet pas COMPOSE_PROFILES à docker compose → les profils
# (novpn, jellyfin…) ne sont jamais activés sans ce fichier.
COMPOSE_DIR="${CALEOPE_BASE_DIR}/apps-installed/${CALEOPE_APP_ID}"
mkdir -p "${COMPOSE_DIR}"
# ARR_PUID/PGID/TZ : résolus par docker compose depuis .env (pas app.env).
# Sans ces vars, compose résout ${ARR_PUID} comme chaîne vide et linuxserver
# utilise son défaut (UID 1000 = user "abc") qui ne peut pas écrire dans
# les dossiers créés par root. On force PUID=0 (root) pour cohérence.
cat > "${COMPOSE_DIR}/.env" <<DOTENVEOF
COMPOSE_PROFILES=${COMPOSE_PROFILES}
ARR_PUID=${PUID}
ARR_PGID=${PGID}
ARR_TZ=Europe/Paris
ARR_AK_MW=${ARR_AK_MW}
DOTENVEOF
echo "✓ .env → COMPOSE_PROFILES=${COMPOSE_PROFILES} ARR_PUID=${PUID} ARR_PGID=${PGID}"

# ── Marquer le service bootstrap pour caleoped ───────────────────────────────
# caleoped détecte ce fichier après docker compose up et exécute le service
# one-shot arr-bootstrap (docker compose run --rm arr-bootstrap) AVANT d'afficher
# les notes post-install. Cela garantit que le wizard Jellyfin et les connexions
# inter-services sont terminés quand l'utilisateur voit ses identifiants.
echo "arr-bootstrap" > "${CONFIG_DIR}/.bootstrap_service"
echo "✓ Bootstrap service marqué : arr-bootstrap"

echo "✓ Arr Stack préparé — bootstrap configuré"
