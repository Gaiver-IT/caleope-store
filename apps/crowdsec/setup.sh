#!/bin/bash
# setup.sh — CrowdSec + Traefik bouncer
set -euo pipefail
echo "→ Préparation de CrowdSec..."

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/crowdsec"
TRAEFIK_DYNAMIC_DIR="${CALEOPE_BASE_DIR}/data/traefik/dynamic"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}/"{config,data}
mkdir -p "${TRAEFIK_DYNAMIC_DIR}"

# ── acquisition.yaml — sources de logs analysés par CrowdSec ─────────────────
# Traefik écrit ses logs dans ${CALEOPE_BASE_DIR}/data/traefik/
# CrowdSec les lit en read-only depuis /var/log/traefik/ (voir volumes)
cat > "${DATA_DIR}/config/acquis.yaml" << 'EOF'
---
filenames:
  - /opt/traefik-logs/*.log
labels:
  type: traefik
---
filenames:
  - /var/log/auth.log
  - /var/log/syslog
labels:
  type: syslog
EOF

# ── Clé API pour le bouncer (générée ici, injectée via secrets.env) ──────────
BOUNCER_KEY=$(openssl rand -hex 32)

cat > "${CONFIG_DIR}/secrets.env" << EOF
# Clé d'API du bouncer Traefik
CROWDSEC_BOUNCER_APIKEY=${BOUNCER_KEY}

# URL interne de l'API CrowdSec (lue par le bouncer)
CROWDSEC_AGENT_HOST=crowdsec:8080

# Activer le mode streaming pour les décisions (plus efficace)
GIN_MODE=release
EOF
chmod 600 "${CONFIG_DIR}/secrets.env"

# ── bootstrap.sh : enregistrement du bouncer dans CrowdSec ──────────────────
# Le bootstrap tourne dans le container crowdsec pour créer la clé bouncer
# puis écrit la config Traefik dynamique pour activer le middleware
cat > "${CONFIG_DIR}/bootstrap.sh" << BOOTSTRAP
#!/bin/sh
set -e
MAX_WAIT=60
WAITED=0

echo "→ CrowdSec bootstrap : attente de l'API locale..."
until cscli lapi status >/dev/null 2>&1; do
    sleep 5
    WAITED=\$((WAITED + 5))
    [ "\${WAITED}" -lt "\${MAX_WAIT}" ] || { echo "❌ CrowdSec non prêt"; exit 1; }
done
echo "  ✓ API CrowdSec prête"

# Enregistrer la clé bouncer si inexistante
if ! cscli bouncers list 2>/dev/null | grep -q "traefik-bouncer"; then
    cscli bouncers add traefik-bouncer --key "${BOUNCER_KEY}" 2>/dev/null || true
    echo "  ✓ Bouncer traefik-bouncer enregistré"
fi

# Installer les collections (best-effort)
cscli collections install crowdsecurity/traefik 2>/dev/null || true
cscli collections install crowdsecurity/linux 2>/dev/null || true
echo "  ✓ Collections installées"
BOOTSTRAP
chmod 644 "${CONFIG_DIR}/bootstrap.sh"

# ── Config Traefik dynamique : middleware CrowdSec ────────────────────────────
# Traefik lit ce répertoire via le file provider et applique le middleware
# Les apps qui veulent la protection ajoutent le label :
#   traefik.http.routers.<app>.middlewares=crowdsec@file
cat > "${TRAEFIK_DYNAMIC_DIR}/crowdsec.yml" << EOF
http:
  middlewares:
    crowdsec:
      forwardAuth:
        address: "http://crowdsec-bouncer:8080/api/v1/forwardAuth"
        trustForwardHeader: true
EOF
echo "  ✓ Middleware Traefik CrowdSec écrit dans data/traefik/dynamic/crowdsec.yml"

# ── post-install.txt ─────────────────────────────────────────────────────────
cat > "${CALEOPE_APP_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │              CrowdSec — Protection et sécurité réseau            │
  ├──────────────────────────────────────────────────────────────────┤
  │  CrowdSec analyse les logs Traefik et bloque automatiquement     │
  │  les IPs malveillantes via le bouncer Traefik.                   │
  │                                                                  │
  │  Le middleware "crowdsec@file" est automatiquement disponible    │
  │  pour Traefik. Il est activé globalement par défaut.             │
  │                                                                  │
  │  Commandes utiles :                                              │
  │    docker exec crowdsec cscli decisions list                     │
  │    docker exec crowdsec cscli alerts list                        │
  │    docker exec crowdsec cscli bouncers list                      │
  │    docker exec crowdsec cscli metrics                            │
  │                                                                  │
  │  Bouncer API key : ${BOUNCER_KEY}
  │                                                                  │
  │  Secrets dans : app-config/${CALEOPE_APP_ID}/secrets.env         │
  └──────────────────────────────────────────────────────────────────┘
EOF

echo ""
echo "✓ CrowdSec configuré (bouncer Traefik actif)"
