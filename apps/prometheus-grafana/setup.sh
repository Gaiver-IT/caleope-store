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
mkdir -p "${APP_CONFIG_DIR}"
mkdir -p "${APP_DATA_DIR}/prometheus"
mkdir -p "${APP_DATA_DIR}/grafana/provisioning/datasources"
mkdir -p "${APP_DATA_DIR}/grafana/provisioning/dashboards"
mkdir -p "${APP_DATA_DIR}/grafana/dashboards"

# ── Ouvrir port 9100 depuis les sous-réseaux Docker ──
# Prometheus tourne dans un container Docker et doit accéder à caleoped sur l'hôte.
# UFW bloque par défaut le trafic des sous-réseaux Docker vers l'hôte.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow from 172.0.0.0/8 to any port 9100 comment "caleoped-metrics-docker" 2>/dev/null || true
    ufw allow from 192.168.0.0/16 to any port 9100 comment "caleoped-metrics-docker" 2>/dev/null || true
fi

# ── prometheus.yml ──
# Utiliser host.docker.internal (résolu via extra_hosts dans le compose) ──
# host-gateway = IP de l'hôte vue depuis le container Docker.
cat > "${APP_DATA_DIR}/prometheus/prometheus.yml" << 'PROM_EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "caleope"
    static_configs:
      - targets: ["host.docker.internal:9100"]
    relabel_configs:
      - target_label: instance
        replacement: "caleope-daemon"
PROM_EOF

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
EOF
chmod 600 "${APP_CONFIG_DIR}/secrets.env"

# ── SSO Authentik : OIDC OAuth2 natif ───────────────────────────────────────
# Grafana supporte OAuth2 nativement → pas de ForwardAuth, utilisation d'OIDC.
# L'API Authentik n'est pas joignable via son URL publique depuis le serveur
# (pas de hairpin NAT) → on utilise http://localhost:8000 (port hôte).
CALEOPE_AUTH_MIDDLEWARE=""

if [ -d "${CALEOPE_BASE_DIR}/apps-installed/authentik" ]; then
    AK_SECRETS="${CALEOPE_BASE_DIR}/app-config/authentik/secrets.env"
    if [ -f "${AK_SECRETS}" ]; then
        AK_TOKEN=$(grep "^AUTHENTIK_BOOTSTRAP_TOKEN=" "${AK_SECRETS}" | cut -d= -f2-)
        AK_DOMAIN=$(grep "^AUTHENTIK_DOMAIN=" "${AK_SECRETS}" | cut -d= -f2-)
        if [ -z "${AK_DOMAIN}" ]; then
            BASE_DOMAIN=$(grep "^CALEOPE_DOMAIN=" "${CALEOPE_BASE_DIR}/caleope.conf" 2>/dev/null | cut -d= -f2-)
            AK_DOMAIN="authentik.${BASE_DOMAIN}"
        fi

        if [ -n "${AK_TOKEN}" ] && [ -n "${AK_DOMAIN}" ]; then
            AK_PORT=$(grep "^CALEOPE_PORT_WEB=" "${CALEOPE_BASE_DIR}/apps-installed/authentik/app.env" 2>/dev/null | cut -d= -f2-)
            AK_PORT="${AK_PORT:-8000}"
            AK_BASE="http://localhost:${AK_PORT}/api/v3"
            AK_HA="Authorization: Bearer ${AK_TOKEN}"
            AK_HJ="Content-Type: application/json"

            echo "  → Configuration OIDC Grafana dans Authentik..."

            AUTH_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-authorization-implicit-consent" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            INVAL_FLOW=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/flows/instances/?slug=default-provider-invalidation-flow" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0]['pk'] if d['results'] else '')" 2>/dev/null || echo "")
            PROP_MAPS=$(curl -s --max-time 10 -H "${AK_HA}" \
                "${AK_BASE}/propertymappings/scope/?managed__icontains=goauthentik.io" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join('\"'+r[\"pk\"]+'\"' for r in d.get('results',[])))" 2>/dev/null || echo "")

            if [ -n "${AUTH_FLOW}" ] && [ -n "${INVAL_FLOW}" ]; then
                GF_OIDC_SECRET=$(openssl rand -hex 16)
                PROV_BODY=$(python3 -c "
import json
d = {
    'name': 'Grafana',
    'authorization_flow': '${AUTH_FLOW}',
    'invalidation_flow': '${INVAL_FLOW}',
    'client_type': 'confidential',
    'client_id': 'grafana',
    'client_secret': '${GF_OIDC_SECRET}',
    'redirect_uris': [{'matching_mode': 'strict', 'url': 'https://${DOMAIN}/login/generic_oauth'}],
    'sub_mode': 'hashed_user_id',
    'include_claims_in_id_token': True,
}
if '${PROP_MAPS}':
    d['property_mappings'] = [s.strip('\"') for s in '${PROP_MAPS}'.split(',')]
print(json.dumps(d))
" 2>/dev/null)
                PROV_PK=$(curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                    "${AK_BASE}/providers/oauth2/" -d "${PROV_BODY}" \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('pk',''))" 2>/dev/null || echo "")

                if [ -n "${PROV_PK}" ]; then
                    curl -s --max-time 10 -X POST -H "${AK_HA}" -H "${AK_HJ}" \
                        "${AK_BASE}/core/applications/" \
                        -d "{\"name\":\"Grafana\",\"slug\":\"grafana-sso\",\"provider\":${PROV_PK},\"meta_launch_url\":\"https://${DOMAIN}/\"}" \
                        >/dev/null 2>&1 || true

                    # Ajouter les vars OAuth2 dans secrets.env
                    cat >> "${APP_CONFIG_DIR}/secrets.env" << OAUTHEOF
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME=Authentik
GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${GF_OIDC_SECRET}
GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://${AK_DOMAIN}/application/o/authorize/
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://${AK_DOMAIN}/application/o/token/
GF_AUTH_GENERIC_OAUTH_API_URL=https://${AK_DOMAIN}/application/o/userinfo/
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'
GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=false
GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE=true
GF_AUTH_SIGNOUT_REDIRECT_URL=https://${AK_DOMAIN}/application/o/grafana-sso/end-session/
OAUTHEOF

                    # Ajouter extra_hosts au compose pour le token exchange interne
                    # Grafana doit atteindre Authentik via Traefik (réseau Docker interne)
                    TRAEFIK_IP=$(docker inspect traefik \
                        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | \
                        awk '{print $1}')
                    if [ -n "${TRAEFIK_IP}" ]; then
                        awk -v domain="${AK_DOMAIN}" -v ip="${TRAEFIK_IP}" '
/^  grafana:/ { in_grafana=1 }
in_grafana && /^    env_file:/ && !extra_done {
    print "    extra_hosts:"
    print "      - \"" domain ":" ip "\""
    extra_done=1
}
{ print }
' "${CALEOPE_APP_DIR}/compose.yml" > /tmp/gf_compose_sso.yml && \
                        mv /tmp/gf_compose_sso.yml "${CALEOPE_APP_DIR}/compose.yml" || true
                    fi

                    echo "  ✓ Grafana OIDC configuré dans Authentik (PK=${PROV_PK})"
                else
                    echo "  ⚠ Erreur création provider OIDC Grafana"
                fi
            else
                echo "  ⚠ Flows Authentik introuvables"
            fi
        fi
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
║  → Scraping Caleope sur host.docker.internal:9100   ║
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
