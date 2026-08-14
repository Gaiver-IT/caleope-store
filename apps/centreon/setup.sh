#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"/{etc,etc-engine,etc-broker,etc-gorgone}
mkdir -p "${DATA_DIR}"/{db,lib,broker,engine}

# ── Mots de passe ───────────────────────────────────────────────────────────
# ⚠️ ORDRE DE PRIORITÉ : paramètre fourni > valeur DÉJÀ EN PLACE > engendré.
# `caleope install --force` rejoue ce script SANS redemander les paramètres.
# Écrire `CENTREON_ADMIN_PASSWORD=${CALEOPE_PARAM_...:-}` sans garde effacerait
# le mot de passe à chaque mise à jour d'image — et ici le dégât est pire
# qu'ailleurs : la base garde l'ancien, plus personne ne peut se connecter.
SECRETS="${CONFIG_DIR}/secrets.env"
_prev() { [ -f "${SECRETS}" ] && grep -m1 "^$1=" "${SECRETS}" 2>/dev/null | cut -d= -f2- || true; }

# Centreon exige 12 caractères minimum avec majuscule, minuscule, chiffre et
# caractère spécial.
#
# ⚠️ « SPÉCIAL » A UN SENS TRÈS PRÉCIS ICI, et se tromper coûte cher. Le produit
# n'accepte que ces sept caractères, en dur dans son code :
#     SecurityPolicy::SPECIAL_CHARACTERS_LIST = '@$!%*?&'
# Un mot de passe avec un tiret ou un point de plus n'a, pour Centreon, AUCUN
# caractère spécial. L'étape 5 du formulaire le refuse — et rend quand même un
# HTTP 200. Le compte admin est alors créé avec un mot de passe VIDE (constaté :
# `length(password) = 0` en base) et personne ne peut se connecter.
#
# Sur ces sept, on écarte & % ? : le mot de passe transite dans un corps
# « application/x-www-form-urlencoded », où ils seraient interprétés et
# tronqueraient la valeur en silence. Reste @ $ ! * — l'intersection de ce que
# Centreon accepte et de ce qui traverse une requête de formulaire intact.
#
# Le premier jet tirait dans « !@$*_.:- » : quatre caractères sur huit étaient
# invalides, soit une installation sur deux qui échouait au hasard du tirage.
_engendrer() {
    local base spec
    base=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)
    spec=$(head -c 32 /dev/urandom | tr -dc '@$!*' | head -c 1)
    [ -z "${spec}" ] && spec='!'
    echo "Ca${base}${spec}7"
}

_keep() { # $1=clé  $2=paramètre fourni  $3=1 pour engendrer si vide
    local cur; cur="$(_prev "$1")"
    if   [ -n "${2:-}" ];  then echo "$1=$2"
    elif [ -n "${cur}" ];  then echo "$1=${cur}"
    elif [ "${3:-0}" = 1 ]; then echo "$1=$(_engendrer)"
    else                        echo "$1="
    fi
}

{
    _keep CENTREON_ADMIN_PASSWORD   "${CALEOPE_PARAM_CENTREON_ADMIN_PASSWORD:-}"   1
    _keep CENTREON_DB_ROOT_PASSWORD "${CALEOPE_PARAM_CENTREON_DB_ROOT_PASSWORD:-}" 1
    _keep CENTREON_DB_PASSWORD      "${CALEOPE_PARAM_CENTREON_DB_PASSWORD:-}"      1
    _keep CENTREON_ADMIN_EMAIL      "${CALEOPE_PARAM_CENTREON_ADMIN_EMAIL:-}"      0
    echo "CENTREON_DB_HOST=centreon-db"
    echo "CENTREON_DB_PORT=3306"
    # Le login et l'URL vivent ICI, à côté du mot de passe, parce que c'est là
    # que la section « Secrets » de l'interface va les chercher. Publier la
    # moitié d'un couple ne sert à personne : on voit CENTREON_ADMIN_PASSWORD
    # sans jamais voir « admin », et on croit que l'information manque.
    # C'est la convention majoritaire du magasin (16 paquets sur 25 le font).
    echo "CENTREON_ADMIN_USER=admin"
    [ -n "${CALEOPE_DOMAIN:-}" ] && echo "CENTREON_URL=https://${CALEOPE_DOMAIN}"
} > "${SECRETS}.new"

# MariaDB lit d'autres noms de variables que Centreon, mais il s'agit du même
# secret : on le recopie plutôt que d'entretenir deux fichiers qui divergeront.
ROOT_PW=$(grep '^CENTREON_DB_ROOT_PASSWORD=' "${SECRETS}.new" | cut -d= -f2-)
{
    echo "MARIADB_ROOT_PASSWORD=${ROOT_PW}"
    echo "MARIADB_ROOT_HOST=%"
    echo "MARIADB_AUTO_UPGRADE=1"
} >> "${SECRETS}.new"

grep -q '^CENTREON_ADMIN_EMAIL=..*' "${SECRETS}.new" || \
    sed -i 's|^CENTREON_ADMIN_EMAIL=$|CENTREON_ADMIN_EMAIL=admin@localhost|' "${SECRETS}.new"

mv -f "${SECRETS}.new" "${SECRETS}"
chmod 600 "${SECRETS}"

