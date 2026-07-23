#!/bin/bash
# setup.sh — Jitsi Meet (visioconférence, 4 conteneurs)
set -euo pipefail
echo "→ Préparation de Jitsi Meet..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
_SECRETS="${CONFIG_DIR}/secrets.env"
mkdir -p "${CONFIG_DIR}"/{web,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb}

read_secret() { [ -f "${_SECRETS}" ] && grep "^$1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- || true; }
JICOFO_PW="$(read_secret JICOFO_AUTH_PASSWORD)"; [ -z "${JICOFO_PW}" ] && JICOFO_PW=$(openssl rand -hex 16)
JVB_PW="$(read_secret JVB_AUTH_PASSWORD)"; [ -z "${JVB_PW}" ] && JVB_PW=$(openssl rand -hex 16)
JICOFO_SECRET="$(read_secret JICOFO_COMPONENT_SECRET)"; [ -z "${JICOFO_SECRET}" ] && JICOFO_SECRET=$(openssl rand -hex 16)

# IP à annoncer pour le flux vidéo UDP (JVB) : IP principale de l'hôte.
ADVERTISE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
[ -z "${ADVERTISE_IP}" ] && ADVERTISE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

cat > "${_SECRETS}" <<ENV
# ── Secrets partagés (persistés) ─────────────────────────────────────────────
JICOFO_AUTH_PASSWORD=${JICOFO_PW}
JVB_AUTH_PASSWORD=${JVB_PW}
JICOFO_COMPONENT_SECRET=${JICOFO_SECRET}

# ── Domaines XMPP internes (valeurs standard docker-jitsi-meet) ──────────────
XMPP_DOMAIN=meet.jitsi
XMPP_AUTH_DOMAIN=auth.meet.jitsi
XMPP_MUC_DOMAIN=muc.meet.jitsi
XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
XMPP_GUEST_DOMAIN=guest.meet.jitsi
XMPP_SERVER=xmpp.meet.jitsi
XMPP_BOSH_URL_BASE=http://xmpp.meet.jitsi:5280
JICOFO_AUTH_USER=focus
JVB_AUTH_USER=jvb
JVB_BREWERY_MUC=jvbbrewery

# ── Accès public / réseau ────────────────────────────────────────────────────
PUBLIC_URL=https://${CALEOPE_DOMAIN}
JVB_PORT=10000
JVB_ADVERTISE_IPS=${ADVERTISE_IP}
JVB_TCP_HARVESTER_DISABLED=true

# ── Réglages web ─────────────────────────────────────────────────────────────
# TLS géré par Traefik → pas de Let's Encrypt ni redirection dans le conteneur.
ENABLE_LETSENCRYPT=0
ENABLE_HTTP_REDIRECT=0
ENABLE_HSTS=0
ENABLE_AUTH=0
ENABLE_GUESTS=1
TZ=Europe/Paris
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                 Jitsi Meet — Visioconférence                    │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${CALEOPE_DOMAIN}/                          │
  │  ⚠ Flux vidéo : le port UDP 10000 doit être joignable depuis    │
  │    l'extérieur (ouvert dans le pare-feu + redirigé sur la box). │
  │  IP annoncée (JVB) : ${ADVERTISE_IP}                            │
  │  Serveur ouvert : n'importe qui avec le lien peut créer/rejoindre.│
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Jitsi Meet configuré — IP vidéo annoncée : ${ADVERTISE_IP}"
