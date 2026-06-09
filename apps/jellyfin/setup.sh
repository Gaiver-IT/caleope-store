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

# ── Plugin SSO Jellyfin (pour intégration Authentik OIDC) ────────────
SSO_PLUGIN_DIR="${JF_CFG}/plugins/SSO-Auth_4.0.0.4.0"
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

# ── Token Authentik (pour SSO OIDC dans le bootstrap) ────────────────
AK_TOKEN=""
AK_DOMAIN="authentik.${CALEOPE_DOMAIN}"
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    _AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${_AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${_AK_SECRETS}" | cut -d= -f2-)
        _AK_D=$(grep "^AUTHENTIK_DOMAIN=" "${_AK_SECRETS}" | cut -d= -f2-)
        [ -n "${_AK_D}" ] && AK_DOMAIN="${_AK_D}"
        [ -n "${AK_TOKEN}" ] && echo "  → Authentik détecté — SSO OIDC sera configuré"
    fi
fi

# ── Bootstrap script ─────────────────────────────────────────────────
# Ce script tourne dans un container Alpine au 1er démarrage.
# Il complète le wizard Jellyfin via l'API /Startup/* (10.11+)
# et configure le SSO OIDC Authentik si disponible.
cat > "${CONFIG_DIR}/bootstrap.sh" <<BOOTSTRAP
#!/bin/bash
exec > /dev/stdout 2>&1

JF_URL="http://jellyfin:8096"
# Interpolés par setup.sh (connus au moment de l'install)
AK_TOKEN="${AK_TOKEN}"
AK_DOMAIN="${AK_DOMAIN}"
AK_INT_URL="http://authentik-server:9000"
AK_SLUG="jellyfin"
JF_SSO_PROVIDER="Authentik"
JF_DOMAIN="${CALEOPE_DOMAIN}"

wait_url() {
    local name=\$1 url=\$2 tries=0
    echo "→ Attente \${name}..."
    until curl -sf --connect-timeout 5 --max-time 10 -o /dev/null "\${url}" 2>/dev/null; do
        sleep 5; tries=\$((tries+1))
        [[ \$tries -ge 72 ]] && { echo "  ⚠ Timeout \${name} (6 min) — on continue"; return 0; }
        [[ \$((tries%6)) -eq 0 ]] && echo "  ... \${name} pas encore prêt (\$((tries*5))s)..."
    done
    echo "  ✓ \${name} prêt"
}

echo "╔══════════════════════════════════════════╗"
echo "║  Jellyfin — Bootstrap automatique        ║"
echo "╚══════════════════════════════════════════╝"

wait_url "Jellyfin" "\${JF_URL}/health"

# Vérifier état wizard
echo "→ Vérification état wizard..."
JF_WIZARD_STATUS="000"
for _i in \$(seq 1 24); do
    JF_WIZARD_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" "\${JF_URL}/Startup/Configuration" 2>/dev/null) || JF_WIZARD_STATUS="000"
    [[ "\${JF_WIZARD_STATUS}" != "503" && "\${JF_WIZARD_STATUS}" != "000" ]] && break
    echo "  ⏳ Wizard pas encore prêt (HTTP \${JF_WIZARD_STATUS}) — attente 10s... (\${_i}/24)"
    sleep 10
done

JF_WIZARD_DONE=false
if [[ "\${JF_WIZARD_STATUS}" == "404" || "\${JF_WIZARD_STATUS}" == "401" ]]; then
    echo "  ℹ Wizard déjà complété"
    JF_WIZARD_DONE=true
else
    echo "→ Configuration automatique du wizard Jellyfin..."

    _cfg_sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\${JF_URL}/Startup/Configuration" \
        -H "Content-Type: application/json" \
        -d '{"ServerName":"Caleope","UICulture":"fr-FR","MetadataCountryCode":"FR","PreferredMetadataLanguage":"fr"}' \
        2>/dev/null) || _cfg_sc="000"
    echo "  → POST /Startup/Configuration → HTTP \${_cfg_sc}"

    echo "  → Attente disponibilité étape User..."
    _user_ep_ok=false
    for _w in \$(seq 1 30); do
        _user_get=\$(curl -s -o /dev/null -w "%{http_code}" "\${JF_URL}/Startup/User" 2>/dev/null) || _user_get="000"
        [[ "\${_user_get}" == "200" ]] && { _user_ep_ok=true; break; }
        sleep 3
    done
    \${_user_ep_ok} || echo "  ⚠ Timeout attente étape User — tentative quand même"

    _jf_ok=false
    for _r in \$(seq 1 10); do
        _sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\${JF_URL}/Startup/User" \
            -H "Content-Type: application/json" \
            -d '{"Name":"${JELLYFIN_USER}","Password":"${JELLYFIN_PASSWORD}"}' 2>/dev/null) || _sc="000"
        [[ "\${_sc}" == "204" || "\${_sc}" == "200" ]] && { _jf_ok=true; break; }
        echo "  ⏳ POST /Startup/User → HTTP \${_sc}, nouvel essai... (\${_r}/10)"
        sleep 3
    done
    \${_jf_ok} && echo "  ✓ Compte admin '${JELLYFIN_USER}' créé" || \
        echo "  ⚠ Création compte échouée (HTTP: \${_sc})"

    curl -sf -X POST "\${JF_URL}/Startup/RemoteAccess" -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null 2>&1 || true
    curl -sf -X POST "\${JF_URL}/Startup/Complete" >/dev/null 2>&1 || true
    echo "  ✓ Wizard complété"
fi

# ── Authentification admin ────────────────────────────────────────────
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

# ── Bibliothèques (seulement sur première install) ────────────────────
if [[ "\${JF_WIZARD_DONE}" == "false" && -n "\$JF_TOKEN" ]]; then
    echo ""
    echo "→ Création des bibliothèques par défaut..."
    add_jf_lib() {
        local name=\$1 type=\$2 path=\$3
        local encoded_name=\$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "\$name" 2>/dev/null || echo "\$name")
        local existing=\$(curl -sf "\${JF_URL}/Library/VirtualFolders" \
            -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(x['Name'] for x in d))" 2>/dev/null) || existing=""
        echo "\$existing" | grep -q "\$name" && { echo "  ℹ Bibliothèque '\$name' déjà présente"; return 0; }
        curl -sf -X POST "\${JF_URL}/Library/VirtualFolders?name=\${encoded_name}&collectionType=\${type}&paths=\${path}&refreshLibrary=false" \
            -H "Content-Type: application/json" \
            -H "Authorization: MediaBrowser Token=\"\$JF_TOKEN\"" \
            -d '{"libraryOptions":{}}' >/dev/null 2>&1 || true
        echo "  ✓ Bibliothèque '\$name' → \$path"
    }
    add_jf_lib "Films"   "movies"  "/arr-media/movies"
    add_jf_lib "Séries"  "tvshows" "/arr-media/tv"
    add_jf_lib "Musique" "music"   "/arr-media/music"
    echo "  ✓ Bibliothèques créées"
