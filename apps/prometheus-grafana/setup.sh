#!/bin/bash
# setup.sh — Prometheus + Grafana
# Génère la config Prometheus avec scraping du daemon Caleope (:9100/metrics)
#
# Variables d'environnement injectées par Caleope :
#   CALEOPE_BASE_DIR  — répertoire racine (/opt/gaiver-it/caleope)
#   CALEOPE_APP_ID    — identifiant de l'app (prometheus-grafana)
#   CALEOPE_APP_DIR   — répertoire compose de l'app
#   CALEOPE_DOMAIN    — domaine Grafana

set -euo pipefail

APP_CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
APP_DATA_DIR="${CALEOPE_BASE_DIR}/app-data/${CALEOPE_APP_ID}"
DOMAIN="${CALEOPE_DOMAIN}"
HOST_IP=""   # détecté automatiquement ci-dessous

mkdir -p "${APP_CONFIG_DIR}"
mkdir -p "${APP_DATA_DIR}/prometheus"
mkdir -p "${APP_DATA_DIR}/grafana/provisioning/datasources"
mkdir -p "${APP_DATA_DIR}/grafana/provisioning/dashboards"
mkdir -p "${APP_DATA_DIR}/grafana/dashboards"

# ── Détecter l'IP de l'hôte ──
if [[ -z "${HOST_IP}" ]]; then
    HOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
fi

# ── prometheus.yml ──
cat > "${APP_DATA_DIR}/prometheus/prometheus.yml" << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "caleope"
    static_configs:
      - targets: ["${HOST_IP}:9100"]
    relabel_configs:
      - target_label: instance
        replacement: "caleope-daemon"
EOF

# ── Grafana datasource : Prometheus ──
cat > "${APP_DATA_DIR}/grafana/provisioning/datasources/prometheus.yml" << EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://caleope-prometheus:9090
    isDefault: true
    editable: false
EOF

# ── Grafana dashboard provisioner ──
cat > "${APP_DATA_DIR}/grafana/provisioning/dashboards/caleope.yml" << EOF
apiVersion: 1
providers:
  - name: "Caleope"
    folder: "Caleope"
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF

# ── Dashboard Caleope (JSON minimal) ──
cat > "${APP_DATA_DIR}/grafana/dashboards/caleope-overview.json" << 'DASHBOARD_EOF'
{
  "title": "Caleope — Overview",
  "uid": "caleope-overview",
  "version": 1,
  "refresh": "30s",
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Apps actives",
      "gridPos": {"x":0,"y":0,"w":4,"h":4},
      "targets": [{"expr": "count(caleope_app_running == 1)", "legendFormat": ""}],
      "options": {"colorMode": "value", "graphMode": "none"}
    },
    {
      "id": 2, "type": "gauge", "title": "RAM système",
      "gridPos": {"x":4,"y":0,"w":4,"h":4},
      "targets": [{"expr": "caleope_system_memory_used_megabytes / caleope_system_memory_total_megabytes * 100", "legendFormat": "RAM %"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "minVizWidth": 75},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
        "thresholds": {"steps": [{"color":"green","value":0},{"color":"yellow","value":70},{"color":"red","value":90}]}}}
    },
    {
      "id": 3, "type": "gauge", "title": "Disque",
      "gridPos": {"x":8,"y":0,"w":4,"h":4},
      "targets": [{"expr": "caleope_system_disk_used_gigabytes / caleope_system_disk_total_gigabytes * 100", "legendFormat": "Disk %"}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "minVizWidth": 75},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
        "thresholds": {"steps": [{"color":"green","value":0},{"color":"yellow","value":70},{"color":"red","value":90}]}}}
    },
    {
      "id": 4, "type": "timeseries", "title": "CPU par app",
      "gridPos": {"x":0,"y":4,"w":12,"h":8},
      "targets": [{"expr": "caleope_app_cpu_percent", "legendFormat": "{{app}}"}]
    },
    {
      "id": 5, "type": "timeseries", "title": "RAM par app (MB)",
      "gridPos": {"x":12,"y":4,"w":12,"h":8},
      "targets": [{"expr": "caleope_app_memory_megabytes", "legendFormat": "{{app}}"}]
    },
    {
      "id": 6, "type": "table", "title": "État des apps",
      "gridPos": {"x":0,"y":12,"w":24,"h":6},
      "targets": [{"expr": "caleope_app_running", "legendFormat": "{{app}}", "instant": true}],
      "transformations": [{"id": "sortBy", "options": {"fields": [{"desc": false, "displayName": "app"}]}}]
    }
  ],
  "time": {"from": "now-1h", "to": "now"},
  "templating": {"list": []},
  "annotations": {"list": []}
}
DASHBOARD_EOF

# ── Permissions des volumes ──
# Grafana tourne en tant qu'UID 472 dans son image officielle
chown -R 472:472 "${APP_DATA_DIR}/grafana"
# Prometheus tourne en tant qu'UID 65534 (nobody)
chown -R 65534:65534 "${APP_DATA_DIR}/prometheus"

# ── Générer les credentials Grafana ──
GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')

