#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/linkding"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/linkding/data"

LINKDING_ADMIN_USER=""
LINKDING_ADMIN_PASS=""
if [ -f "${_SECRETS}" ]; then
    LINKDING_ADMIN_USER=$(grep "^LINKDING_ADMIN_USER=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
    LINKDING_ADMIN_PASS=$(grep "^LINKDING_ADMIN_PASS=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

[ -n "${CALEOPE_PARAM_LINKDING_ADMIN_USER:-}" ] && LINKDING_ADMIN_USER="${CALEOPE_PARAM_LINKDING_ADMIN_USER}"
[ -n "${CALEOPE_PARAM_LINKDING_ADMIN_PASS:-}" ] && LINKDING_ADMIN_PASS="${CALEOPE_PARAM_LINKDING_ADMIN_PASS}"
[ -z "${LINKDING_ADMIN_USER}" ] && LINKDING_ADMIN_USER="admin"
[ -z "${LINKDING_ADMIN_PASS}" ] && LINKDING_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Générer un token API pour CaleOpe
LINKDING_API_TOKEN=""
if [ -f "${_SECRETS}" ]; then
    LINKDING_API_TOKEN=$(grep "^LINKDING_API_TOKEN=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || true
fi

cat > "${_SECRETS}" <<ENV
LINKDING_ADMIN_USER=${LINKDING_ADMIN_USER}
LINKDING_ADMIN_PASS=${LINKDING_ADMIN_PASS}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Linkding configuré"

# ── Token API Linkding ────────────────────────────────────────────────────────
if [ -z "${LINKDING_API_TOKEN}" ]; then
    echo ""
    echo "→ Génération token API Linkding..."
    _ld_ready=false
    for _i in $(seq 1 20); do
        if curl -sf --max-time 3 "http://localhost:${CALEOPE_PORT_WEB}/health" >/dev/null 2>&1; then
            _ld_ready=true; break
        fi
        sleep 3
    done

    if ${_ld_ready}; then
        # linkding 1.31+ utilise bookmarks_apitoken (pas DRF authtoken)
        _token=$(docker exec linkding python manage.py shell -c "
import binascii, os
from django.db import connection
from django.contrib.auth.models import User
from django.utils import timezone
u = User.objects.get(username='${LINKDING_ADMIN_USER}')
rows = connection.cursor().execute('SELECT key FROM bookmarks_apitoken WHERE user_id=?', [u.id]).fetchall()
if rows:
    print(rows[0][0])
else:
    key = binascii.hexlify(os.urandom(20)).decode()
    with connection.cursor() as c:
        c.execute('INSERT INTO bookmarks_apitoken (key, name, created, user_id) VALUES (?,?,?,?)',
                  [key, 'caleope', timezone.now().isoformat(), u.id])
    print(key)
" 2>/dev/null | tail -1) || _token=""

        if [ -n "${_token}" ]; then
            sed -i '/^LINKDING_API_TOKEN/d' "${_SECRETS}"
            echo "LINKDING_API_TOKEN=${_token}" >> "${_SECRETS}"
            echo "  ✓ Token API Linkding généré"
        else
            echo "  ⚠ Token API non obtenu (générer manuellement dans Paramètres > Intégrations)"
        fi
    fi
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Linkding — Gestionnaire de marque-pages            │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface  : https://${CALEOPE_DOMAIN}/                         │
  │  Utilisateur: ${LINKDING_ADMIN_USER}                             │
  │  Mot de passe: ${LINKDING_ADMIN_PASS}                            │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Linkding prêt — https://${CALEOPE_DOMAIN}/"
