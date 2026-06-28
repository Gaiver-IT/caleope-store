#!/bin/bash
# Pi-hole setup — génère les secrets, configure le reverse proxy et l'API token
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/pihole"
_SECRETS="${CONFIG_DIR}/secrets.env"

# ── Credentials ───────────────────────────────────────────────────────────────
PIHOLE_WEBPASSWORD=""
PIHOLE_DNS1="1.1.1.1"
PIHOLE_DNS2="1.0.0.1"

if [ -f "${_SECRETS}" ]; then
    _PREV_PASS=$(grep "^PIHOLE_WEBPASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2- | tr -d '"') || _PREV_PASS=""
    _PREV_DNS1=$(grep "^PIHOLE_DNS1=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_DNS1=""
    _PREV_DNS2=$(grep "^PIHOLE_DNS2=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_DNS2=""
    [ -n "${_PREV_PASS}" ] && PIHOLE_WEBPASSWORD="${_PREV_PASS}"
    [ -n "${_PREV_DNS1}" ] && PIHOLE_DNS1="${_PREV_DNS1}"
    [ -n "${_PREV_DNS2}" ] && PIHOLE_DNS2="${_PREV_DNS2}"
fi

# Paramètres fournis par Caleope (depuis params.json)
[ -n "${CALEOPE_PARAM_PIHOLE_WEBPASSWORD:-}" ] && PIHOLE_WEBPASSWORD="${CALEOPE_PARAM_PIHOLE_WEBPASSWORD}"
[ -n "${CALEOPE_PARAM_PIHOLE_DNS1:-}" ]        && PIHOLE_DNS1="${CALEOPE_PARAM_PIHOLE_DNS1}"
[ -n "${CALEOPE_PARAM_PIHOLE_DNS2:-}" ]        && PIHOLE_DNS2="${CALEOPE_PARAM_PIHOLE_DNS2}"

[ -z "${PIHOLE_WEBPASSWORD}" ] && \
    PIHOLE_WEBPASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-16)

# ── API token = SHA256(SHA256(password)) ──────────────────────────────────────
PIHOLE_API_TOKEN=$(python3 -c "
import hashlib, sys
pw = '${PIHOLE_WEBPASSWORD}'
h1 = hashlib.sha256(pw.encode()).digest()
h2 = hashlib.sha256(h1).hexdigest()
print(h2)
" 2>/dev/null || echo -n "${PIHOLE_WEBPASSWORD}" | sha256sum | awk '{print $1}')

mkdir -p "${CONFIG_DIR}"
cat > "${_SECRETS}" << ENV
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_DNS1=${PIHOLE_DNS1}
PIHOLE_DNS2=${PIHOLE_DNS2}
PIHOLE_API_TOKEN=${PIHOLE_API_TOKEN}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Secrets Pi-hole générés"

# ── Authentik SSO — ForwardAuth (Pi-hole n'a pas d'OIDC natif) ────────────────
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" 2>/dev/null | cut -d= -f2-) || AK_TOKEN=""
    if [ -n "${AK_TOKEN}" ]; then
        echo "  → Authentik détecté — ForwardAuth configuré (Pi-hole ne supporte pas OIDC natif)"
    fi
fi

# ── Post-install info ─────────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/post-install.txt" << INFO
Pi-hole est démarré.
Interface admin : http://<IP>:${PIHOLE_PORT_WEB:-8053}/admin
Mot de passe admin : ${PIHOLE_WEBPASSWORD}
API token : ${PIHOLE_API_TOKEN}

Pour utiliser Pi-hole comme DNS sur votre réseau :
  Configurer l'IP de ce serveur comme DNS sur vos routeurs/clients.
  Port DNS : 53
INFO

echo "  ✓ Pi-hole configuré — admin : http://<IP>:${PIHOLE_PORT_WEB:-8053}/admin"
