#!/bin/bash
set -euo pipefail

# ── Hermes Agent — Agent IA autonome ─────────────────────────────────────────
# Prépare la configuration générique (fournisseur, endpoint API, modèle et
# gestion du contexte), génère une clé SSH dédiée si absente, et initialise
# l'espace de travail persistant.

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/hermes"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/hermes/data"
SSH_DIR="${CALEOPE_BASE_DIR}/app-data/hermes/ssh"
WORKSPACE_DIR="${CALEOPE_BASE_DIR}/app-data/hermes/workspace"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${SSH_DIR}" "${WORKSPACE_DIR}"
DOMAIN="${CALEOPE_DOMAIN:-localhost}"

# ── Motif « param > existant > défaut » ───────────────────────────────────────
get_existing() {
  local key="$1"
  if [ -f "${_SECRETS}" ]; then
    grep -E "^${key}=" "${_SECRETS}" | head -n 1 | cut -d'=' -f2- || true
  fi
}

EXISTING_PROVIDER=$(get_existing "LLM_PROVIDER")
EXISTING_URL=$(get_existing "OPENAI_BASE_URL")
EXISTING_KEY=$(get_existing "OPENAI_API_KEY")
EXISTING_MODEL=$(get_existing "HERMES_MODEL")
EXISTING_COMP=$(get_existing "HERMES_CONTEXT_COMPRESSION")
EXISTING_THRESH=$(get_existing "HERMES_COMPRESSION_THRESHOLD")

FINAL_PROVIDER="${HERMES_LLM_PROVIDER:-${EXISTING_PROVIDER:-openai}}"
FINAL_URL="${HERMES_OPENAI_BASE_URL:-${EXISTING_URL:-https://api.openai.com/v1}}"
FINAL_KEY="${HERMES_OPENAI_API_KEY:-${EXISTING_KEY:-}}"
FINAL_MODEL="${HERMES_DEFAULT_MODEL:-${EXISTING_MODEL:-gpt-4o-mini}}"
FINAL_COMP="${HERMES_CONTEXT_COMPRESSION:-${EXISTING_COMP:-true}}"
FINAL_THRESH="${HERMES_COMPRESSION_THRESHOLD:-${EXISTING_THRESH:-0.65}}"

cat > "${_SECRETS}" <<ENV
TZ=Europe/Paris
LLM_PROVIDER=${FINAL_PROVIDER}
OPENAI_BASE_URL=${FINAL_URL}
OPENAI_API_KEY=${FINAL_KEY}
HERMES_MODEL=${FINAL_MODEL}
HERMES_CONTEXT_COMPRESSION=${FINAL_COMP}
HERMES_COMPRESSION_THRESHOLD=${FINAL_THRESH}
ENV
chmod 600 "${_SECRETS}"

# ── Clé SSH dédiée (générée uniquement si absente) ──────────────────────────
chmod 700 "${SSH_DIR}"
if [ ! -f "${SSH_DIR}/id_ed25519" ]; then
  ssh-keygen -t ed25519 -f "${SSH_DIR}/id_ed25519" -N "" -C "hermes-agent@${DOMAIN}" >/dev/null
  chmod 600 "${SSH_DIR}/id_ed25519"
  chmod 644 "${SSH_DIR}/id_ed25519.pub"
fi

if [ ! -f "${SSH_DIR}/config" ]; then
  cat > "${SSH_DIR}/config" <<SSHCFG
Host *
    IdentityFile /root/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
SSHCFG
  chmod 600 "${SSH_DIR}/config"
fi

PUB_KEY=$(cat "${SSH_DIR}/id_ed25519.pub")

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                         Hermes Agent                             │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface     : https://${DOMAIN}/
  │  Fournisseur   : ${FINAL_PROVIDER}
  │  Endpoint API  : ${FINAL_URL}
  │  Modèle        : ${FINAL_MODEL}
  │                                                                  │
  │  Clé SSH publique (à ajouter dans ~/.ssh/authorized_keys si      │
  │  vous souhaitez autoriser l'agent à se connecter à vos hôtes) :  │
  │                                                                  │
  │  ${PUB_KEY}
  │                                                                  │
  │  Espace de travail : app-data/hermes/workspace (/workspace)      │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Hermes Agent prêt — https://${DOMAIN}/"