# ── Image Centreon ──────────────────────────────────────────────────────────
# Centreon ne publie AUCUNE image Docker officielle. Les images tierces
# disponibles sur Docker Hub sont des travaux personnels sans mainteneur (l'une
# d'elles est un environnement de démonstration de faille). Caleope installe
# chez ses utilisateurs avec les droits root : on ne fait pas confiance à ça.
# L'image est donc construite ici, depuis les dépôts APT officiels de l'éditeur.
#
# ⚠️ Ne JAMAIS retomber en silence sur une image tierce si la construction rate.
# Un échec bruyant vaut mieux qu'une supervision qui ment.
IMAGE="caleope-centreon:24.10"
APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/image"

if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
    echo "  ✓ Image déjà présente : ${IMAGE}"
elif [ -f "${APP_SRC}/Dockerfile" ]; then
    echo "  ⏳ Construction de l'image Centreon depuis les dépôts officiels"
    echo "     (2 à 3 min, ~1,6 Go — une seule fois)..."
    if docker build -t "${IMAGE}" "${APP_SRC}" > "${CONFIG_DIR}/build.log" 2>&1; then
        echo "  ✓ Image construite : ${IMAGE}"
    else
        echo "  ✗ Construction ÉCHOUÉE."
        echo "    Journal : ${CONFIG_DIR}/build.log"
        echo "    Cause la plus fréquente : packages.centreon.com injoignable."
        echo "    Relancer à la main : docker build -t ${IMAGE} ${APP_SRC}"
        exit 1
    fi
else
    echo "  ✗ Dockerfile introuvable dans ${APP_SRC}."
    echo "    Le paquet est incomplet : lance 'caleope update' puis réessaie."
    exit 1
fi

# ── Amorçage des dossiers montés ────────────────────────────────────────────
# ⚠️ LE PIÈGE QUI A COÛTÉ UN ESSAI COMPLET. Les six dossiers persistés ne sont
# pas vides dans l'image : /etc/centreon en contient 7 entrées, /var/lib/centreon
# 9, et ainsi de suite. Monter un dossier hôte vide par-dessus MASQUE ce contenu.
# Résultat mesuré le 12/08/2026 : l'installation déroule ses étapes normalement
# jusqu'à insertBaseConf.php, qui rend un HTTP 500 — sans que rien n'indique que
# la cause est un dossier masqué.
#
# On recopie donc ce que l'image apporte, une seule fois, dans les dossiers
# encore vides. Un dossier déjà peuplé n'est jamais touché : c'est ce qui rend
# l'opération rejouable sans écraser les données de l'utilisateur.
_semer() { # $1 = chemin dans l'image, $2 = dossier hôte
    if [ -n "$(ls -A "$2" 2>/dev/null)" ]; then
        echo "    · $2 déjà peuplé, laissé tel quel"
        return 0
    fi
    if docker run --rm -v "$2:/cible" --entrypoint sh "${IMAGE}" \
         -c "cp -a $1/. /cible/" > /dev/null 2>&1; then
        echo "    · $2 amorcé depuis l'image ($(ls -A "$2" | wc -l) entrées)"
    else
        echo "  ✗ Amorçage de $2 impossible depuis ${IMAGE}."
        echo "    Sans ce contenu, l'installation échouera à insertBaseConf.php."
        exit 1
    fi
}

echo "  ⏳ Amorçage des dossiers de configuration"
_semer /etc/centreon            "${CONFIG_DIR}/etc"
_semer /etc/centreon-engine     "${CONFIG_DIR}/etc-engine"
_semer /etc/centreon-broker     "${CONFIG_DIR}/etc-broker"
_semer /etc/centreon-gorgone    "${CONFIG_DIR}/etc-gorgone"
_semer /var/lib/centreon        "${DATA_DIR}/lib"
_semer /var/lib/centreon-engine "${DATA_DIR}/engine"
_semer /var/lib/centreon-broker "${DATA_DIR}/broker"

ADMIN_PW=$(_prev CENTREON_ADMIN_PASSWORD)
ADRESSE="https://${CALEOPE_DOMAIN:-<domaine-non-defini>}"

# ⚠️ Pas de bordure à droite sur les lignes à contenu variable. Un cadre en
# largeur fixe se casse dès qu'on y glisse un mot de passe ou un chemin — et un
# encadré cassé, c'est le premier signe que personne n'a relu la sortie.
cat > "${CONFIG_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────┐
  │  Centreon — supervision                                      │
  └──────────────────────────────────────────────────────────────┘

  Interface     : ${ADRESSE}
  Identifiant   : admin
  Mot de passe  : ${ADMIN_PW}

  L'installation se termine SEULE dans le conteneur, environ 30 s après
  le démarrage. La suivre avec :  caleope logs centreon
  La ligne « ✅ Centreon installé, vérifié, supervision armée » signe la fin.

  Le serveur central est déjà créé et supervisé : la page Supervision ▸ Hôtes
  n'est pas vide au premier accès. Les autres machines s'ajoutent depuis
  Configuration ▸ Hôtes, puis « Exporter la configuration ».

  ⚠️ Une Centreon neuve n'a AUCUNE commande de contrôle applicative définie,
  alors que les 50 sondes Nagios sont bien présentes sur le disque. Pour en
  raccorder : Configuration ▸ Modèles.

  Ces identifiants restent consultables à tout moment :
    · bouton NOTES sur la carte Centreon de l'interface Caleope
    · section « Secrets » de l'interface (CENTREON_ADMIN_USER / _PASSWORD)
    · ${CONFIG_DIR}/secrets.env
EOF
chmod 600 "${CONFIG_DIR}/post-install.txt"

echo "✓ Centreon configuré"
