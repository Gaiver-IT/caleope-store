#!/bin/bash
set -euo pipefail
echo "→ Préparation de GLPI..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/glpi/"{files,plugins,config,marketplace,db}

# Garantit que le fichier cert existe (même vide) — le volume bind-mount dans
# docker-compose est inconditionnel ; Docker crée un répertoire à la place
# d'un fichier absent, ce qui corromprait le montage.
mkdir -p "${CALEOPE_BASE_DIR}/data/traefik/certs"
[ -f "${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt" ] || \
    touch "${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"

# ── Secrets ─────────────────────────────────────────────────────────────────
DB_PASS=$(openssl rand -hex 24)
DB_ROOT_PASS=$(openssl rand -hex 24)
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" | cut -d= -f2)
AUTHENTIK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
[ -n "${AUTHENTIK_DOMAIN}" ] || AUTHENTIK_DOMAIN="authentik.${BASE_DOMAIN}"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# MariaDB
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_PASSWORD=${DB_PASS}

# GLPI → MariaDB
MARIADB_PASSWORD=${DB_PASS}

# Extra hosts Authentik (hairpin NAT → host-gateway)
AUTHENTIK_DOMAIN=${AUTHENTIK_DOMAIN}

# Compte admin local GLPI (conservé même avec SSO activé)
GLPI_ADMIN_USER=glpi
GLPI_ADMIN_PASSWORD=${ADMIN_PASS}

# URL publique de GLPI (utilisée pour url_base dans glpi_configs)
GLPI_URL_BASE=https://${CALEOPE_DOMAIN}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── SSO OIDC via Authentik (même pattern que Nextcloud) ──────────────────────
# Utilise docker exec authentik-server python3 pour éviter le hairpin NAT
# et les problèmes de cert auto-signé lors des appels API depuis le host.
authentik_setup_oidc() {
    local DEBUG_LOG="/tmp/caleope_glpi_sso.log"
    echo "=== $(date) ===" > "${DEBUG_LOG}"

    local APP_NAME="$1" APP_SLUG="$2" REDIRECT_URI="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ ! -f "${AK_SECRETS}" ]; then
        echo "ERREUR: AK_SECRETS introuvable" >> "${DEBUG_LOG}"; return 1
    fi

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    if [ -z "${AK_DOMAIN}" ]; then
        local BD
        BD=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
        AK_DOMAIN="authentik.${BD}"
    fi
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || { echo "ERREUR: TOKEN ou DOMAIN vide" >> "${DEBUG_LOG}"; return 1; }

    local AK_CONTAINER="authentik-server"

    ak_get() {
        local endpoint="$1"
        docker exec -e "AK_TOKEN=${TOKEN}" "${AK_CONTAINER}" python3 -c '
import os, requests, sys
r = requests.get("http://localhost:9000'"${endpoint}"'",
                  headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"]},
                  timeout=10)
sys.stderr.write("GET '"${endpoint}"' -> " + str(r.status_code) + "\n")
if not r.ok:
    sys.stderr.write(r.text[:500] + "\n")
print(r.text if r.ok else "")
' 2>>"${DEBUG_LOG}" || echo ""
    }

    ak_post() {
        local endpoint="$1"
        docker exec -i -e "AK_TOKEN=${TOKEN}" "${AK_CONTAINER}" python3 -c '
import os, sys, requests, json
body = json.load(sys.stdin)
r = requests.post("http://localhost:9000'"${endpoint}"'",
                   headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"],
                            "Content-Type": "application/json"},
                   json=body, timeout=10)
sys.stderr.write("POST '"${endpoint}"' -> " + str(r.status_code) + "\n")
if not r.ok:
    sys.stderr.write(r.text[:1000] + "\n")
print(r.text if r.ok else "")
' 2>>"${DEBUG_LOG}" || echo ""
    }

    echo "  → Connexion à l'API Authentik..."
    if ! docker exec -e "AK_TOKEN=${TOKEN}" "${AK_CONTAINER}" python3 -c '
