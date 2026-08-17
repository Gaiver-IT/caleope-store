#!/bin/bash
# setup.sh — Immich (galerie photos auto-hébergée)
set -euo pipefail
echo "→ Préparation d'Immich..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/immich"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{library,db,model-cache,thumbs-local}

# ── Témoin de montage attendu par Immich ────────────────────────────────────
# Immich dépose un fichier « .immich » dans CHAQUE dossier qu'il monte et
# REFUSE de démarrer s'il n'arrive pas à le relire — mesuré sur le banc, le
# serveur repartait en boucle sur « Failed to read
# /usr/src/app/upload/thumbs/.immich ». Un dossier de miniatures local tout
# neuf n'en a pas : on l'écrit nous-mêmes, au même format qu'Immich (un
# horodatage en millisecondes). On ne touche JAMAIS un témoin existant : il
# appartient à Immich.
if [ ! -f "${DATA_DIR}/thumbs-local/.immich" ]; then
    printf '%s' "$(date +%s%3N)" > "${DATA_DIR}/thumbs-local/.immich"
fi

# ── Choix de l'image de base : migration en deux temps, automatique ─────────
# POURQUOI : l'image de base ne fournit plus l'extension « vectors ». Immich a
# abandonné pgvecto.rs en v3.0.0 et migre les bases vers VectorChord au premier
# démarrage — mais seulement sur l'image de TRANSITION, qui embarque les deux.
# Une base restée sur pgvecto.rs ne perd rien si on démarre sans la
# bibliothèque, mais Immich ne sait plus lire ses vecteurs : l'app tombe.
#
# On ne REFUSE pas pour autant : un setup.sh qui sort en erreur déclenche le
# rollback du daemon, qui arrête les conteneurs, EFFACE apps-installed/immich/
# et désinscrit l'app. Refuser coûterait donc à l'utilisateur l'app qui
# marchait. On épingle plutôt l'image de transition : Immich migre tout seul au
# démarrage, et la montée suivante atterrit sur l'image cible.
#
# ⚠️ Seul le catalogue tranche : ni le répertoire « pg_vectors » de PGDATA ni
# shared_preload_libraries ne distinguent une base migrée d'une base qui ne
# l'est pas — mesuré sur deux instances déjà migrées, les deux portent encore
# un pg_vectors non vide. Un contrôle sur disque se tromperait à tous les coups.
#
# setup.sh tourne AVANT « docker compose up » et peut modifier le compose
# engendré : lors d'une montée, l'ancienne base est donc encore interrogeable.
_IMG_TRANSITION="ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
# ⚠️ Le fichier engendré s'appelle « compose.yml », pas « docker-compose.yml » —
# se tromper de nom ne casse rien de visible, ça saute juste tout ce bloc en
# silence, et les bases héritées partent au cassage. On prend le chemin que le
# daemon nous donne (CALEOPE_APP_DIR) et on essaie les deux noms.
_COMPOSE=""
for _f in "${CALEOPE_APP_DIR:-${CALEOPE_BASE_DIR}/apps-installed/${CALEOPE_APP_ID}}/compose.yml" \
          "${CALEOPE_APP_DIR:-${CALEOPE_BASE_DIR}/apps-installed/${CALEOPE_APP_ID}}/docker-compose.yml"; do
    [ -f "${_f}" ] && { _COMPOSE="${_f}"; break; }
done

if [ -f "${DATA_DIR}/db/PG_VERSION" ] && [ -z "${_COMPOSE}" ]; then
    echo "  ⚠ Compose engendré introuvable : le contrôle pgvecto.rs n'a pas pu"
    echo "    s'exécuter. Vérifiez la base avant de redémarrer l'app."
fi

