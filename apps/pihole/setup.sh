#!/bin/bash
# Pi-hole v6 setup
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/pihole"
_SECRETS="${CONFIG_DIR}/secrets.env"

PIHOLE_WEBPASSWORD=""
PIHOLE_DNS1="1.1.1.1"
PIHOLE_DNS2="1.0.0.1"

if [ -f "${_SECRETS}" ]; then
    PIHOLE_WEBPASSWORD=$(grep "^PIHOLE_WEBPASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- | tr -d '"') || true
    PIHOLE_DNS1=$(grep "^PIHOLE_DNS1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || PIHOLE_DNS1="1.1.1.1"
    PIHOLE_DNS2=$(grep "^PIHOLE_DNS2=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || PIHOLE_DNS2="1.0.0.1"
fi

[ -n "${CALEOPE_PARAM_PIHOLE_WEBPASSWORD:-}" ] && PIHOLE_WEBPASSWORD="${CALEOPE_PARAM_PIHOLE_WEBPASSWORD}"
[ -n "${CALEOPE_PARAM_PIHOLE_DNS1:-}" ] && PIHOLE_DNS1="${CALEOPE_PARAM_PIHOLE_DNS1}"
[ -n "${CALEOPE_PARAM_PIHOLE_DNS2:-}" ] && PIHOLE_DNS2="${CALEOPE_PARAM_PIHOLE_DNS2}"

[ -z "${PIHOLE_WEBPASSWORD}" ] && \
    PIHOLE_WEBPASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/pihole/etc-pihole"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/pihole/etc-dnsmasq"

# Pi-hole v6 uses FTLCONF_webserver_api_password (not PIHOLE_WEBPASSWORD) to set pass
cat > "${_SECRETS}" <<ENV
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_DNS1=${PIHOLE_DNS1}
PIHOLE_DNS2=${PIHOLE_DNS2}
FTLCONF_webserver_api_password=${PIHOLE_WEBPASSWORD}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Pi-hole configuré"

# Pi-hole ne supporte pas OIDC natif → aucun SSO configuré
# (ForwardAuth serait acceptable mais inutile car Pi-hole a sa propre auth)

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │               Pi-hole v6 — Bloqueur de pub DNS                   │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/admin                     │
  │                                                                  │
  │  Mot de passe : ${PIHOLE_WEBPASSWORD}                            │
  │                                                                  │
  │  DNS à configurer sur vos clients/routeurs :                     │
  │    Serveur DNS : IP_DE_CE_SERVEUR                                │
  │    Port DNS    : 53                                              │
  │                                                                  │
  │  DNS upstream configurés :                                       │
  │    Primaire   : ${PIHOLE_DNS1}                                   │
  │    Secondaire : ${PIHOLE_DNS2}                                   │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Pi-hole v6 — Bloqueur DNS                  ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  URL  : https://${CALEOPE_DOMAIN}/admin"
echo "  ║  Pass : ${PIHOLE_WEBPASSWORD}"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "✓ Pi-hole configuré"