cat > "${APP_CONFIG_DIR}/secrets.env" << EOF
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
GF_SERVER_ROOT_URL=https://${DOMAIN}
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
PROMETHEUS_HOST_IP=${HOST_IP}
EOF
chmod 600 "${APP_CONFIG_DIR}/secrets.env"

# ── Auto-enregistrement dans Authentik ──────────────────────────────────────
authentik_register_app() {
    local APP_NAME="$1" APP_SLUG="$2" APP_URL="$3"
    local AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    [ -f "${AK_SECRETS}" ] || return 1

    local TOKEN AK_DOMAIN
    TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
    AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
    [ -n "${TOKEN}" ] && [ -n "${AK_DOMAIN}" ] || return 1

    local BASE="https://${AK_DOMAIN}/api/v3"
    local HA="Authorization: Bearer ${TOKEN}"
    local HJ="Content-Type: application/json"

    echo "  → Connexion à l'API Authentik (max 60s)..."
    local i=0
    until curl -sf --max-time 5 -H "${HA}" "${BASE}/core/applications/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -lt 12 ] || { echo "  ⚠ Authentik non joignable"; return 1; }
        sleep 5
    done

    local FLOW_UUID
    FLOW_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
    [ -n "${FLOW_UUID}" ] || { echo "  ⚠ Flow Authentik introuvable"; return 1; }

    local PROVIDER_PK
    PROVIDER_PK=$(curl -sf --max-time 10 -H "${HA}" "${BASE}/providers/proxy/" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = [p for p in d.get('results',[]) if p['name']==\"${APP_NAME}\"]
print(m[0]['pk'] if m else '')
" 2>/dev/null || echo "")

    if [ -z "${PROVIDER_PK}" ]; then
        PROVIDER_PK=$(curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
            "${BASE}/providers/proxy/" \
            -d "{\"name\":\"${APP_NAME}\",\"authorization_flow\":\"${FLOW_UUID}\",\"external_host\":\"${APP_URL}\",\"mode\":\"forward_single\"}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")
    fi
    [ -n "${PROVIDER_PK}" ] || { echo "  ⚠ Erreur création Provider"; return 1; }

    curl -sf --max-time 10 -X POST -H "${HA}" -H "${HJ}" \
        "${BASE}/core/applications/" \
        -d "{\"name\":\"${APP_NAME}\",\"slug\":\"${APP_SLUG}\",\"provider\":${PROVIDER_PK}}" \
        >/dev/null 2>&1 || true

    local OUTPOST_UUID CURRENT_PROVIDERS NEW_PROVIDERS
    OUTPOST_UUID=$(curl -sf --max-time 10 -H "${HA}" \
        "${BASE}/outposts/instances/?managed=goauthentik.io%2Foutposts%2Fembedded" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")

    if [ -n "${OUTPOST_UUID}" ]; then
        CURRENT_PROVIDERS=$(curl -sf --max-time 10 -H "${HA}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('providers',[])))" 2>/dev/null || echo "[]")
        NEW_PROVIDERS=$(echo "${CURRENT_PROVIDERS}" | python3 -c "
import sys, json
l = json.load(sys.stdin)
if ${PROVIDER_PK} not in l: l.append(${PROVIDER_PK})
print(json.dumps(l))
" 2>/dev/null || echo "[${PROVIDER_PK}]")
        curl -sf --max-time 10 -X PATCH -H "${HA}" -H "${HJ}" \
            "${BASE}/outposts/instances/${OUTPOST_UUID}/" \
            -d "{\"providers\":${NEW_PROVIDERS}}" >/dev/null 2>&1 || true
    fi

    echo "  → ${APP_NAME} enregistré dans Authentik ✓"
    return 0
}

CALEOPE_AUTH_MIDDLEWARE=""
if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    if authentik_register_app "Grafana" "grafana" "https://${DOMAIN}"; then
        CALEOPE_AUTH_MIDDLEWARE="authentik@docker"
    else
        echo "  ⚠ ForwardAuth désactivé (enregistrement Authentik échoué)"
    fi
fi
echo "CALEOPE_AUTH_MIDDLEWARE=${CALEOPE_AUTH_MIDDLEWARE}" >> "${APP_CONFIG_DIR}/secrets.env"

# ── Post-install ──
cat > "${APP_CONFIG_DIR}/post-install.txt" << EOF
╔══════════════════════════════════════════════════════╗
║       Prometheus + Grafana — Installation réussie    ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  Grafana                                             ║
║  → https://${DOMAIN}                     ║
║                                                      ║
║  Identifiants admin :                                ║
║  Utilisateur : admin                                 ║
║  Mot de passe : ${GRAFANA_PASSWORD}
║                                                      ║
║  Sources de données :                                ║
║  → Prometheus configuré automatiquement              ║
║  → Scraping Caleope sur ${HOST_IP}:9100         ║
║                                                      ║
║  Dashboard inclus : Caleope — Overview               ║
║  → Grafana > Dashboards > Caleope                    ║
╚══════════════════════════════════════════════════════╝
EOF

# ── Afficher les identifiants dans la sortie d'installation ──
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Prometheus + Grafana — Identifiants d'accès      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  URL      : https://${DOMAIN}"
echo "║  Login    : admin"
echo "║  Password : ${GRAFANA_PASSWORD}"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
