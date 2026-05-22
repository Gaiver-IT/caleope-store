#!/bin/bash
set -euo pipefail
echo "→ Préparation de Nextcloud..."
mkdir -p "${CALEOPE_BASE_DIR}/app-data/nextcloud/"{html,db,redis}
echo "✓ Dossiers créés"
