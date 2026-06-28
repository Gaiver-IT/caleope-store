#!/bin/bash
# AdGuard Home setup — pré-configure via AdGuardHome.yaml (avant démarrage container)
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/adguard"
_SECRETS="${CONFIG_DIR}/secrets.env"
DATA_CONF="${CALEOPE_BASE_DIR}/app-data/adguard/conf"

# ── Credentials ───────────────────────────────────────────────────────────────
ADGUARD_USERNAME="admin"
ADGUARD_PASSWORD=""
ADGUARD_DNS1="1.1.1.1"
ADGUARD_DNS2="1.0.0.1"

if [ -f "${_SECRETS}" ]; then
    _PREV_USER=$(grep "^ADGUARD_USERNAME=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_USER=""
    _PREV_PASS=$(grep "^ADGUARD_PASSWORD=" "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_PASS=""
    _PREV_DNS1=$(grep "^ADGUARD_DNS1="    "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_DNS1=""
    _PREV_DNS2=$(grep "^ADGUARD_DNS2="    "${_SECRETS}" 2>/dev/null | cut -d= -f2-) || _PREV_DNS2=""
    [ -n "${_PREV_USER}" ] && ADGUARD_USERNAME="${_PREV_USER}"
    [ -n "${_PREV_PASS}" ] && ADGUARD_PASSWORD="${_PREV_PASS}"
    [ -n "${_PREV_DNS1}" ] && ADGUARD_DNS1="${_PREV_DNS1}"
    [ -n "${_PREV_DNS2}" ] && ADGUARD_DNS2="${_PREV_DNS2}"
fi

[ -n "${CALEOPE_PARAM_ADGUARD_USERNAME:-}" ] && ADGUARD_USERNAME="${CALEOPE_PARAM_ADGUARD_USERNAME}"
[ -n "${CALEOPE_PARAM_ADGUARD_PASSWORD:-}" ] && ADGUARD_PASSWORD="${CALEOPE_PARAM_ADGUARD_PASSWORD}"
[ -n "${CALEOPE_PARAM_ADGUARD_DNS1:-}"     ] && ADGUARD_DNS1="${CALEOPE_PARAM_ADGUARD_DNS1}"
[ -n "${CALEOPE_PARAM_ADGUARD_DNS2:-}"     ] && ADGUARD_DNS2="${CALEOPE_PARAM_ADGUARD_DNS2}"

[ -z "${ADGUARD_PASSWORD}" ] && \
    ADGUARD_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | cut -c1-16)

mkdir -p "${CONFIG_DIR}" "${DATA_CONF}"
cat > "${_SECRETS}" << ENV
ADGUARD_USERNAME=${ADGUARD_USERNAME}
ADGUARD_PASSWORD=${ADGUARD_PASSWORD}
ADGUARD_DNS1=${ADGUARD_DNS1}
ADGUARD_DNS2=${ADGUARD_DNS2}
ENV
chmod 600 "${_SECRETS}"
echo "  ✓ Secrets AdGuard Home générés"

# ── Port web alloué par Caleope ───────────────────────────────────────────────
# CALEOPE_PORT_WEB est exporté par buildEnvFile (format: CALEOPE_PORT_<NOM>)
_AG_WEB_PORT="${CALEOPE_PORT_WEB:-3080}"

# ── Hash bcrypt du mot de passe (pour AdGuardHome.yaml) ──────────────────────
_PASS_HASH=$(python3 -c "
import sys
try:
    import bcrypt
    h = bcrypt.hashpw('${ADGUARD_PASSWORD}'.encode(), bcrypt.gensalt(10)).decode()
    print(h)
except ImportError:
    pass
" 2>/dev/null) || _PASS_HASH=""

# Fallback htpasswd si bcrypt python indisponible
if [ -z "${_PASS_HASH}" ] && command -v htpasswd >/dev/null 2>&1; then
    _PASS_HASH=$(htpasswd -bnBC 10 "" "${ADGUARD_PASSWORD}" 2>/dev/null | tr -d ':\n') || _PASS_HASH=""
fi

# ── Pré-configuration AdGuardHome.yaml (avant démarrage container) ────────────
# setup.sh tourne à l'étape 7, docker compose up à l'étape 9.
# On écrit la config directement dans le dossier de données persistent.
_YAML="${DATA_CONF}/AdGuardHome.yaml"

if [ ! -f "${_YAML}" ]; then
    echo "→ Écriture de la configuration AdGuard Home..."

    if [ -n "${_PASS_HASH}" ]; then
        _USER_BLOCK="users:
  - name: ${ADGUARD_USERNAME}
    password: '${_PASS_HASH}'"
    else
        # Sans bcrypt, la config sera sans auth → l'utilisateur configure au 1er accès
        _USER_BLOCK="users: []"
        echo "  ⚠ bcrypt indisponible — configurer le compte admin à la 1ère connexion"
    fi

    cat > "${_YAML}" << YAML
# Généré par Caleope — ne pas modifier manuellement
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:3000
  session_ttl: 720h
auth_attempts: 5
block_auth_min: 15
${_USER_BLOCK}
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - ${ADGUARD_DNS1}
    - ${ADGUARD_DNS2}
  bootstrap_dns:
    - 9.9.9.9
    - 149.112.112.112
  fallback_dns: []
  upstream_mode: ""
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  rewrites: []
  blocked_services:
    schedule:
      time_zone: Europe/Paris
    ids: []
  protection_enabled: true
  blocking_mode: default
  blocking_ipv4: ""
  blocking_ipv6: ""
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  ipset: []
  ipset_file: ""
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  max_goroutines: 300
  handle_ddr: true
  ratelimit: 20
  ratelimit_whitelist: []
  refuse_any: true
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Europe/Paris
    ids: []
  protection_enabled: true
  filtering_enabled: true
  filters_update_interval: 24
  parental_enabled: false
  safebrowsing_enabled: false
  safebrowsing_cache_size: 1048576
  safesearch:
    enabled: false
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  parental_cache_size: 1048576
  safe_search_cache_size: 1048576
  rewrites: []
  filters:
    - enabled: true
      url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
      name: AdGuard DNS filter
      id: 1
    - enabled: true
      url: https://adaway.org/hosts.txt
      name: AdAway Default Blocklist
      id: 2
  whitelist_filters: []
  user_rules: []
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
YAML
    echo "  ✓ AdGuardHome.yaml pré-configuré"
else
    echo "  ℹ Configuration existante conservée (${_YAML})"
fi

# ── Post-install info ─────────────────────────────────────────────────────────
cat > "${CONFIG_DIR}/post-install.txt" << INFO
AdGuard Home est démarré et pré-configuré.

  Interface admin : https://${CALEOPE_DOMAIN}/
  Utilisateur     : ${ADGUARD_USERNAME}
  Mot de passe    : ${ADGUARD_PASSWORD}

Pour utiliser AdGuard Home comme DNS sur votre réseau :
  Configurer l'IP de ce serveur comme DNS primaire sur vos routeurs/clients.
  Port DNS : 53 (UDP/TCP)

Note : si le wizard de configuration s'affiche, c'est que bcrypt n'était pas
disponible lors de l'installation. Utilisez les credentials ci-dessus.

Secrets dans : app-config/adguard/secrets.env
INFO

echo "✓ AdGuard Home configuré"
