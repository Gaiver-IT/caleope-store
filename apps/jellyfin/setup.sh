#!/bin/bash
set -euo pipefail
trap 'echo "❌ setup.sh jellyfin : erreur ligne ${LINENO} — ${BASH_COMMAND}" >&2' ERR

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/jellyfin"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/jellyfin"
JF_CFG="${DATA_DIR}/config"
_SECRETS="${CONFIG_DIR}/secrets.env"

echo "→ Préparation de Jellyfin..."
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/"{config,cache,media}

# Pré-créer les répertoires médias arr-stack (montés en :ro dans le compose).
# Si arr-stack n'est pas encore installé, ces dossiers seront vides mais présents.
# Quand arr-stack s'installe, il y dépose Films/Séries/Musique téléchargés.
mkdir -p "${CALEOPE_BASE_DIR}/app-data/arr-stack/data/media/"{movies,tv,music}

# ── Credentials admin ─────────────────────────────────────────────────
# Si un secrets.env existe déjà (réinstall), on conserve les mêmes credentials
# pour ne pas casser les apps qui s'y connectent (arr-stack, Jellyseerr…).
JELLYFIN_USER="admin"
JELLYFIN_PASSWORD=""
if [[ -f "${_SECRETS}" ]]; then
    _PREV_USER=$(grep "^JELLYFIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- | tr -d '"') || _PREV_USER=""
    _PREV_PASS=$(grep "^JELLYFIN_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- | tr -d '"') || _PREV_PASS=""
    [[ -n "${_PREV_USER}" ]] && JELLYFIN_USER="${_PREV_USER}"
    [[ -n "${_PREV_PASS}" ]] && JELLYFIN_PASSWORD="${_PREV_PASS}"
    echo "  ✓ Credentials existants conservés (réinstall)"
fi
[[ -z "${JELLYFIN_PASSWORD}" ]] && \
    JELLYFIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-14)

# Sauvegarder les credentials : lisibles par les autres apps Caleope (arr-stack…)
cat > "${_SECRETS}" <<SECEOF
JELLYFIN_USER=${JELLYFIN_USER}
JELLYFIN_PASSWORD=${JELLYFIN_PASSWORD}
SECEOF
chmod 600 "${_SECRETS}"
echo "  ✓ Credentials sauvegardés dans app-config/jellyfin/secrets.env"
echo "    Compte admin : ${JELLYFIN_USER} / ${JELLYFIN_PASSWORD}"

# ── Nettoyage wizard (réinstall) ─────────────────────────────────────
# Même logique que arr-stack/setup.sh pour le Jellyfin embarqué
if [[ -f "${JF_CFG}/data/jellyfin.db" || -d "${JF_CFG}/root" ]]; then
    echo "→ Nettoyage configuration Jellyfin précédente..."
    docker run --rm -v "${JF_CFG}:/jf" alpine:3.19 \
        sh -c "rm -rf /jf/data /jf/log /jf/root 2>/dev/null; true" \
        >/dev/null 2>&1 || true
    echo "  ✓ Données Jellyfin précédentes supprimées"
fi
if [[ -f "${JF_CFG}/config/system.xml" ]]; then
    docker run --rm -v "${JF_CFG}:/jf" alpine:3.19 \
        sh -c "sed -i 's|<IsStartupWizardCompleted>true</IsStartupWizardCompleted>|<IsStartupWizardCompleted>false</IsStartupWizardCompleted>|' /jf/config/system.xml 2>/dev/null; true" \
        >/dev/null 2>&1 || true
    echo "  ✓ Flag wizard Jellyfin réinitialisé"
fi

# ── Pré-configuration ────────────────────────────────────────────────
mkdir -p "${JF_CFG}/config"
chmod 777 "${DATA_DIR}/config" "${DATA_DIR}/cache"

# network.xml : désactiver HTTPS interne (géré par Traefik)
if [[ ! -f "${JF_CFG}/config/network.xml" ]]; then
    cat > "${JF_CFG}/config/network.xml" <<NETXML
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration>
  <BaseUrl></BaseUrl>
  <EnableHttps>false</EnableHttps>
  <RequireHttps>false</RequireHttps>
  <EnableRemoteAccess>true</EnableRemoteAccess>
</NetworkConfiguration>
NETXML
fi

# ── Bootstrap script ─────────────────────────────────────────────────
# Ce script tourne dans un container Alpine au 1er démarrage.
# Il complète le wizard Jellyfin via l'API /Startup/* (10.11+).
cat > "${CONFIG_DIR}/bootstrap.sh" <<BOOTSTRAP
#!/bin/bash
exec > /dev/stdout 2>&1

JF_URL="http://jellyfin:8096"

wait_url() {
    local name=\$1 url=\$2 tries=0
    echo "→ Attente \${name}..."
    until curl -sf --connect-timeout 5 --max-time 10 -o /dev/null "\${url}" 2>/dev/null; do
        sleep 5; tries=\$((tries+1))
        [[ \$tries -ge 72 ]] && { echo "  ⚠ Timeout Jellyfin (6 min) — on continue"; return 0; }
        [[ \$((tries%6)) -eq 0 ]] && echo "  ... \${name} pas encore prêt (\$((tries*5))s)..."
    done
    echo "  ✓ \${name} prêt"
}

echo "╔══════════════════════════════════════════╗"
echo "║  Jellyfin — Bootstrap automatique        ║"
echo "╚══════════════════════════════════════════╝"

wait_url "Jellyfin" "\${JF_URL}/health"

# Attendre que le wizard soit prêt (peut être en 503 quelques secondes)
echo "→ Vérification état wizard..."
JF_WIZARD_STATUS="000"
for _i in \$(seq 1 24); do
    JF_WIZARD_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" "\${JF_URL}/Startup/Configuration" 2>/dev/null) || JF_WIZARD_STATUS="000"
    [[ "\${JF_WIZARD_STATUS}" != "503" && "\${JF_WIZARD_STATUS}" != "000" ]] && break
    echo "  ⏳ Wizard pas encore prêt (HTTP \${JF_WIZARD_STATUS}) — attente 10s... (\${_i}/24)"
    sleep 10
done

if [[ "\${JF_WIZARD_STATUS}" == "404" ]]; then
    echo "  ℹ Wizard déjà complété — Jellyfin déjà configuré, rien à faire"
    exit 0
fi

echo "→ Configuration automatique du wizard Jellyfin..."

# Étape 1 : Nom serveur + langue
_cfg_sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\${JF_URL}/Startup/Configuration" \
    -H "Content-Type: application/json" \
    -d '{"ServerName":"Caleope","UICulture":"fr-FR","MetadataCountryCode":"FR","PreferredMetadataLanguage":"fr"}' \
    2>/dev/null) || _cfg_sc="000"
echo "  → POST /Startup/Configuration → HTTP \${_cfg_sc}"

# Étape 2 : Attendre que le wizard avance à l'étape User
# Jellyfin 10.11+ : après Configuration (204), l'endpoint /Startup/User peut
# prendre du temps à devenir disponible (retourne 404 tant que le wizard n'a
# pas avancé). On attend un GET 200 avant de POSTer.
echo "  → Attente disponibilité étape User..."
_user_ep_ok=false
for _w in \$(seq 1 30); do
    _user_get=\$(curl -s -o /dev/null -w "%{http_code}" "\${JF_URL}/Startup/User" 2>/dev/null) || _user_get="000"
    if [[ "\${_user_get}" == "200" ]]; then
        _user_ep_ok=true
        break
    fi
    sleep 3
done
\${_user_ep_ok} || echo "  ⚠ Timeout attente étape User — tentative quand même"

# Créer le compte admin
_jf_ok=false
for _r in \$(seq 1 10); do
    _sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\${JF_URL}/Startup/User" \
        -H "Content-Type: application/json" \
        -d '{"Name":"${JELLYFIN_USER}","Password":"${JELLYFIN_PASSWORD}"}' 2>/dev/null) || _sc="000"
    [[ "\${_sc}" == "204" || "\${_sc}" == "200" ]] && { _jf_ok=true; break; }
    echo "  ⏳ POST /Startup/User → HTTP \${_sc}, nouvel essai... (\${_r}/10)"
    sleep 3
done
if \${_jf_ok}; then
    echo "  ✓ Compte admin '${JELLYFIN_USER}' créé"
else
    echo "  ⚠ Création compte échouée (dernier HTTP: \${_sc}) — le wizard devra être complété manuellement"
fi

# Étape 3 : Accès distant
curl -sf -X POST "\${JF_URL}/Startup/RemoteAccess" \
    -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' \
    >/dev/null 2>&1 || true

# Étape 4 : Finalisation wizard
curl -sf -X POST "\${JF_URL}/Startup/Complete" >/dev/null 2>&1 || true
echo "  ✓ Wizard complété"

# ── Création des bibliothèques par défaut ─────────────────────────────
# Après Startup/Complete, on s'authentifie pour créer les bibliothèques.
# Paths : /arr-media/* = app-data/arr-stack/data/media/* (monté en :ro)
#         Ces paths sont ceux qu'arr-stack utilise pour Radarr/Sonarr/Lidarr.
echo ""
echo "→ Création des bibliothèques par défaut..."

# Attendre que Jellyfin recharge après wizard (peut redémarrer en interne)
sleep 5

JF_TOKEN=""
for _auth_try in \$(seq 1 10); do
    JF_AUTH=\$(curl -sf -X POST "\${JF_URL}/Users/AuthenticateByName" \
        -H "Content-Type: application/json" \
        -H 'X-Emby-Authorization: MediaBrowser Client="Bootstrap", Device="Bootstrap", DeviceId="jf-bootstrap-1", Version="1.0.0"' \
        -d '{"Username":"${JELLYFIN_USER}","Pw":"${JELLYFIN_PASSWORD}"}' 2>/dev/null) || JF_AUTH=""
    JF_TOKEN=\$(echo "\$JF_AUTH" | grep -o '"AccessToken":"[^"]*"' | head -1 | cut -d'"' -f4) || JF_TOKEN=""
    [[ -n "\$JF_TOKEN" ]] && break
    sleep 3
done

if [[ -n "\$JF_TOKEN" ]]; then
    add_jf_lib() {
        local name=\$1 type=\$2 path=\$3
        local encoded_name=\$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "\$name" 2>/dev/null || echo "\$name")
        # Idempotence : vérifier si la biblio existe déjà
        local existing=\$(curl -sf "\${JF_URL}/Library/VirtualFolders" \
            -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(x['Name'] for x in d))" 2>/dev/null) || existing=""
        if echo "\$existing" | grep -q "\$name"; then
            echo "  ℹ Bibliothèque '\$name' déjà présente"
            return 0
        fi
        curl -sf -X POST "\${JF_URL}/Library/VirtualFolders?name=\${encoded_name}&collectionType=\${type}&paths=\${path}&refreshLibrary=false" \
            -H "Content-Type: application/json" \
            -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" \
            -d '{"libraryOptions":{}}' >/dev/null 2>&1 || true
        echo "  ✓ Bibliothèque '\$name' → \$path"
    }
    # Bibliothèques pointant sur les répertoires arr-stack (partagés avec Radarr/Sonarr/Lidarr)
    add_jf_lib "Films"   "movies"  "/arr-media/movies"
    add_jf_lib "Séries"  "tvshows" "/arr-media/tv"
    add_jf_lib "Musique" "music"   "/arr-media/music"
    echo "  ✓ Bibliothèques créées (liées à app-data/arr-stack/data/media/)"
