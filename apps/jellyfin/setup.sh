#!/bin/bash
set -euo pipefail
echo "→ Préparation de Jellyfin..."
mkdir -p "${CALEOPE_BASE_DIR}/app-data/jellyfin/"{config,cache,media}
echo "✓ Dossiers créés"
