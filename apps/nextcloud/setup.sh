#!/bin/bash
set -euo pipefail
echo "→ Préparation de Nextcloud + OnlyOffice..."

mkdir -p "${CALEOPE_BASE_DIR}/app-data/nextcloud/"{html,db,redis}
mkdir -p "${CALEOPE_BASE_DIR}/app-data/nextcloud/onlyoffice/"{logs,data}
mkdir -p "${CALEOPE_BASE_DIR}/app-config/nextcloud"

# ── Secrets : on RELIT l'existant avant de générer ───────────────────────────
# `caleope install --force` rejoue ce script SANS redemander les paramètres.
# Régénérer les mots de passe ici ne serait pas une simple rotation gênante,
# ce serait une PANNE TOTALE :
#   • MYSQL_PASSWORD change dans le fichier mais PAS dans MariaDB (qui l'a déjà
#     inscrit à sa création) → Nextcloud ne peut plus ouvrir sa propre base ;
#   • NEXTCLOUD_ADMIN_PASSWORD n'est lu qu'à la toute première initialisation →
#     le fichier annoncerait un mot de passe qui n'ouvre plus rien.
# Même motif que `_keep` dans authentik / jellyfin / azuracast-discord-bot,
# posé après l'incident du 14/07 où un token Discord avait été vidé ainsi.
_SECRETS="${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"
_prev() { [ -f "${_SECRETS}" ] && grep "^$1=" "${_SECRETS}" 2>/dev/null | head -1 | cut -d= -f2- || true; }

DB_PASS=$(_prev MYSQL_PASSWORD)
[ -n "${DB_PASS}" ] || DB_PASS=$(openssl rand -hex 20)

DB_ROOT_PASS=$(_prev MYSQL_ROOT_PASSWORD)
[ -n "${DB_ROOT_PASS}" ] || DB_ROOT_PASS=$(openssl rand -hex 20)

ADMIN_PASS=$(_prev NEXTCLOUD_ADMIN_PASSWORD)
[ -n "${ADMIN_PASS}" ] || ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

ONLYOFFICE_JWT=$(_prev JWT_SECRET)
[ -n "${ONLYOFFICE_JWT}" ] || ONLYOFFICE_JWT=$(openssl rand -hex 20)

# Les identifiants OIDC subissent le MÊME piège, en pire : secrets.env est
# réécrit intégralement juste en dessous, alors que les clés NC_OIDC_* ne sont
# ré-ajoutées que dans la branche de succès Authentik, bien plus bas. Un
# `install --force` pendant qu'Authentik est arrêté effacerait donc le SSO —
# et comme le bootstrap ne configure user_oidc que si ces clés existent, le
# bouton « Se connecter avec Authentik » disparaîtrait sans un mot d'erreur.
# On capture les valeurs en place AVANT la réécriture ; un filet plus bas les
# restaure si la branche Authentik n'a rien produit.
PREV_OIDC_CLIENT_ID=$(_prev NC_OIDC_CLIENT_ID)
PREV_OIDC_CLIENT_SECRET=$(_prev NC_OIDC_CLIENT_SECRET)
PREV_OIDC_DISCOVERY_URI=$(_prev NC_OIDC_DISCOVERY_URI)

# Domaines dérivés du domaine de base depuis caleope.conf
BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" | cut -d= -f2) || true
ONLYOFFICE_DOMAIN="onlyoffice.${BASE_DOMAIN}"
# Domaine Authentik — utilisé dans extra_hosts du docker-compose pour contourner le hairpin NAT
AUTHENTIK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env" 2>/dev/null | cut -d= -f2- || true)
[ -n "${AUTHENTIK_DOMAIN}" ] || AUTHENTIK_DOMAIN="authentik.${BASE_DOMAIN}"

cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << EOF
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
MYSQL_PASSWORD=${DB_PASS}
NEXTCLOUD_ADMIN_USER=user-caleope
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}
JWT_ENABLED=true
JWT_SECRET=${ONLYOFFICE_JWT}
ONLYOFFICE_DOMAIN=${ONLYOFFICE_DOMAIN}
AUTHENTIK_DOMAIN=${AUTHENTIK_DOMAIN}
EOF
chmod 600 "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

