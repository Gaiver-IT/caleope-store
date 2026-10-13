#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}"
SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}" "${DATA_DIR}"/{cf,storage}

requested="${CALEOPE_PARAM_PBX_BIND_IP:-}"
if [ -n "${requested}" ]; then
    bind_ip="${requested}"
elif command -v tailscale >/dev/null 2>&1; then
    bind_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
else
    bind_ip=""
fi
if [ -z "${bind_ip}" ]; then
    bind_ip="$(ip -4 -o addr show scope global | awk '$4 ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/{sub(/\/.*/,"",$4); print $4; exit}')"
fi
if ! python3 - "${bind_ip}" <<'PY'
import ipaddress, sys
try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
tailscale = address in ipaddress.ip_network('100.64.0.0/10')
raise SystemExit(0 if address.version == 4 and (address.is_private or tailscale) else 1)
PY
then
    echo "❌ PBX_BIND_IP doit être une adresse Tailscale ou RFC1918 ; exposition Internet refusée en canal alpha." >&2
    exit 1
fi
if ! ip -4 -o addr show | awk '{sub(/\/.*/,"",$4); print $4}' | grep -Fxq -- "${bind_ip}"; then
    echo "❌ PBX_BIND_IP n'est pas configurée sur cet hôte." >&2
    exit 1
fi

admin_password="$(sed -n 's/^WEB_ADMIN_PASSWORD=//p' "${SECRETS}" 2>/dev/null | head -n1 || true)"
if [ -z "${admin_password}" ]; then
    admin_password="$(openssl rand -base64 24 | tr -d '\n')"
    umask 077
    printf 'Utilisateur: admin\nMot de passe initial: %s\n' "${admin_password}" > "${CONFIG_DIR}/initial-admin.txt"
fi

cat > "${SECRETS}" <<ENV
PBX_BIND_IP=${bind_ip}
WEB_ADMIN_PASSWORD=${admin_password}
ENV
chmod 600 "${SECRETS}" "${CONFIG_DIR}/initial-admin.txt" 2>/dev/null || true

cat > "${CONFIG_DIR}/post-install.txt" <<INFO
VoIP PBX (alpha)

Interface privée : https://${bind_ip}:${CALEOPE_PORT_WEB}/
SIP privé         : ${bind_ip}:${CALEOPE_PORT_SIP}/UDP
SIP TLS           : ${bind_ip}:5061/TCP
RTP privé         : ${bind_ip}:20000-20800/UDP
Identifiant web   : admin
Mot de passe      : ${CONFIG_DIR}/initial-admin.txt (à transférer dans Proton Pass puis supprimer)

Le paquet n'ouvre aucune règle de pare-feu et refuse une adresse publique.
L'exposition Internet requiert un SBC, TLS/SRTP et une recette séparée.
INFO

echo "✓ MikoPBX préparé sur l'adresse privée ${bind_ip}"