else
    echo "  ⚠ Auth Jellyfin échouée — bibliothèques à créer manuellement"
fi

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║  ✅  Jellyfin configuré automatiquement !      ║"
echo "║  Compte admin : ${JELLYFIN_USER} / ${JELLYFIN_PASSWORD}   ║"
echo "╚════════════════════════════════════════════════╝"
BOOTSTRAP
chmod +x "${CONFIG_DIR}/bootstrap.sh"

# Marquer le service bootstrap pour caleoped
echo "jellyfin-bootstrap" > "${CONFIG_DIR}/.bootstrap_service"
echo "  ✓ Bootstrap configuré"

# ── Auto-enregistrement dans Authentik ──────────────────────────────
authentik_register_app() {
    local APP_NAME="$1" APP_SLUG="$2" APP_URL="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 1

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    if [ -z "${AK_DOMAIN}" ]; then
        local BASE_DOMAIN
        BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
        AK_DOMAIN="authentik.${BASE_DOMAIN}"
    fi
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || return 1

    local BASE="https://${AK_DOMAIN}/api/v3"
    local HA="Authorization: Bearer ${TOKEN}"
    local HJ="Content-Type: application/json"

    local i=0
    until curl -sf --max-time 5 -H "${HA}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 12 ] || { echo "  ⚠ Authentik non joignable"; return 1; }
        sleep 5
    done

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || { echo "  ⚠ Flow Authentik introuvable"; return 1; }

    local PROVIDER_PK
    PROVIDER_PK=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/providers/proxy/" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = [p for p in d.get('results',[]) if p['name']==\"${APP_NAME}\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -z "${PROVIDER_PK}" ]; then
        PROVIDER_PK=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
            "${BASE}/providers/proxy/" \
            -d "{\"name\":\"${APP_NAME}\",\"authorization_flow\":\"${FLOW_UUID}\",\"external_host\":\"${APP_URL}\",\"mode\":\"forward_single\"}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "  ⚠ Erreur création Provider"; return 1; }

    curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
        "${BASE}/core/applications/" \
        -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROVIDER_PK}}" \
        >/dev/null 2>&1 || true

    local OUTPOST_UUID CURRENT_PROVIDERS NEW_PROVIDERS
    OUTPOST_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

    if [ -n "${OUTPOST_UUID}" ]; then
        CURRENT_PROVIDERS=$(curl -sf --max-time 10 -H "${HA}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('providers',[])))" 2>/dev/null || echo "[]")
        NEW_PROVIDERS=$(echo "${CURRENT_PROVIDERS}" | python3 -c "
import sys, json
l = json.load(sys.stdin)
if ${PROVIDER_PK} not in l: l.append(${PROVIDER_PK})
print(json.dumps(l))
" 2>/dev/null || echo "[${PROVIDER_PK}]")
        curl -sf --max-time 10 -X PATCH -H "${HA}" -H "${HJ}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            -d "{\"providers\":${NEW_PROVIDERS}}" >/dev/null 2>&1 || true
    fi

    echo "  → ${APP_NAME} enregistré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    if authentik_register_app "Jellyfin" "jellyfin" "https://${CALEOPE_DOMAIN}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    else
        echo "  ⚠ ForwardAuth désactivé (enregistrement Authentik échoué)"
    fi
fi

cat > "${CALEOPE_BASE_DIR}/app-config/jellyfin/app.env" <<ENV
CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}
ENV
chmod 600 "${CALEOPE_BASE_DIR}/app-config/jellyfin/app.env"

# ── post-install.txt ─────────────────────────────────────────────────
cat > "${CONFIG_DIR}/post-install.txt" <<EOF
╔══════════════════════════════════════════════════════════════╗
║               Jellyfin — Accès et credentials               ║
╠══════════════════════════════════════════════════════════════╣
║  Interface : https://${CALEOPE_DOMAIN}                      ║
╠══════════════════════════════════════════════════════════════╣
║  Compte admin    : ${JELLYFIN_USER}                         ║
║  Mot de passe    : ${JELLYFIN_PASSWORD}                     ║
║  (stocké dans app-config/jellyfin/secrets.env)              ║
╠══════════════════════════════════════════════════════════════╣
║  🤖 CONFIGURÉ AUTOMATIQUEMENT                               ║
║  • Wizard de démarrage complété (compte admin créé)         ║
║  • Langue française (métadonnées + interface)               ║
╠══════════════════════════════════════════════════════════════╣
║  À FAIRE :                                                  ║
║  1. Ajouter tes bibliothèques médias dans Paramètres        ║
║  2. Créer des comptes pour tes utilisateurs                 ║
╚══════════════════════════════════════════════════════════════╝
EOF

echo "✓ Jellyfin prêt — démarrage en cours..."