elif [[ -z "\$JF_TOKEN" ]]; then
    echo "  ⚠ Auth Jellyfin échouée — bibliothèques à créer manuellement"
fi

# ── SSO OIDC Authentik ────────────────────────────────────────────────
if [[ -n "\${AK_TOKEN}" && -n "\${JF_TOKEN}" ]]; then
    echo ""
    echo "→ Configuration SSO OIDC Authentik..."

    # Vérifier si le provider SSO est déjà configuré (idempotence)
    _sso_exists=\$(curl -sf -o /dev/null -w "%{http_code}" \
        "\${JF_URL}/sso/OID/Get/\${JF_SSO_PROVIDER}?api_key=\${JF_TOKEN}" 2>/dev/null) || _sso_exists="000"

    if [[ "\${_sso_exists}" == "200" ]]; then
        echo "  ℹ SSO Authentik déjà configuré — ignoré"
    else
        # Vérifier si Authentik est joignable
        _ak_up=false
        for _i in \$(seq 1 6); do
            _ak_c=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
                "\${AK_INT_URL}/api/v3/core/applications/" \
                -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null) || _ak_c="000"
            [[ "\${_ak_c}" == "200" ]] && { _ak_up=true; break; }
            [[ \$_i -eq 1 ]] && echo "  ⏳ Attente Authentik..."
            sleep 5
        done

        if \${_ak_up}; then
            _AK_FLOW=\$(curl -sf "\${AK_INT_URL}/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null)
            _AK_INVAL=\$(curl -sf "\${AK_INT_URL}/api/v3/flows/instances/?slug=default-provider-invalidation-flow" \
                -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null)
            _AK_KEY=\$(curl -sf "\${AK_INT_URL}/api/v3/crypto/certificatekeypairs/?has_key=true&ordering=name" \
                -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null)
            _AK_ALL_SCOPES=\$(curl -sf "\${AK_INT_URL}/api/v3/propertymappings/all/?ordering=name&page_size=200" \
                -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null)
            _S_OID=\$(echo "\${_AK_ALL_SCOPES}" | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if 'scope-openid' in str(p.get('managed',''))]; print(m[0]['pk'] if m else '')" 2>/dev/null)
            _S_EMAIL=\$(echo "\${_AK_ALL_SCOPES}" | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if 'scope-email' in str(p.get('managed',''))]; print(m[0]['pk'] if m else '')" 2>/dev/null)
            _S_PROF=\$(echo "\${_AK_ALL_SCOPES}" | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if 'scope-profile' in str(p.get('managed',''))]; print(m[0]['pk'] if m else '')" 2>/dev/null)
            _JF_REDIRECT="\$(python3 -c "import urllib.parse; print(urllib.parse.quote('https://\${JF_DOMAIN}/sso/OID/redirect/\${JF_SSO_PROVIDER}'))" 2>/dev/null || echo "https://\${JF_DOMAIN}/sso/OID/redirect/\${JF_SSO_PROVIDER}")"

            if [[ -n "\${_AK_FLOW}" && -n "\${_AK_KEY}" && -n "\${_S_OID}" ]]; then
                # Provider OAuth2 — créer ou récupérer
                _AK_PROV_PK=\$(curl -sf "\${AK_INT_URL}/api/v3/providers/oauth2/" \
                    -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null \
                    | python3 -c "import sys,json; d=json.load(sys.stdin); m=[p for p in d.get('results',[]) if p.get('name')=='Jellyfin SSO']; print(m[0]['pk'] if m else '')" 2>/dev/null)

                if [[ -n "\${_AK_PROV_PK}" ]]; then
                    _AK_PROV_RESP=\$(curl -sf "\${AK_INT_URL}/api/v3/providers/oauth2/\${_AK_PROV_PK}/" \
                        -H "Authorization: Bearer \${AK_TOKEN}" 2>/dev/null)
                else
                    _AK_PROV_RESP=\$(python3 -c "
import json
scopes=[s for s in ['\${_S_OID}','\${_S_EMAIL}','\${_S_PROF}'] if s]
body={'name':'Jellyfin SSO','authorization_flow':'\${_AK_FLOW}','client_type':'confidential',
      'redirect_uris':[{'url':'https://\${JF_DOMAIN}/sso/OID/redirect/\${JF_SSO_PROVIDER}','matching_mode':'strict'}],
      'sub_mode':'hashed_user_id','include_claims_in_id_token':True,
      'signing_key':'\${_AK_KEY}','property_mappings':scopes}
if '\${_AK_INVAL}': body['invalidation_flow']='\${_AK_INVAL}'
print(json.dumps(body))" | curl -sf -X POST "\${AK_INT_URL}/api/v3/providers/oauth2/" \
                        -H "Authorization: Bearer \${AK_TOKEN}" \
                        -H "Content-Type: application/json" -d @- 2>/dev/null)
                    _AK_PROV_PK=\$(echo "\${_AK_PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null)
                fi

                _AK_CLIENT_ID=\$(echo "\${_AK_PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null)
                _AK_SECRET=\$(echo "\${_AK_PROV_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null)

                if [[ -n "\${_AK_CLIENT_ID}" && -n "\${_AK_SECRET}" && -n "\${_AK_PROV_PK}" ]]; then
                    # Application Authentik
                    python3 -c "import json; print(json.dumps({'name':'Jellyfin','slug':'\${AK_SLUG}','provider':\${_AK_PROV_PK},'meta_launch_url':'https://\${JF_DOMAIN}/sso/OID/start/\${JF_SSO_PROVIDER}','open_in_new_tab':False}))" \
                        | curl -sf -X POST "\${AK_INT_URL}/api/v3/core/applications/" \
                            -H "Authorization: Bearer \${AK_TOKEN}" \
                            -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true

                    # Attendre que le controller SSO soit initialisé.
                    # Jellyfin charge le plugin au démarrage, mais le SSOController
                    # peut prendre ~90s supplémentaires à s'initialiser.
                    # Signal fiable : POST /sso/OID/Add/probe sans auth → 401 (controller prêt)
                    #                 000 = controller pas encore démarré
                    _sso_plugin_ready=false
                    for _sp in \$(seq 1 24); do
                        _sp_sc=\$(curl -s -o /dev/null -w "%{http_code}" -X POST "\${JF_URL}/sso/OID/Add/probe" \
                            -H "Content-Type: application/json" -d '{}' 2>/dev/null) || _sp_sc="000"
                        [[ "\${_sp_sc}" == "401" || "\${_sp_sc}" == "400" ]] && { _sso_plugin_ready=true; break; }
                        [[ \$_sp -eq 1 ]] && echo "  ⏳ Attente chargement plugin SSO Jellyfin..."
                        sleep 5
                    done

                    # Configurer plugin SSO dans Jellyfin
                    _OID_EP="https://\${AK_DOMAIN}/application/o/\${AK_SLUG}/"
                    _SSO_CODE=\$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
                        "\${JF_URL}/sso/OID/Add/\${JF_SSO_PROVIDER}" \
                        -H "Content-Type: application/json" \
                        -H "Authorization: MediaBrowser Token=\"\${JF_TOKEN}\"" \
                        -d "{\"oidEndpoint\":\"\${_OID_EP}\",\"oidClientId\":\"\${_AK_CLIENT_ID}\",\"oidSecret\":\"\${_AK_SECRET}\",\"enabled\":true,\"enableAuthorization\":true,\"enableAllFolders\":true,\"enabledFolders\":[],\"roles\":[],\"adminRoles\":[],\"roleClaim\":\"groups\",\"oidScopes\":[]}" \
                        2>/dev/null) || _SSO_CODE="000"

                    if [[ "\${_SSO_CODE}" == "200" || "\${_SSO_CODE}" == "204" || "\${_SSO_CODE}" == "201" ]]; then
                        echo "  ✓ Provider OAuth2 Authentik créé (slug: \${AK_SLUG})"
                        echo "  ✓ Plugin SSO Jellyfin configuré"

                        # Le bouton SSO est écrit dans branding.xml par setup.sh (API lecture seule)
                    else
                        echo "  ⚠ Plugin SSO non chargé (HTTP \${_SSO_CODE}) — redémarrer Jellyfin"
                    fi
                else
                    echo "  ⚠ Authentik SSO : client_id ou secret vides"
                fi
            else
                echo "  ⚠ Authentik SSO : flows ou clé de signature introuvables"
            fi
        else
            echo "  ⚠ Authentik non joignable — SSO ignoré"
        fi
    fi
elif [[ -z "\${AK_TOKEN}" ]]; then
    echo "  ℹ Authentik non installé — SSO ignoré"
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

# SSO OIDC natif → pas de ForwardAuth Traefik (Jellyfin gère l'auth lui-même via le plugin SSO)
CALEOPE_AUTH_MIDDLEWARE=""

cat > "${CALEOPE_BASE_DIR}/app-config/jellyfin/app.env" <<ENV
CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}
CALEOPE_AK_DOMAIN=${AK_DOMAIN}
ENV
chmod 600 "${CALEOPE_BASE_DIR}/app-config/jellyfin/app.env"

# ── Branding Jellyfin : bouton SSO sur la page de login ───────────────
# Jellyfin 10.11+ lit le LoginDisclaimer depuis config/config/branding.xml
# (l'API /Branding/Configuration est en lecture seule).
if [[ -n "${AK_TOKEN}" ]]; then
    mkdir -p "${JF_CFG}/config"
    SSO_BTN='<a href="/sso/OID/start/Authentik" style="display:block;margin:8px auto;padding:8px 16px;background:#fd4b2d;color:#fff;text-decoration:none;border-radius:4px;text-align:center;font-weight:bold">&#x1F512; Se connecter avec Authentik</a>'
    cat > "${JF_CFG}/config/branding.xml" <<BRANDXML
<?xml version="1.0" encoding="utf-8"?>
<BrandingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LoginDisclaimer>${SSO_BTN}</LoginDisclaimer>
  <SplashscreenEnabled>false</SplashscreenEnabled>
</BrandingOptions>
BRANDXML
    echo "  ✓ Bouton SSO Authentik configuré dans branding.xml"
fi

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
