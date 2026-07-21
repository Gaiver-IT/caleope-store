#!/bin/bash
# setup.sh — Ollama (runtime LLM local, backend interne)
set -euo pipefail
echo "→ Préparation d'Ollama..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}/models"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │           Ollama — Moteur LLM local (backend interne)           │
  ├──────────────────────────────────────────────────────────────────┤
  │  Pas d'interface web propre : joignable en interne à            │
  │    http://ollama:11434  (utilisé par Open WebUI)                │
  │                                                                  │
  │  Télécharger un modèle :                                        │
  │    docker exec ollama ollama pull llama3.2                       │
  │  ou via l'interface Open WebUI (Réglages → Modèles).            │
  │                                                                  │
  │  ⚠ CPU par défaut (lent). GPU = configuration hôte séparée.     │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Ollama configuré — backend interne http://ollama:11434"
