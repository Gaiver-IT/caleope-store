#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/changedetection"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/changedetection/data"

cat > "${_SECRETS}" <<ENV
BASE_URL=https://${CALEOPE_DOMAIN}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Changedetection.io configuré"

# ── Token API ChangeDetection ─────────────────────────────────────────────────
CHANGEDETECTION_API_TOKEN=""
if [ -f "${_SECRETS}" ]; then
    CHANGEDETECTION_API_TOKEN=$(grep "^CHANGEDETECTION_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi
if [ -z "${CHANGEDETECTION_API_TOKEN}" ]; then
    _data_file="${CALEOPE_BASE_DIR}/app-data/changedetection/data/changedetection.json"
    _cd_ready=false
    for _i in $(seq 1 20); do
        if [ -f "${_data_file}" ]; then _cd_ready=true; break; fi
        sleep 3
    done
    if ${_cd_ready}; then
        _token=$(python3 -c "
import json
with open('${_data_file}') as f:
    d = json.load(f)
print(d.get('settings',{}).get('application',{}).get('api_access_token',''))
" 2>/dev/null) || _token=""
        if [ -n "${_token}" ]; then
            echo "CHANGEDETECTION_API_TOKEN=${_token}" >> "${_SECRETS}"
            echo "  ✓ Token API ChangeDetection extrait"
        fi
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │           Changedetection.io — Surveillance de pages web         │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │                                                                  │
  │  Aucun compte requis — accès direct à l'interface.               │
  │  Configurer un mot de passe dans Settings > Security             │
  │  si nécessaire.                                                  │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Changedetection.io prêt — https://${CALEOPE_DOMAIN}/"
