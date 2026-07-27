#!/bin/bash
# setup.sh — XiVO / Wazo (PBX, 19 services) — EXPÉRIMENTAL
set -euo pipefail
echo "→ Préparation de XiVO (Wazo)..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"

# Les fichiers de config (etc/, bin/, certs/, init-db/, wazo-auth-keys/, variables.env)
# sont vendorisés dans le cache du store → on les copie dans app-config.
APP_SRC=$(ls -d "${CALEOPE_BASE_DIR}"/core/cache/*/apps/"${CALEOPE_APP_ID}" 2>/dev/null | head -1)
if [ -z "${APP_SRC}" ] || [ ! -d "${APP_SRC}/vendor" ]; then
    echo "  ❌ fichiers vendorisés introuvables (${APP_SRC}/vendor)"; exit 1
fi
cp -r "${APP_SRC}/vendor/"* "${CONFIG_DIR}/"
chmod -R a+rx "${CONFIG_DIR}/bin" 2>/dev/null || true

# variables.env : fuseau FR + UUID unique (idempotent)
XIVO_UUID=""
[ -f "${CONFIG_DIR}/variables.env" ] && XIVO_UUID=$(grep "^XIVO_UUID=" "${CONFIG_DIR}/variables.env" 2>/dev/null | cut -d= -f2-) || true
# garder l'UUID existant s'il a déjà été personnalisé, sinon en générer un
case "${XIVO_UUID}" in ""|00000000-*) XIVO_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-4000-8000-0000000AA450");; esac
cat > "${CONFIG_DIR}/variables.env" <<ENV
INIT_TIMEOUT=180
TZ=Europe/Paris
XIVO_UUID=${XIVO_UUID}
SQLALCHEMY_WARN_20=1
ENV

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              XiVO (Wazo) — Standard téléphonique IP              │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface admin : https://${CALEOPE_DOMAIN}/                    │
  │  ⚠ EXPÉRIMENTAL (19 services). 1er démarrage long (bootstrap DB).│
  │                                                                  │
  │  Pour que les appels fonctionnent, OUVRIR dans le pare-feu et    │
  │  rediriger sur la box :                                          │
  │    • UDP 5060           (SIP)                                    │
  │    • UDP 19980-20000    (RTP / flux audio)                       │
  │  (Caleope ouvre 5060 ; la plage RTP est à ouvrir à la main.)    │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ XiVO (Wazo) configuré — bootstrap au 1er démarrage (patience)"