if [ -f "${DATA_DIR}/db/PG_VERSION" ] && [ -n "${_COMPOSE}" ]; then
    # Le catalogue : 0 = migrée, 1 = encore sur pgvecto.rs, autre = pas de réponse.
    _SQL="select 'CALEOPE_VECTORS_'||count(*) from pg_extension where extname='vectors';"
    _REP=$(printf '%s\n' "${_SQL}" \
        | docker exec -i immich-db psql -U immich -t -A immich 2>/dev/null \
        | tr -d '[:space:]' || true)
    # L'image RÉELLEMENT en service : on ne redescend jamais une base déjà
    # passée en VectorChord 1.x sous une bibliothèque 0.4 qui ne saurait la lire.
    _IMG_ACTUELLE=$(docker inspect immich-db --format '{{.Config.Image}}' 2>/dev/null || true)

    # Une base migrée peut garder une entrée « vectors » qui ne sert plus à rien.
    # On ne la laisse pas traîner : un pg_dump la ré-émettrait en « CREATE
    # EXTENSION vectors », irrestaurable sur une image qui ne la fournit plus.
    # Le retrait se fait SANS CASCADE : c'est PostgreSQL qui tranche, et il
    # refuse tout seul dès qu'une colonne ou un index en dépend encore — donc
    # une vraie bibliothèque héritée ne peut pas être amputée par cette ligne.
    if [ "${_REP}" != "CALEOPE_VECTORS_0" ] && [ -n "${_REP}" ]; then
        case "${_REP}" in
            CALEOPE_VECTORS_*)
                if printf 'drop extension vectors;\n' \
                     | docker exec -i immich-db psql -U immich -v ON_ERROR_STOP=1 immich >/dev/null 2>&1; then
                    echo "  ✓ Entrée pgvecto.rs retirée : plus aucune donnée n'en dépendait."
                    _REP="CALEOPE_VECTORS_0"
                fi ;;
        esac
    fi

    _EPINGLER=""
    case "${_REP}" in
        CALEOPE_VECTORS_0)
            echo "  ✓ Base déjà sur VectorChord — image cible conservée." ;;
        CALEOPE_VECTORS_*)
            echo "  ⚠ Cette base photo porte encore des données pgvecto.rs."
            echo "    → image de transition conservée : Immich va migrer la base au"
            echo "      démarrage (« Reindexing » dans les journaux). Relancez la"
            echo "      montée ensuite pour passer sur VectorChord 1.1."
            _EPINGLER="${_IMG_TRANSITION}" ;;
        *)
            case "${_IMG_ACTUELLE}" in
                *vectorchord1*)
                    echo "  ⚠ Base injoignable, mais déjà en VectorChord 1.x — image cible conservée." ;;
                *)
                    echo "  ⚠ Base injoignable : impossible de savoir si elle porte encore"
                    echo "    pgvecto.rs. On ne change donc rien à la base de données."
                    _EPINGLER="${_IMG_TRANSITION}" ;;
            esac ;;
    esac

    if [ -n "${_EPINGLER}" ]; then
        sed -i "s|image: ghcr.io/immich-app/postgres:.*|image: ${_EPINGLER}|" "${_COMPOSE}"
        echo "    image de base épinglée : ${_EPINGLER}"
    fi
fi

