#!/bin/bash
# setup.sh — Woodpecker CI (branché sur Gitea/Forgejo)
set -euo pipefail
echo "→ Préparation de Woodpecker CI..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
_SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/server"

# ── Secret partagé server↔agent (idempotent) ────────────────────────────────
AGENT_SECRET=""
if [ -f "${_SECRETS}" ]; then
    AGENT_SECRET=$(grep "^WOODPECKER_AGENT_SECRET=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${AGENT_SECRET}" ] && AGENT_SECRET=$(openssl rand -hex 32)

# ── Détecter la forge (Gitea puis Forgejo) et créer l'app OAuth ──────────────
# Woodpecker s'authentifie via l'OAuth de la forge. On crée une application
# OAuth2 dans la forge (API, basic auth admin) et on récupère client/secret.
FORGE=""; FORGE_URL=""; OA_CLIENT=""; OA_SECRET=""; ADMIN_USER=""

# Idempotence : si une app OAuth a déjà été créée (réinstall), on la réutilise
# plutôt que d'en créer une orpheline de plus dans la forge.
if [ -f "${_SECRETS}" ]; then
    for g in GITEA FORGEJO; do
        c=$(grep "^WOODPECKER_${g}_CLIENT=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
        s=$(grep "^WOODPECKER_${g}_SECRET=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
        if [ -n "${c}" ] && [ -n "${s}" ]; then
            OA_CLIENT="${c}"; OA_SECRET="${s}"
            FORGE=$(echo "${g}" | tr A-Z a-z)
            FORGE_URL=$(grep "^WOODPECKER_${g}_URL=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
            ADMIN_USER=$(grep "^WOODPECKER_ADMIN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
            echo "  ✓ App OAuth ${FORGE} déjà configurée — réutilisée"
        fi
    done
fi

[ -n "${FORGE}" ] || for f in gitea forgejo; do
    FDIR="${CALEOPE_BASE_DIR}/apps-installed/${f}"
    FSECRETS="${CALEOPE_BASE_DIR}/app-config/${f}/secrets.env"
    [ -d "${FDIR}" ] && [ -f "${FSECRETS}" ] || continue
    FPORT=$(grep "^CALEOPE_PORT_WEB=" "${FDIR}/app.env" 2>/dev/null | cut -d= -f2-)
    FDOMAIN=$(grep "^GITEA__server__DOMAIN=" "${FSECRETS}" 2>/dev/null | cut -d= -f2-)
    AU=$(grep "^GITEA_ADMIN_USER=" "${FSECRETS}" 2>/dev/null | cut -d= -f2-)
    AP=$(grep "^GITEA_ADMIN_PASS=" "${FSECRETS}" 2>/dev/null | cut -d= -f2-)
    [ -n "${FPORT}" ] && [ -n "${AU}" ] && [ -n "${AP}" ] || continue

    echo "  → Forge détectée : ${f} (création de l'app OAuth)..."
    REDIR="https://${CALEOPE_DOMAIN}/authorize"
    RESP=$(curl -s --max-time 15 -u "${AU}:${AP}" \
        -H "Content-Type: application/json" \
        -X POST "http://localhost:${FPORT}/api/v1/user/applications/oauth2" \
        -d "{\"name\":\"Woodpecker CI\",\"redirect_uris\":[\"${REDIR}\"],\"confidential_client\":true}" 2>/dev/null || echo "")
    OA_CLIENT=$(echo "${RESP}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || echo "")
    OA_SECRET=$(echo "${RESP}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('client_secret',''))" 2>/dev/null || echo "")
    if [ -n "${OA_CLIENT}" ] && [ -n "${OA_SECRET}" ]; then
        FORGE="${f}"; ADMIN_USER="${AU}"
        FORGE_URL="https://${FDOMAIN:-${f}.${CALEOPE_DOMAIN#*.}}"
        echo "  ✓ App OAuth créée dans ${f} (client_id=${OA_CLIENT})"
        break
    fi
    echo "  ⚠ Création OAuth ${f} échouée : ${RESP}"
done

if [ -z "${FORGE}" ]; then
    echo "  ⚠ Aucune forge (Gitea/Forgejo) exploitable — installe-la AVANT Woodpecker."
    echo "    Woodpecker démarrera mais l'authentification ne marchera pas sans forge."
fi

# ── secrets.env ──────────────────────────────────────────────────────────────
# WOODPECKER_OPEN=true : autorise l'auto-inscription (1er login = à promouvoir admin).
FORGE_FLAG=""
[ "${FORGE}" = "gitea" ] && FORGE_FLAG="WOODPECKER_GITEA=true"
[ "${FORGE}" = "forgejo" ] && FORGE_FLAG="WOODPECKER_FORGEJO=true"

{
  echo "WOODPECKER_HOST=https://${CALEOPE_DOMAIN}"
  echo "WOODPECKER_OPEN=true"
  echo "WOODPECKER_AGENT_SECRET=${AGENT_SECRET}"
  [ -n "${ADMIN_USER}" ] && echo "WOODPECKER_ADMIN=${ADMIN_USER}"
  if [ -n "${FORGE}" ]; then
    echo "${FORGE_FLAG}"
    echo "WOODPECKER_$(echo "${FORGE}" | tr a-z A-Z)_URL=${FORGE_URL}"
    echo "WOODPECKER_$(echo "${FORGE}" | tr a-z A-Z)_CLIENT=${OA_CLIENT}"
    echo "WOODPECKER_$(echo "${FORGE}" | tr a-z A-Z)_SECRET=${OA_SECRET}"
  fi
} > "${_SECRETS}"
chmod 600 "${_SECRETS}"

# Libellés précalculés (pas de ${x:-...} avec parenthèses/apostrophe dans le
# heredoc : bash le prend pour une substitution mal fermée → échec).
FORGE_LABEL="${FORGE}"
[ -z "${FORGE_LABEL}" ] && FORGE_LABEL="aucune - installe Gitea/Forgejo d abord"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                 Woodpecker CI — Intégration continue            │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │  Forge     : ${FORGE_LABEL}
  │  Connexion : via la forge (OAuth) — 1er compte connecté = admin. │
  │  L'agent exécute les pipelines (accès au socket Docker).        │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Woodpecker CI configuré (forge: ${FORGE:-aucune})"
