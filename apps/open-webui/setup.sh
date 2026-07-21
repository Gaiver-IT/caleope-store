#!/bin/bash
# setup.sh — Open WebUI (façade LLM pour Ollama)
set -euo pipefail
echo "→ Préparation d'Open WebUI..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
_SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/data"

# ── Clé de session idempotente ───────────────────────────────────────────────
WEBUI_KEY=""
if [ -f "${_SECRETS}" ]; then
    WEBUI_KEY=$(grep "^WEBUI_SECRET_KEY=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
[ -z "${WEBUI_KEY}" ] && WEBUI_KEY=$(openssl rand -hex 32)

# OLLAMA_BASE_URL : le backend Ollama sur le réseau interne Caleope.
# Si Ollama n'est pas installé, l'utilisateur pourra régler une autre source dans l'UI.
cat > "${_SECRETS}" <<ENV
WEBUI_SECRET_KEY=${WEBUI_KEY}
OLLAMA_BASE_URL=http://ollama:11434
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │            Open WebUI — Interface de chat pour LLM               │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │  Le PREMIER compte créé devient administrateur.                 │
  │                                                                  │
  │  Backend LLM : Ollama (http://ollama:11434).                    │
  │  ⚠ Installer aussi l'app « Ollama » (ou via le Pack IA privée). │
  │  Puis Réglages → Modèles → télécharger un modèle.               │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Open WebUI configuré — https://${CALEOPE_DOMAIN}/"