# ── Préservation des secrets ────────────────────────────────────────────────
# POURQUOI : une montée de version passe par « caleope install immich --force »,
# donc par ce script. Si on réengendre les mots de passe à chaque passage, la
# base PostgreSQL garde l'ancien mot de passe pendant qu'Immich présente le
# nouveau : l'app se coupe de ses propres données (http 000, erreurs d'auth).
# On relit donc la valeur déjà écrite dans secrets.env quand elle existe, et on
# n'engendre que lors de la toute première installation.
_SECRETS="${CONFIG_DIR}/secrets.env"
_garde() { # $1 = clé TELLE QU'ÉCRITE dans secrets.env, $2 = commande d'engendrement
    local cur=""
    # « || true » : sans lui, un grep sans résultat casse le script (set -o pipefail)
    [ -f "${_SECRETS}" ] && cur=$(grep -m1 "^$1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; else eval "$2"; fi
}

# ── Secrets ─────────────────────────────────────────────────────────────────
# DB_PASS alimente à la fois POSTGRES_PASSWORD et DB_PASSWORD (même valeur) :
# le relire depuis POSTGRES_PASSWORD préserve donc les deux clés.
DB_PASS=$(_garde POSTGRES_PASSWORD "openssl rand -hex 24")
ADMIN_EMAIL="admin@${CALEOPE_DOMAIN}"
ADMIN_PASS=$(_garde IMMICH_ADMIN_PASS "openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20")
ADMIN_NAME="Admin"

# ── SMTP (global Caleope) ────────────────────────────────────────────────────
SMTP_HOST="${CALEOPE_SMTP_HOST:-}"
SMTP_PORT="${CALEOPE_SMTP_PORT:-587}"
SMTP_USER="${CALEOPE_SMTP_USER:-}"
SMTP_PASS="${CALEOPE_SMTP_PASS:-}"
SMTP_FROM="${CALEOPE_SMTP_FROM:-noreply@${CALEOPE_DOMAIN}}"

cat > "${CONFIG_DIR}/secrets.env" << EOF
# PostgreSQL
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_USER=immich
POSTGRES_DB=immich

# Immich
DB_HOSTNAME=immich-db
DB_USERNAME=immich
DB_PASSWORD=${DB_PASS}
DB_DATABASE_NAME=immich
REDIS_HOSTNAME=immich-redis

# URL publique (pour les liens de partage)
IMMICH_SERVER_URL=https://${CALEOPE_DOMAIN}

# SMTP (configuré via l'interface admin Immich)
_SMTP_HOST=${SMTP_HOST}
_SMTP_PORT=${SMTP_PORT}
_SMTP_USER=${SMTP_USER}
_SMTP_PASS=${SMTP_PASS}
_SMTP_FROM=${SMTP_FROM}

# Admin auto-créé par le bootstrap container
IMMICH_ADMIN_EMAIL=${ADMIN_EMAIL}
IMMICH_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── SSO OAuth2 via Authentik ─────────────────────────────────────────────────
# Immich supporte OAuth2 natif. On crée un provider OIDC dans Authentik ici
# (Authentik est déjà en cours depuis la machine hôte).
# La configuration dans Immich se fait via le bootstrap container (après démarrage).
IMMICH_OIDC_SECRET=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-) || true
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2- || echo "")
        [ -n "${AK_DOMAIN}" ] || AK_DOMAIN="authentik.${CALEOPE_DOMAIN#*.}"

        if [ -n "${AK_TOKEN}" ]; then
            AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null || echo "9000")
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            echo "  → Configuration OAuth2 Immich dans Authentik..."

            AUTH_FLOW=$(curl -sf --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -sf --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                IMMICH_OIDC_SECRET=$(openssl rand -hex 16)
                PROV_BODY=$(python3 -c "
import json
print(json.dumps({
    'name': 'Immich',
    'authorization_flow': '${AUTH_FLOW}',
    'invalidation_flow': '${INVAL_FLOW}',
    'client_type': 'confidential',
    'client_id': 'immich',
    'client_secret': '${IMMICH_OIDC_SECRET}',
    'redirect_uris': [{'matching_mode': 'strict', 'url': 'https://${CALEOPE_DOMAIN}/auth/login'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
}))
" 2>/dev/null)
                PROV_PK=$(curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" -d "${PROV_BODY}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Immich\",\"slug\":\"immich-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Groupes Authentik
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-immich-users\",\"is_superuser\":false}" \
                        >/dev/null 2>&1 || true
                    curl -sf --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-immich-admins\",\"is_superuser\":false}" \
                        >/dev/null 2>&1 || true

                    # extra_hosts + cert Traefik pour que Immich joigne Authentik
                    TRAEFIK_IP=$(docker inspect traefik \
                        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}' || echo "")
                    TRAEFIK_CERT="${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"

                    if [ -n "${TRAEFIK_IP}" ] && [ -f "${TRAEFIK_CERT}" ]; then
                        awk -v domain="${AK_DOMAIN}" -v ip="${TRAEFIK_IP}" -v cert="${TRAEFIK_CERT}" '
/^  immich-server:$/ { in_svc=1 }
/^  [a-z]/ && !/^  immich-server:$/ { in_svc=0 }
in_svc && /^    env_file:/ && !extra_done {
    print "    environment:"
    print "      - NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/traefik-auth.crt"
    print "    extra_hosts:"
    print "      - \"" domain ":" ip "\""
    extra_done=1
}
in_svc && /^    volumes:/ && !vol_done {
    print
    print "      - \"" cert ":/usr/local/share/ca-certificates/traefik-auth.crt:ro\""
    vol_done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/immich_compose_sso.yml && \
                        mv /tmp/immich_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true
                    fi

                    # Stocker les credentials OIDC pour le bootstrap container
                    cat >> "${CONFIG_DIR}/secrets.env" << OIDCENV
IMMICH_OIDC_CLIENT_ID=immich
IMMICH_OIDC_CLIENT_SECRET=${IMMICH_OIDC_SECRET}
IMMICH_OIDC_ISSUER_URL=https://${AK_DOMAIN}/application/o/immich-sso/
OIDCENV
                    echo "  ✓ Immich OAuth2 configuré dans Authentik (PK=${PROV_PK})"
                fi
            fi
        fi
    fi
fi

# ── bootstrap.sh (admin signup + OAuth2 Immich après démarrage) ──────────────
# setup.sh tourne à l'étape 7 (avant docker compose up étape 9).
# Le bootstrap container attend qu'Immich soit prêt, crée l'admin et configure OAuth2.
cat > "${CONFIG_DIR}/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/sh
set -e

IMMICH_URL="http://immich-server.:2283"
MAX_WAIT=180
WAITED=0

echo "→ Immich bootstrap : attente de l'API..."
until curl -sf --max-time 5 "${IMMICH_URL}/api/server/about" >/dev/null 2>&1; do
    sleep 5
    WAITED=$((WAITED + 5))
    [ "${WAITED}" -lt "${MAX_WAIT}" ] || { echo "⚠ Immich non joignable après ${MAX_WAIT}s — skip"; exit 0; }
done
echo "  ✓ API Immich prête (${WAITED}s)"

# Créer le compte admin (idempotent via /api/auth/admin-sign-up)
echo "→ Création du compte admin Immich..."
SIGNUP_RESP=$(curl -s --max-time 10 -X POST "${IMMICH_URL}/api/auth/admin-sign-up" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${IMMICH_ADMIN_EMAIL}\",\"password\":\"${IMMICH_ADMIN_PASS}\",\"name\":\"Admin\"}" 2>/dev/null || echo "")

if echo "${SIGNUP_RESP}" | grep -q '"email"'; then
    echo "  ✓ Admin Immich créé : ${IMMICH_ADMIN_EMAIL}"
elif echo "${SIGNUP_RESP}" | grep -qi "already\|exists"; then
    echo "  ✓ Admin déjà existant"
else
    echo "  ⚠ Signup: ${SIGNUP_RESP}"
fi

# Configurer OAuth2 si OIDC credentials disponibles
if [ -n "${IMMICH_OIDC_CLIENT_SECRET:-}" ] && [ -n "${IMMICH_OIDC_ISSUER_URL:-}" ]; then
    echo "→ Configuration OAuth2 Immich..."
    TOKEN=$(curl -sf --max-time 10 -X POST "${IMMICH_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${IMMICH_ADMIN_EMAIL}\",\"password\":\"${IMMICH_ADMIN_PASS}\"}" \
        | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [ -n "${TOKEN}" ]; then
        CURR_CFG=$(curl -sf "${IMMICH_URL}/api/system-config" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "{}")
        NEW_CFG=$(echo "${CURR_CFG}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['oauth'] = {
    'enabled': True,
    'issuerUrl': '${IMMICH_OIDC_ISSUER_URL}',
    'clientId': '${IMMICH_OIDC_CLIENT_ID}',
    'clientSecret': '${IMMICH_OIDC_CLIENT_SECRET}',
    'scope': 'openid email profile',
    'signingAlgorithm': 'RS256',
    'profileSigningAlgorithm': 'none',
    'tokenEndpointAuthMethod': 'client_secret_post',
    'storageLabelClaim': 'preferred_username',
    'buttonText': 'Se connecter avec Authentik',
    'autoRegister': True,
    'autoLaunch': False,
}
print(json.dumps(d))
" 2>/dev/null || echo "")
        if [ -n "${NEW_CFG}" ]; then
            curl -sf -X PUT "${IMMICH_URL}/api/system-config" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${TOKEN}" \
                -d "${NEW_CFG}" >/dev/null 2>&1 && echo "  ✓ OAuth2 Immich configuré" || echo "  ⚠ OAuth2 config échouée"
        fi
    else
        echo "  ⚠ Login Immich échoué — OAuth2 à configurer manuellement"
    fi
fi

echo "✓ Immich bootstrap terminé"
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │              Immich — Galerie photos auto-hébergée               │
  ├──────────────────────────────────────────────────────────────────┤
  │  Application : https://${CALEOPE_DOMAIN}/                        │
  │                                                                  │
  │  Compte admin :                                                  │
  │    Email    : ${ADMIN_EMAIL}
  │    Password : ${ADMIN_PASS}
  │                                                                  │
  │  Application mobile : "Immich" sur App Store / Play Store        │
  │    → Entrer https://${CALEOPE_DOMAIN}/ comme URL serveur         │
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Immich — Identifiants admin                ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL      : https://${CALEOPE_DOMAIN}/"
echo "  ║  Email    : ${ADMIN_EMAIL}"
echo "  ║  Password : ${ADMIN_PASS}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Immich configuré"
