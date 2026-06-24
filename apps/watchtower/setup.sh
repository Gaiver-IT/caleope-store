#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_APP_CONFIG}/watchtower"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"

WATCHTOWER_SCHEDULE=""
WATCHTOWER_CLEANUP=""
WATCHTOWER_INCLUDE_STOPPED=""
if [ -f "${_SECRETS}" ]; then
    WATCHTOWER_SCHEDULE=$(grep "^WATCHTOWER_SCHEDULE=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    WATCHTOWER_CLEANUP=$(grep "^WATCHTOWER_CLEANUP=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    WATCHTOWER_INCLUDE_STOPPED=$(grep "^WATCHTOWER_INCLUDE_STOPPED=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -n "${PARAM_WATCHTOWER_SCHEDULE:-}" ] && WATCHTOWER_SCHEDULE="${PARAM_WATCHTOWER_SCHEDULE}"
[ -n "${PARAM_WATCHTOWER_CLEANUP:-}" ] && WATCHTOWER_CLEANUP="${PARAM_WATCHTOWER_CLEANUP}"
[ -n "${PARAM_WATCHTOWER_INCLUDE_STOPPED:-}" ] && WATCHTOWER_INCLUDE_STOPPED="${PARAM_WATCHTOWER_INCLUDE_STOPPED}"
[ -z "${WATCHTOWER_SCHEDULE}" ] && WATCHTOWER_SCHEDULE="0 0 4 * * *"
[ -z "${WATCHTOWER_CLEANUP}" ] && WATCHTOWER_CLEANUP="true"
[ -z "${WATCHTOWER_INCLUDE_STOPPED}" ] && WATCHTOWER_INCLUDE_STOPPED="false"

cat > "${_SECRETS}" <<ENV
WATCHTOWER_SCHEDULE=${WATCHTOWER_SCHEDULE}
WATCHTOWER_CLEANUP=${WATCHTOWER_CLEANUP}
WATCHTOWER_INCLUDE_STOPPED=${WATCHTOWER_INCLUDE_STOPPED}
WATCHTOWER_NO_STARTUP_MESSAGE=true
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
Watchtower est démarré en mode planifié.
Cron : ${WATCHTOWER_SCHEDULE}
Nettoyage images : ${WATCHTOWER_CLEANUP}

Watchtower vérifie et met à jour automatiquement tous les conteneurs.
Aucune interface web — consultez les logs pour voir les mises à jour.
INFO

echo "✓ Watchtower configuré — vérification planifiée : ${WATCHTOWER_SCHEDULE}"