import os, requests
r = requests.get("http://localhost:9000/api/v3/core/applications/",
                  headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"]}, timeout=5)
exit(0 if r.ok else 1)
' 2>>"${DEBUG_LOG}"; then
        echo "ERREUR: API inaccessible" >> "${DEBUG_LOG}"; return 1
    fi

    local FLOW_UUID INVALIDATION_FLOW_UUID
    FLOW_UUID=$(ak_get "/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || { echo "ERREUR: Flow introuvable" >> "${DEBUG_LOG}"; return 1; }

    INVALIDATION_FLOW_UUID=$(ak_get "/api/v3/flows/instances/?slug=default-provider-invalidation-flow" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null || echo "")
    [ -n "${INVALIDATION_FLOW_UUID}" ] || { echo "ERREUR: Invalidation flow introuvable" >> "${DEBUG_LOG}"; return 1; }

    local SIGNING_KEY SIGNING_RAW
    SIGNING_RAW=$(ak_get "/api/v3/crypto/certificatekeypairs/?has_key=true&ordering=name")
    SIGNING_KEY=$(echo "${SIGNING_RAW}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d.get('results') else '')" 2>/dev/null || echo "")
    [ -n "${SIGNING_KEY}" ] || { echo "ERREUR: Clé de signature introuvable" >> "${DEBUG_LOG}"; return 1; }

    local ALL_SCOPES S_OPENID S_EMAIL S_PROFILE
    ALL_SCOPES=$(ak_get "/api/v3/propertymappings/all/?ordering=name&page_size=200")
    S_OPENID=$(echo "${ALL_SCOPES}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if 'scope-openid' in str(p.get('managed',''))]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")
    S_EMAIL=$(echo "${ALL_SCOPES}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if 'scope-email' in str(p.get('managed',''))]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")
    S_PROFILE=$(echo "${ALL_SCOPES}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if 'scope-profile' in str(p.get('managed',''))]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")
    [ -n "${S_OPENID}" ] || { echo "ERREUR: Scopes OIDC introuvables" >> "${DEBUG_LOG}"; return 1; }

    local PROVIDER_RESP PROVIDER_PK
    PROVIDER_PK=$(ak_get "/api/v3/providers/oauth2/" \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
m=[p for p in d.get('results',[]) if p['name']==\"${APP_NAME} SSO\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -n "${PROVIDER_PK}" ]; then
        PROVIDER_RESP=$(ak_get "/api/v3/providers/oauth2/${PROVIDER_PK}/")
    else
        local BODY
        BODY=$(python3 -c "
import json
scopes=[s for s in ['${S_OPENID}','${S_EMAIL}','${S_PROFILE}'] if s]
print(json.dumps({
    'name': '${APP_NAME} SSO',
    'authorization_flow': '${FLOW_UUID}',
    'invalidation_flow': '${INVALIDATION_FLOW_UUID}',
    'client_type': 'confidential',
    'redirect_uris': [{'url': '${REDIRECT_URI}', 'matching_mode': 'regex'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
    'signing_key': '${SIGNING_KEY}',
    'property_mappings': scopes
}))
")
        PROVIDER_RESP=$(echo "${BODY}" | ak_post "/api/v3/providers/oauth2/")
        PROVIDER_PK=$(echo "${PROVIDER_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "ERREUR: Erreur création OAuth2 Provider" >> "${DEBUG_LOG}"; return 1; }

    OIDC_CLIENT_ID=$(echo "${PROVIDER_RESP}"     | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_id',''))"     2>/dev/null || echo "")
    OIDC_CLIENT_SECRET=$(echo "${PROVIDER_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
    [ -n "${OIDC_CLIENT_ID}" ] && [ -n "${OIDC_CLIENT_SECRET}" ] || { echo "ERREUR: Client ID/Secret vides" >> "${DEBUG_LOG}"; return 1; }

    python3 -c "
import json
print(json.dumps({'name':'${APP_NAME}','slug':'${APP_SLUG}','provider':${PROVIDER_PK}}))
" | ak_post "/api/v3/core/applications/" >/dev/null || true

    echo "  → SSO OIDC configuré dans Authentik ✓"
    return 0
}

# ── Certificat TLS auto-signé pour communication interne Docker → Authentik ──
# Même fonction que Nextcloud — génère le cert pour Traefik file provider
setup_authentik_tls_cert() {
    local AK_DOMAIN="$1"
    local TRAEFIK_CERTS_DIR="${CALEOPE_BASE_DIR}/data/traefik/certs"
    local TRAEFIK_DYNAMIC_DIR="${CALEOPE_BASE_DIR}/data/traefik/dynamic"
    local CERT_FILE="${TRAEFIK_CERTS_DIR}/authentik.crt"
    local KEY_FILE="${TRAEFIK_CERTS_DIR}/authentik.key"
    local TLS_CONFIG="${TRAEFIK_DYNAMIC_DIR}/authentik-tls.yml"

    if [ ! -d "${TRAEFIK_DYNAMIC_DIR}" ]; then
        echo "  ⚠ Répertoire Traefik introuvable — certificat non généré"
        return 0
    fi

    mkdir -p "${TRAEFIK_CERTS_DIR}"

    if [ ! -f "${CERT_FILE}" ] || \
       ! openssl x509 -checkend 2592000 -noout -in "${CERT_FILE}" 2>/dev/null; then
        echo "  → Génération du certificat auto-signé (SAN: ${AK_DOMAIN})..."
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout "${KEY_FILE}" \
            -out    "${CERT_FILE}" \
            -subj   "/CN=${AK_DOMAIN}" \
            -addext "subjectAltName=DNS:${AK_DOMAIN}" \
            2>/dev/null
        chmod 600 "${KEY_FILE}"
        echo "  ✓ Certificat généré : ${CERT_FILE}"
    else
        echo "  ✓ Certificat Authentik valide déjà présent"
    fi

    cat > "${TLS_CONFIG}" << TLSEOF
tls:
  certificates:
    - certFile: /certs/authentik.crt
      keyFile: /certs/authentik.key
TLSEOF

    if docker ps --format '{{.Names}}' | grep -q '^traefik$'; then
        echo "  → Rechargement de Traefik..."
        docker restart traefik >/dev/null 2>&1 \
            && echo "  ✓ Traefik redémarré" \
            || echo "  ⚠ Relancer manuellement : docker restart traefik"
    fi
}

# ── Intégration Authentik ────────────────────────────────────────────────────
OIDC_CLIENT_ID="" OIDC_CLIENT_SECRET="" OIDC_AK_DOMAIN=""

if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    # Redirect URI en regex car l'ID du provider est inconnu avant insertion
    # Le plugin singlesignon génère une URL du type :
    #   /plugins/singlesignon/front/callback.php/provider/<id>
    REDIRECT_URI_REGEX="https://${CALEOPE_DOMAIN}/plugins/singlesignon/front/callback.php/provider/[0-9]+"
    REDIRECT_URI_BASE="https://${CALEOPE_DOMAIN}/plugins/singlesignon/front/callback.php"

    setup_authentik_tls_cert "${AUTHENTIK_DOMAIN}"

    if authentik_setup_oidc "GLPI" "glpi-sso" "${REDIRECT_URI_REGEX}"; then
        OIDC_AK_DOMAIN="${AUTHENTIK_DOMAIN}"
        cat >> "${CONFIG_DIR}/secrets.env" << OIDCENV
# SSO OIDC — transmis à glpi-init.sh pour configurer le plugin singlesignon
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
OIDC_REDIRECT_URI_BASE=${REDIRECT_URI_BASE}
OIDC_AUTHORIZE_URL=https://${AUTHENTIK_DOMAIN}/application/o/authorize/
OIDC_TOKEN_URL=https://${AUTHENTIK_DOMAIN}/application/o/token/
OIDC_USERINFO_URL=https://${AUTHENTIK_DOMAIN}/application/o/userinfo/
OIDCENV
    else
        echo "  ⚠ SSO OIDC désactivé (voir /tmp/caleope_glpi_sso.log)"
    fi
fi

# ── glpi-init.sh : init automatique dans le container glpi ───────────────────
# Lance /opt/glpi-start.sh (Apache) en background puis installe GLPI via CLI
# et configure le plugin oauth2sso. Tourne comme entrypoint du container glpi.
cat > "${CONFIG_DIR}/glpi-init.sh" << 'INITSCRIPT'
#!/bin/bash
set -uo pipefail

GLPI_DIR="/var/www/html/glpi"

# Lance l'entrypoint original (télécharge GLPI + démarre Apache) en background
/opt/glpi-start.sh &
MAIN_PID=$!

# Attend que GLPI soit extrait par glpi-start.sh
echo "[glpi-init] Attente de l'extraction GLPI..."
until [ -f "${GLPI_DIR}/bin/console" ]; do
    sleep 5
    kill -0 $MAIN_PID 2>/dev/null || { echo "[glpi-init] Processus principal mort"; exit 1; }
done
echo "[glpi-init] GLPI extrait"

# Confiance TLS Authentik (PHP/curl doit valider le cert auto-signé)
if [ -f "/usr/local/share/ca-certificates/authentik.crt" ] && \
   grep -q 'BEGIN CERTIFICATE' "/usr/local/share/ca-certificates/authentik.crt" 2>/dev/null; then
    update-ca-certificates 2>/dev/null || true
fi

# Attend MariaDB
echo "[glpi-init] Attente de MariaDB..."
until php -r "
try {
    new PDO('mysql:host='.getenv('MARIADB_HOST').';dbname='.getenv('MARIADB_DATABASE'),
            getenv('MARIADB_USER'), getenv('MARIADB_PASSWORD'));
    exit(0);
} catch(Exception \$e) { exit(1); }
" 2>/dev/null; do sleep 5; done
echo "[glpi-init] MariaDB OK"

# Installation CLI de GLPI si config_db.php absent (1er démarrage)
if [ ! -f "${GLPI_DIR}/config/config_db.php" ]; then
    echo "[glpi-init] Installation de la base de données GLPI..."
    cd "${GLPI_DIR}"
    php bin/console database:configure \
        --db-host="${MARIADB_HOST:-glpi-db}" \
        --db-name="${MARIADB_DATABASE:-glpi}" \
        --db-user="${MARIADB_USER:-glpi}" \
        --db-password="${MARIADB_PASSWORD}" \
        --reconfigure --allow-superuser --no-interaction 2>&1 || true
    php bin/console database:install \
        --default-language=fr_FR \
        --allow-superuser --no-interaction 2>&1 || true
    echo "[glpi-init] GLPI installé"
fi

# Attend que glpi_users existe (install complète)
until php -r "
try {
    \$p = new PDO('mysql:host='.getenv('MARIADB_HOST').';dbname='.getenv('MARIADB_DATABASE'),
                  getenv('MARIADB_USER'), getenv('MARIADB_PASSWORD'));
    \$r = \$p->query('SHOW TABLES LIKE \"glpi_users\"');
    exit(\$r && \$r->rowCount() > 0 ? 0 : 1);
} catch(Exception \$e) { exit(1); }
" 2>/dev/null; do sleep 5; done
echo "[glpi-init] Tables GLPI OK"

# Changer le mot de passe admin local
if [ -n "${GLPI_ADMIN_PASSWORD:-}" ]; then
    php -r "
\$p = new PDO('mysql:host='.getenv('MARIADB_HOST').';dbname='.getenv('MARIADB_DATABASE'),
              getenv('MARIADB_USER'), getenv('MARIADB_PASSWORD'),
              [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
\$hash = password_hash(getenv('GLPI_ADMIN_PASSWORD'), PASSWORD_BCRYPT);
\$s = \$p->prepare('UPDATE glpi_users SET password=? WHERE name=?');
\$s->execute([\$hash, 'glpi']);
echo '[glpi-init] Mot de passe admin mis à jour'.PHP_EOL;
" 2>/dev/null || echo "[glpi-init] ⚠ Mot de passe admin non modifié"
fi

# Plugin singlesignon OAuth2/OIDC pour GLPI 11
# https://github.com/edgardmessias/glpi-singlesignon
if [ -n "${OIDC_CLIENT_ID:-}" ]; then
    PLUGIN_DIR="${GLPI_DIR}/plugins/singlesignon"
    PLUGIN_DL="https://github.com/edgardmessias/glpi-singlesignon/releases/latest/download/singlesignon.tgz"

    if [ ! -d "${PLUGIN_DIR}" ]; then
        echo "[glpi-init] Téléchargement du plugin singlesignon..."
        TMP=$(mktemp -d)
        if curl -sfL --max-time 120 -o "${TMP}/singlesignon.tgz" "${PLUGIN_DL}"; then
            cd "${GLPI_DIR}/plugins"
            tar -xzf "${TMP}/singlesignon.tgz"
            rm -rf "${TMP}"
            chown -R www-data:www-data "${PLUGIN_DIR}" 2>/dev/null || true
            echo "[glpi-init] Plugin téléchargé"
        else
            rm -rf "${TMP}"
            echo "[glpi-init] ⚠ Plugin non téléchargé"
        fi
    fi

    if [ -d "${PLUGIN_DIR}" ]; then
        echo "[glpi-init] Installation du plugin singlesignon..."
        cd "${GLPI_DIR}"
        php bin/console glpi:plugin:install  --username=glpi singlesignon --allow-superuser 2>&1 || \
        php bin/console plugin:install       --username=glpi singlesignon --allow-superuser 2>&1 || true
        php bin/console glpi:plugin:activate singlesignon --allow-superuser 2>&1 || \
        php bin/console plugin:activate      singlesignon --allow-superuser 2>&1 || true
        echo "[glpi-init] Plugin installé et activé"

        sleep 3

        echo "[glpi-init] Configuration du provider OIDC..."
        php -r "
\$pdo = new PDO('mysql:host='.getenv('MARIADB_HOST').';dbname='.getenv('MARIADB_DATABASE'),
               getenv('MARIADB_USER'), getenv('MARIADB_PASSWORD'),
               [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

// Définir url_base GLPI (sinon GLPI utilise localhost dans les redirections OAuth)
\$glpiUrl = getenv('GLPI_URL_BASE') ?: '';
if (\$glpiUrl) {
    \$s = \$pdo->prepare(\"INSERT INTO glpi_configs (context, name, value) VALUES ('core','url_base',?)
        ON DUPLICATE KEY UPDATE value=?\");
    \$s->execute([\$glpiUrl, \$glpiUrl]);
    echo '[glpi-init] url_base = ' . \$glpiUrl . PHP_EOL;
}

\$check = \$pdo->prepare('SELECT id FROM glpi_plugin_singlesignon_providers WHERE name=?');
\$check->execute(['Authentik']);
\$existing = \$check->fetch(PDO::FETCH_ASSOC);

// auto_register=1 : création automatique du compte à la 1ère connexion SSO
// default_profiles_id=1 : profil Self-Service par défaut (id=1 dans GLPI)
// ssl_verify_host/peer=0 : Authentik utilise un cert auto-signé via Traefik
// use_email_for_login=1 : identifiant = email (cohérent avec Authentik)
if (\$existing) {
    \$stmt = \$pdo->prepare('UPDATE glpi_plugin_singlesignon_providers SET
        type=?, client_id=?, client_secret=?, scope=?,
        url_authorize=?, url_access_token=?, url_resource_owner_details=?,
        is_active=1, auto_register=1, default_profiles_id=1,
        use_email_for_login=1, ssl_verify_host=0, ssl_verify_peer=0
        WHERE id=?');
    \$stmt->execute([
        'generic', getenv('OIDC_CLIENT_ID'), getenv('OIDC_CLIENT_SECRET'), 'openid profile email',
        getenv('OIDC_AUTHORIZE_URL'), getenv('OIDC_TOKEN_URL'), getenv('OIDC_USERINFO_URL'),
        \$existing['id']
    ]);
    \$pid = \$existing['id'];
} else {
    \$stmt = \$pdo->prepare('INSERT INTO glpi_plugin_singlesignon_providers
        (name, type, client_id, client_secret, scope,
         url_authorize, url_access_token, url_resource_owner_details,
         is_active, auto_register, default_profiles_id,
         use_email_for_login, ssl_verify_host, ssl_verify_peer)
        VALUES (?,?,?,?,?,?,?,?,1,1,1,1,0,0)');
    \$stmt->execute([
        'Authentik', 'generic', getenv('OIDC_CLIENT_ID'), getenv('OIDC_CLIENT_SECRET'),
        'openid profile email', getenv('OIDC_AUTHORIZE_URL'), getenv('OIDC_TOKEN_URL'),
        getenv('OIDC_USERINFO_URL')
    ]);
    \$pid = \$pdo->lastInsertId();
}
\$base = getenv('OIDC_REDIRECT_URI_BASE') ?: '';
echo '[glpi-init] Provider OIDC id=' . \$pid . PHP_EOL;
if (\$base) { echo '[glpi-init] Callback: ' . \$base . '/provider/' . \$pid . PHP_EOL; }
echo '[glpi-init] Configuration OIDC sauvegardée'.PHP_EOL;
" 2>/dev/null || echo "[glpi-init] ⚠ Config OIDC échouée"
    fi
else
    echo "[glpi-init] Pas de config OIDC — SSO non activé"
fi

echo "[glpi-init] Activation de l'API REST GLPI..."
php -r "
\$pdo = new PDO('mysql:host='.getenv('MARIADB_HOST').';dbname='.getenv('MARIADB_DATABASE'),
               getenv('MARIADB_USER'), getenv('MARIADB_PASSWORD'),
               [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
// Activer l'API REST
\$s = \$pdo->prepare(\"INSERT INTO glpi_configs (context, name, value) VALUES ('core','enable_api',1)
    ON DUPLICATE KEY UPDATE value=1\");
\$s->execute();
// Désactiver l'obligation d'app token (utilisation par credentials seuls)
\$s2 = \$pdo->prepare(\"INSERT INTO glpi_configs (context, name, value) VALUES ('core','enable_api_login',1)
    ON DUPLICATE KEY UPDATE value=1\");
\$s2->execute();
\$s3 = \$pdo->prepare(\"INSERT INTO glpi_configs (context, name, value) VALUES ('core','api_url_base',?)
    ON DUPLICATE KEY UPDATE value=?\");
\$base = (getenv('GLPI_URL_BASE') ?: '') . '/apirest.php';
\$s3->execute([\$base, \$base]);
echo '[glpi-init] API REST activée' . PHP_EOL;
" 2>/dev/null || echo "[glpi-init] ⚠ Activation API REST échouée"

echo "[glpi-init] Initialisation terminée ✓"

# Fix permissions — les commandes php bin/console tournent en root,
# ce qui crée files/_cache/ en root:root ; Apache (www-data) ne peut pas les lire.
chown -R www-data:www-data "${GLPI_DIR}/files/" 2>/dev/null || true

# Reste en vie tant qu'Apache tourne
wait $MAIN_PID
INITSCRIPT
chmod +x "${CONFIG_DIR}/glpi-init.sh"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────┐
  │                  GLPI — Premiers accès                       │
  ├──────────────────────────────────────────────────────────────┤
  │  ⏳  GLPI installe sa base de données au premier démarrage   │
  │      (environ 2-4 min). Patienter avant d'ouvrir l'URL.     │
  │                                                              │
  │  URL  : https://${CALEOPE_DOMAIN}                            │
  │                                                              │
  │  Compte admin local (conservé même avec SSO) :              │
  │    Login    : glpi                                           │
  │    Password : ${ADMIN_PASS}                          │
EOF

if [ -n "${OIDC_CLIENT_ID}" ]; then
cat >> "${CONFIG_DIR}/post-install.txt" << EOF
  │                                                              │
  │  SSO Authentik (plugin singlesignon) :                       │
  │    → Configuré automatiquement au démarrage                  │
  │    → Bouton "Login with Authentik" sur la page login         │
  │    → Les comptes sont créés automatiquement à la 1ère cnx   │
  │    → L'admin local reste toujours accessible                 │
  │                                                              │
  │  ⚠️  Si le SSO échoue avec une erreur TLS :                 │
  │      GLPI > Setup > Single Sign-On → désactiver SSL verify   │
  │      (temporaire) ou charger le cert depuis :                │
  │      data/traefik/certs/authentik.crt                        │
EOF
else
cat >> "${CONFIG_DIR}/post-install.txt" << EOF
  │                                                              │
  │  SSO Authentik : non configuré (Authentik absent)           │
  │  → Installer Authentik puis relancer : caleope configure glpi│
EOF
fi

cat >> "${CONFIG_DIR}/post-install.txt" << EOF
  │                                                              │
  │  ⚠️  Supprimer le fichier d'install après setup :            │
  │      docker exec glpi rm /var/www/html/glpi/install/install.php │
  │                                                              │
  │  Secrets : app-config/glpi/secrets.env                      │
  └──────────────────────────────────────────────────────────────┘
EOF

echo "✓ GLPI préparé"