# ── SSO OIDC via Authentik ───────────────────────────────────────────────────
# Nextcloud supporte OIDC natif (user_oidc). L'API Authentik n'est pas joignable
# via son URL publique depuis le serveur (hairpin NAT absent) → http://localhost:8000.
# Nextcloud accède à Authentik via extra_hosts → IP interne Traefik (caleope-public).
CALEOPE_AUTH_MIDDLEWARE=""
NC_OIDC_CLIENT_ID="" NC_OIDC_CLIENT_SECRET="" NC_OIDC_DISCOVERY_URI=""

if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-) || true
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-) || true
        if [ -z "${AK_DOMAIN}" ]; then
            AK_DOMAIN="authentik.${BASE_DOMAIN}"
        fi

        if [ -n "${AK_TOKEN}" ] && [ -n "${AK_DOMAIN}" ]; then
            AK_PORT=$(python3 -c "import json; d=json.load(open('${CALEOPE_BASE_DIR}/runtime/apps/authentik.json')); print(next((p['host'] for p in d.get('ports',[]) if p['name']=='web'), 9000))" 2>/dev/null)
            AK_PORT="${AK_PORT:-9000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            echo "  → Configuration OIDC Nextcloud dans Authentik..."

            AUTH_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            PROP_MAPS=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/propertymappings/scope/?managed__icontains=goauthentik.io" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join('\"'+r['pk']+'\"' for r in d.get('results',[])))" 2>/dev/null || echo "")

            # Certificat RS256 pour la signature JWT — Nextcloud user_oidc n'accepte
            # pas HS256 (symétrique). Sans signing_key, Authentik signe en HS256 par défaut.
            SIGN_KEY=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/crypto/certificatekeypairs/?has_key=true" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                NC_OIDC_SECRET=$(openssl rand -hex 16)
                PROV_BODY=$(python3 -c "
import json
d = {
    'name': 'Nextcloud',
    'authorization_flow': '${AUTH_FLOW}',
    'invalidation_flow': '${INVAL_FLOW}',
    'client_type': 'confidential',
    'client_id': 'nextcloud',
    'client_secret': '${NC_OIDC_SECRET}',
    'redirect_uris': [{'matching_mode': 'strict', 'url': 'https://${CALEOPE_DOMAIN}/apps/user_oidc/code'}],
    'sub_mode': 'user_username',
    'include_claims_in_id_token': True,
}
if '${PROP_MAPS}':
    d['property_mappings'] = [s.strip('\"') for s in '${PROP_MAPS}'.split(',')]
if '${SIGN_KEY}':
    d['signing_key'] = '${SIGN_KEY}'
print(json.dumps(d))
" 2>/dev/null)
                # ── Réutiliser le fournisseur s'il existe déjà ───────────────
                # Authentik REFUSE un client_id en double (400). Le script
                # postait aveuglément : à la deuxième installation (ou après un
                # `--force`), la création échouait, PROV_PK restait vide, et on
                # repartait SANS SSO — en silence, sans message d'erreur.
                # On regarde donc d'abord. Authentik renvoie le client_secret
                # existant, ce qui permet de le réutiliser tel quel.
                _EXIST=$(curl -s --max-time 10 -H "${AK_HA}" \
                    "${AK_BASE}/providers/oauth2/?client_id=nextcloud" \
                    | python3 -c "
import sys, json
r = (json.load(sys.stdin).get('results') or [])
print('%s|%s' % (r[0]['pk'], r[0].get('client_secret', '')) if r else '')
" 2>/dev/null || echo "")

                if [ -n "${_EXIST}" ]; then
                    PROV_PK="${_EXIST%%|*}"
                    _EXIST_SECRET="${_EXIST#*|}"
                    [ -n "${_EXIST_SECRET}" ] && NC_OIDC_SECRET="${_EXIST_SECRET}"
                    echo "  → fournisseur OIDC Nextcloud déjà présent (PK=${PROV_PK}) — réutilisé"
                else
                    PROV_PK=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/providers/oauth2/" -d "${PROV_BODY}" \
                        | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
                fi

                if [ -n "${PROV_PK}" ]; then
                    # Création SI ABSENTE, puis mise à jour DANS TOUS LES CAS.
                    # ⚠️ L'application peut déjà exister d'une installation
                    # précédente. Le POST échoue alors (slug en double) et
                    # l'application reste accrochée à un ANCIEN fournisseur.
                    # Authentik refuse alors l'autorisation — « Permission
                    # denied » — alors que tout paraît configuré : le client_id
                    # envoyé par Nextcloud pointe vers un fournisseur qui n'a
                    # aucune application liée. Constaté en production le 09/08.
                    # Le PATCH qui suit garantit le bon lien, création ou pas.
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Nextcloud\",\"slug\":\"nextcloud-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    curl -s --max-time 10 -X PATCH -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/nextcloud-sso/" \
                        -d "{\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${CALEOPE_DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Groupes Authentik par app
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-nextcloud-users\",\"is_superuser\":false}" >/dev/null 2>&1 || true
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/groups/" \
                        -d "{\"name\":\"caleope-nextcloud-admins\",\"is_superuser\":false}" >/dev/null 2>&1 || true

                    NC_OIDC_CLIENT_ID="nextcloud"
                    NC_OIDC_CLIENT_SECRET="${NC_OIDC_SECRET}"
                    NC_OIDC_DISCOVERY_URI="https://${AK_DOMAIN}/application/o/nextcloud-sso/.well-known/openid-configuration"

                    # Ajouter extra_hosts pour que Nextcloud résolve le domaine Authentik
                    # Nextcloud → Authentik via IP interne Traefik (évite le hairpin NAT)
                    TRAEFIK_IP=$(docker inspect traefik \
                        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | \
                        awk '{print $1}')
                    TRAEFIK_CERT="${CALEOPE_BASE_DIR}/data/traefik/certs/authentik.crt"
                    if [ -n "${TRAEFIK_IP}" ]; then
                        # entrypoint update-ca-certificates + montage du certificat.
                        # Nextcloud (PHP) vérifie le SSL → il faut lui faire confiance
                        # au certificat de Traefik.
                        #
                        # ⚠️ On n'injecte PLUS extra_hosts ici : le modèle compose le
                        # définit déjà dans ce même service (`${AUTHENTIK_DOMAIN}:host-gateway`).
                        # Injecter le nôtre créait une SECONDE clé `extra_hosts` dans le
                        # même mapping → « mapping key already defined » → docker compose
                        # refuse le fichier et l'installation échoue. Le modèle a été
                        # modernisé sans que cette injection soit retirée.
                        awk -v cert="${TRAEFIK_CERT}" '
/^  nextcloud:$/ { in_nc=1 }
/^  [a-z]/ && !/^  nextcloud:$/ { in_nc=0 }
in_nc && /^    env_file:/ && !extra_done {
    print "    entrypoint: [\"/bin/sh\", \"-c\", \"update-ca-certificates 2>/dev/null || true; exec /entrypoint.sh apache2-foreground\"]"
    extra_done=1
}
in_nc && /^    volumes:/ && !vol_done {
    print
    print "      - \"" cert ":/usr/local/share/ca-certificates/traefik-auth.crt:ro\""
    vol_done=1
    next
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/nc_compose_sso.yml && \
                        mv /tmp/nc_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true

                        # ── extra_hosts : SEULEMENT en cas de vrai hairpin NAT ──
                        # Si le domaine public d'Authentik résout déjà depuis le
                        # serveur (DNS interne, entrée /etc/hosts, proxy en amont),
                        # le détourner vers le Traefik LOCAL est NUISIBLE : celui-ci
                        # n'a ni certificat valide pour ce nom, ni routeur sur 443.
                        # Constaté le 09/08 en production : Nextcloud affichait
                        # « Impossible de joindre le fournisseur OpenID Connect »
                        # alors que le chemin normal, via le proxy, répondait 200
                        # avec un certificat valide. On ne détourne donc que si le
                        # nom ne résout vraiment pas.
                        if ! getent hosts "${AK_DOMAIN}" >/dev/null 2>&1; then
                            echo "  → ${AK_DOMAIN} ne résout pas : détournement vers Traefik (${TRAEFIK_IP})"
                            awk -v domain="${AK_DOMAIN}" -v ip="${TRAEFIK_IP}" '
/^  nextcloud:$/ { in_nc=1 }
/^  [a-z]/ && !/^  nextcloud:$/ { in_nc=0 }
in_nc && /^    env_file:/ && !eh_done {
    print "    extra_hosts:"
    print "      - \"" domain ":" ip "\""
    eh_done=1
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/nc_compose_eh.yml && \
                            mv /tmp/nc_compose_eh.yml "${CALEOPE_APP_DIR}/compose.yml" || true
                        else
                            echo "  → ${AK_DOMAIN} résout normalement : pas de détournement (le proxy fait le travail)"
                        fi
                    fi

                    cat >> "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env" << OIDCENV
NC_OIDC_CLIENT_ID=${NC_OIDC_CLIENT_ID}
NC_OIDC_CLIENT_SECRET=${NC_OIDC_CLIENT_SECRET}
NC_OIDC_DISCOVERY_URI=${NC_OIDC_DISCOVERY_URI}
OIDCENV
                    echo "  ✓ Nextcloud OIDC configuré dans Authentik (PK=${PROV_PK})"
                else
                    echo "  ⚠ Erreur création provider OIDC Nextcloud"
                fi
            else
                echo "  ⚠ Flows Authentik introuvables"
            fi
        fi
    fi
fi
# Filet SSO : si aucune des branches ci-dessus n'a écrit les clés OIDC (Authentik
# arrêté, API muette, flows introuvables...), on restaure celles qui étaient déjà
# en place plutôt que de laisser secrets.env amputé. Sans ça, une simple
# réinstallation pendant qu'Authentik est down suffit à faire disparaître le SSO.
if ! grep -q "^NC_OIDC_CLIENT_ID=" "${_SECRETS}" 2>/dev/null && [ -n "${PREV_OIDC_CLIENT_ID}" ]; then
    cat >> "${_SECRETS}" << OIDCKEEP
NC_OIDC_CLIENT_ID=${PREV_OIDC_CLIENT_ID}
NC_OIDC_CLIENT_SECRET=${PREV_OIDC_CLIENT_SECRET}
NC_OIDC_DISCOVERY_URI=${PREV_OIDC_DISCOVERY_URI}
OIDCKEEP
    echo "  ↺ SSO : identifiants OIDC précédents conservés (Authentik injoignable)"
fi

echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${CALEOPE_BASE_DIR}/app-config/nextcloud/secrets.env"

# Script de configuration automatique du connecteur OnlyOffice
# Exécuté par le container nextcloud-bootstrap après démarrage de la stack
cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/bootstrap.sh" << 'BOOTSTRAP'
#!/bin/bash
set -e

occ() { su -s /bin/bash www-data -c "php /var/www/html/occ $*"; }

# Les attentes sont PLAFONNÉES. Une boucle `until` sans compteur laisse le
# conteneur de bootstrap tourner indéfiniment si le service ne vient jamais :
# l'installation semble « en cours » pour toujours, et personne ne sait pourquoi.
echo "→ En attente de Nextcloud..."
NC_PRET=0
for _ in $(seq 1 60); do   # 60 × 5 s = 5 min
    if curl -sf "http://nextcloud/status.php" 2>/dev/null | grep -q '"installed":true'; then
        NC_PRET=1
        break
    fi
    sleep 5
done
if [ "${NC_PRET}" != 1 ]; then
    echo "✗ Nextcloud n'est toujours pas initialisé après 5 minutes — bootstrap abandonné."
    echo "  Diagnostic : docker logs nextcloud"
    exit 1
fi

echo "→ En attente du serveur de documents..."
DS_PRET=0
for _ in $(seq 1 60); do
    if curl -sf "http://nextcloud-onlyoffice/healthcheck" 2>/dev/null | grep -q "true"; then
        DS_PRET=1
        break
    fi
    sleep 5
done
if [ "${DS_PRET}" != 1 ]; then
    echo "⚠ Serveur de documents injoignable après 5 minutes."
    echo "  On continue quand même : le reste de la configuration Nextcloud"
    echo "  (proxys de confiance, SSO) ne doit pas être perdu pour autant."
    echo "  Diagnostic : docker logs nextcloud-onlyoffice"
fi

# ⚠️ Cette étape ne doit JAMAIS tuer le bootstrap. Le connecteur n'est pas
# embarqué dans l'image Nextcloud : `app:install` le TÉLÉCHARGE depuis
# apps.nextcloud.com. Sur une machine hors ligne (ISO, air-gap, coupure), la
# commande échoue — et avec `set -e` elle emportait TOUT ce qui suit : URLs du
# serveur de documents, secret JWT, proxys de confiance, SSO. Sans un mot.
echo "→ Installation du connecteur OnlyOffice..."
CONNECTEUR_OK=0
if occ "app:enable onlyoffice" > /dev/null 2>&1; then
    CONNECTEUR_OK=1            # déjà présent — app:enable est idempotent
elif occ "app:install onlyoffice" > /dev/null 2>&1; then
    CONNECTEUR_OK=1            # téléchargé puis activé par app:install
fi

if [ "${CONNECTEUR_OK}" = 1 ]; then
    echo "→ Configuration du connecteur OnlyOffice..."
    occ "config:app:set onlyoffice DocumentServerUrl         --value='https://${ONLYOFFICE_DOMAIN}/'"
    occ "config:app:set onlyoffice DocumentServerInternalUrl --value='http://nextcloud-onlyoffice/'"
    occ "config:app:set onlyoffice StorageUrl                --value='http://nextcloud/'"
    occ "config:app:set onlyoffice jwt_secret                --value='${JWT_SECRET}'"
    occ "config:app:set onlyoffice jwt_header                --value='Authorization'"
    # Contrôle explicite : on relit ce qui a été écrit plutôt que de supposer.
    echo "✓ OnlyOffice connecté à Nextcloud (serveur : $(occ "config:app:get onlyoffice DocumentServerUrl" 2>/dev/null))"
else
    echo "✗ Le connecteur OnlyOffice n'a pas pu être installé."
    echo "  Il se télécharge depuis apps.nextcloud.com : sans accès Internet, c'est attendu."
    echo "  L'édition de documents restera indisponible tant qu'il manque."
    echo "  Une fois la machine en ligne :"
    echo "    docker exec -u www-data nextcloud php occ app:install onlyoffice"
    echo "    caleope install nextcloud --force"
fi

# Autoriser les requêtes vers les IPs internes Docker (protection SSRF désactivée
# pour les serveurs internes — nécessaire pour joindre authentik-server:9000)
occ "config:system:set allow_local_remote_servers --value=true --type=boolean"

# Trusted proxies — Caleope proxy accède Nextcloud depuis le réseau caleope-internal
occ "config:system:set trusted_proxies 0 --value=172.18.0.0/16"
occ "config:system:set trusted_proxies 1 --value=172.19.0.0/16"
occ "config:system:set overwriteprotocol --value=https"

# user_oidc utilise Guzzle (HTTP client interne Nextcloud) avec son propre bundle CA,
# différent de /etc/ssl/certs. Sans cette option, le JWKS fetch échoue silencieusement
# quand Traefik présente un certificat auto-signé → "Invalid JWKS: missing 'keys' array"
occ "config:system:set user_oidc httpclient.allowselfsigned --value=true --type=boolean"

# SSO OIDC — configuré seulement si Authentik a fourni les credentials
if [ -n "${NC_OIDC_CLIENT_ID:-}" ] && [ -n "${NC_OIDC_CLIENT_SECRET:-}" ] && [ -n "${NC_OIDC_DISCOVERY_URI:-}" ]; then
    echo "→ Configuration SSO OIDC (user_oidc)..."
    # Activer l'app avant de configurer le provider
    occ "app:enable user_oidc" 2>/dev/null || occ "app:install user_oidc"
    occ "user_oidc:provider Authentik \
        --clientid=${NC_OIDC_CLIENT_ID} \
        --clientsecret=${NC_OIDC_CLIENT_SECRET} \
        --discoveryuri=${NC_OIDC_DISCOVERY_URI} \
        --mapping-uid=sub \
        --check-bearer=0 \
        --unique-uid=0"
    echo "✓ SSO Authentik configuré dans Nextcloud"
fi
BOOTSTRAP
chmod +x "${CALEOPE_BASE_DIR}/app-config/nextcloud/bootstrap.sh"

cat > "${CALEOPE_BASE_DIR}/app-config/nextcloud/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────┐
  │          Nextcloud + OnlyOffice — Premiers accès             │
  ├──────────────────────────────────────────────────────────────┤
  │  ⏳  Nextcloud initialise sa base de données (3-5 min).      │
  │  ⏳  OnlyOffice démarre ensuite (2-3 min supplémentaires).   │
  │  ⏳  Le connecteur se configure automatiquement.             │
  │                                                              │
  │  Identifiants Nextcloud :                                    │
  │    Login    : user-caleope                                   │
  │    Password : ${ADMIN_PASS}                          │
  │                                                              │
  │  OnlyOffice accessible sur :                                 │
  │    https://${ONLYOFFICE_DOMAIN}                              │
  │  (ajoute ce domaine dans NPM comme les autres)               │
  │                                                              │
  │  Secrets dans : app-config/nextcloud/secrets.env             │
  └──────────────────────────────────────────────────────────────┘
EOF

echo "✓ Dossiers, secrets et bootstrap créés"
