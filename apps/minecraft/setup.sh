#!/bin/bash
# setup.sh — Minecraft (serveur de jeu)
set -euo pipefail
echo "→ Préparation du serveur Minecraft..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
# ⚠️ Les données suivent l'INSTANCE, pas le nom du paquet : « minecraft » et
# « minecraft@homestead » doivent avoir deux mondes distincts. Utiliser le nom
# du paquet ici ferait écrire les deux serveurs au même endroit.
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/data"

# ── Le contrat de licence ───────────────────────────────────────────────────
# Mojang exige une acceptation explicite. On REFUSE de la cocher à la place de
# l'utilisateur : accepter un contrat en son nom n'est pas un service à lui
# rendre. Sans elle, on s'arrête ici avec un message clair plutôt que de laisser
# le conteneur repartir en boucle en écrivant « you need to agree to the EULA ».
_EULA="${CALEOPE_PARAM_MC_EULA:-false}"
if [ "${_EULA}" != "true" ] && [ "${_EULA}" != "TRUE" ] && [ "${_EULA}" != "1" ]; then
    echo "✗ Le contrat de licence Minecraft (EULA) n'a pas été accepté." >&2
    echo "  Le serveur ne peut pas démarrer sans — c'est une exigence de Mojang." >&2
    echo "  Coche « Accepter le contrat de licence Mojang » et relance l'installation." >&2
    echo "  Texte du contrat : https://aka.ms/MinecraftEULA" >&2
    exit 1
fi

# ── Préservation des secrets ────────────────────────────────────────────────
# Une montée de version repasse par ce script : réengendrer le mot de passe RCON
# couperait la console de l'interface sans prévenir.
_SECRETS="${CONFIG_DIR}/secrets.env"
_garde() { # $1 = clé TELLE QU'ÉCRITE dans secrets.env, $2 = commande d'engendrement
    local cur=""
    [ -f "${_SECRETS}" ] && cur=$(grep -m1 "^$1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "${cur}" ]; then printf '%s' "${cur}"; else eval "$2"; fi
}
RCON_PASS=$(_garde RCON_PASSWORD "openssl rand -hex 16")

# ── Configuration du serveur ────────────────────────────────────────────────
# ⚠️ TOUT passe par secrets.env, et surtout PAS par app.env : le daemon
# RECONSTRUIT app.env après setup.sh (étape 7.5), donc ce qu'on y ajoute ici
# disparaît avant le démarrage. Mesuré : le conteneur recevait « EULA= » vide et
# « TYPE=VANILLA », puis repartait en boucle en réclamant l'acceptation du
# contrat qu'on venait pourtant de cocher.
#
# On n'écrit pas non plus server.properties nous-mêmes : l'image l'engendre à
# partir de ces variables, et le réécrire ferait disparaître au démarrage
# suivant les réglages faits depuis l'interface.
TYPE="${CALEOPE_PARAM_MC_TYPE:-PAPER}"
VERSION="${CALEOPE_PARAM_MC_VERSION:-LATEST}"
MEMOIRE="${CALEOPE_PARAM_MC_MEMOIRE:-2G}"
MODRINTH="${CALEOPE_PARAM_MC_MODRINTH:-}"
OPS="${CALEOPE_PARAM_MC_OPS:-}"

{
    echo "# Console d'administration (RCON) — utilisée par l'interface Caleope."
    echo "RCON_PASSWORD=${RCON_PASS}"
    echo "ENABLE_RCON=true"
    echo "RCON_PORT=25575"
    echo ""
    echo "# Moteur et version"
    echo "EULA=TRUE"
    echo "TYPE=${TYPE}"
    echo "VERSION=${VERSION}"
    echo "MEMORY=${MEMOIRE}"
    echo "TZ=${TZ:-Europe/Paris}"
    # Sans ça, une mise à jour de mod laisse l'ancienne version à côté de la
    # nouvelle : le serveur charge les deux et refuse de démarrer.
    echo "REMOVE_OLD_MODS=true"
    [ -n "${MODRINTH}" ] && echo "MODRINTH_PROJECTS=${MODRINTH}"
    [ -n "${OPS}" ] && echo "OPS=${OPS}"
    [ -n "${CALEOPE_PARAM_MC_CURSEFORGE_KEY:-}" ] && echo "CF_API_KEY=${CALEOPE_PARAM_MC_CURSEFORGE_KEY}"
} > "${_SECRETS}"
chmod 600 "${_SECRETS}"

# ── Variante Java ───────────────────────────────────────────────────────────
# Le compose épingle java25. Si l'utilisateur a besoin d'une variante plus
# ancienne pour un vieux serveur, on patche l'image engendrée.
_JAVA="${CALEOPE_PARAM_MC_JAVA:-25}"
if [ "${_JAVA}" != "25" ] && [ -f "${CALEOPE_APP_DIR}/compose.yml" ]; then
    sed -i "s|itzg/minecraft-server:java25|itzg/minecraft-server:java${_JAVA}|" "${CALEOPE_APP_DIR}/compose.yml"
    echo "  ✓ Variante Java ${_JAVA}"
fi

# ── Port du jeu ─────────────────────────────────────────────────────────────
# Il est écrit en dur dans le compose (25565, celui que tout le monde connaît).
# Si l'utilisateur en a choisi un autre, on patche le compose engendré — le
# daemon nous laisse volontairement le modifier avant le démarrage.
_PORT="${CALEOPE_PARAM_MC_PORT:-25565}"
if [ "${_PORT}" != "25565" ] && [ -f "${CALEOPE_APP_DIR}/compose.yml" ]; then
    sed -i "s|\"25565:25565/tcp\"|\"${_PORT}:25565/tcp\"|" "${CALEOPE_APP_DIR}/compose.yml"
    echo "  ✓ Port du jeu : ${_PORT}"
fi

echo "  ✓ Serveur ${TYPE} ${VERSION}, ${MEMOIRE} de mémoire."
[ -n "${MODRINTH}" ] && echo "  ✓ Mods Modrinth demandés : ${MODRINTH}"
echo "  ℹ Le premier démarrage télécharge le moteur et engendre le monde :"
echo "    compte plusieurs minutes avant que le serveur réponde."
