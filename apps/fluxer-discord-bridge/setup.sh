#!/bin/bash
set -euo pipefail

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/${CALEOPE_APP_ID}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${CALEOPE_BASE_DIR}/app-data/fluxer-discord-bridge/db"

# Les tokens ne peuvent pas être générés automatiquement — l'utilisateur
# doit les renseigner manuellement après l'install via post-install.txt.
cat > "${CONFIG_DIR}/secrets.env" << 'ENVEOF'
# ─────────────────────────────────────────────────────────────────────────────
# Fluxer-Discord Bridge — Tokens à renseigner avant le premier démarrage
# ─────────────────────────────────────────────────────────────────────────────

# Token du bot Discord
# Créer un bot : https://discord.com/developers/applications
# Permissions requises : Manage Roles, Manage Webhooks, Send Messages, Read Message History
DISCORD_TOKEN=

# Token du bot Fluxer
# Permissions requises : Manage Roles, Manage Webhooks, Send Messages, Read Message History
FLUXER_TOKEN=

# Préfixe des commandes du bridge (défaut : brdg;)
# Exemple : brdg;help  brdg;link  brdg;unlink
CMD_PREFIX=brdg;
ENVEOF
chmod 600 "${CONFIG_DIR}/secrets.env"

cat > "${CONFIG_DIR}/post-install.txt" << EOF

  ┌──────────────────────────────────────────────────────────────┐
  │       Fluxer-Discord Bridge — Configuration requise          │
  ├──────────────────────────────────────────────────────────────┤
  │  ⚠  Le service tourne mais les bots ne peuvent pas           │
  │     s'authentifier sans leurs tokens.                        │
  │                                                              │
  │  1. Édite le fichier de secrets :                            │
  │     ${CONFIG_DIR}/secrets.env    │
  │                                                              │
  │  2. Remplis les valeurs :                                    │
  │     DISCORD_TOKEN=<ton token Discord>                        │
  │       → discord.com/developers/applications                  │
  │     FLUXER_TOKEN=<ton token Fluxer>                          │
  │     CMD_PREFIX=brdg;  (ou ton préfixe personnalisé)          │
  │                                                              │
  │  3. Redémarre le service :                                   │
  │     caleope restart fluxer-discord-bridge                    │
  │                                                              │
  │  4. Teste dans Discord ou Fluxer :                           │
  │     brdg;help                                                │
  │                                                              │
  │  Permissions requises sur les deux bots :                    │
  │    Manage Roles, Manage Webhooks,                            │
  │    Send Messages, Read Message History                       │
  └──────────────────────────────────────────────────────────────┘
EOF

echo "✓ Fluxer-Discord Bridge préparé — renseigne les tokens dans secrets.env puis : caleope restart fluxer-discord-bridge"
