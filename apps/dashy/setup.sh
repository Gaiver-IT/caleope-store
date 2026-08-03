#!/bin/bash
set -euo pipefail

# ── Dashy — tableau de bord d'accueil ────────────────────────────────────────
# Comme pour les autres tableaux de bord du store : on n'écrase JAMAIS une
# configuration existante. `caleope install --force` rejoue ce setup à chaque
# mise à jour ; un `cat >` inconditionnel détruirait le travail de l'utilisateur.

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/dashy"
DATA="${CALEOPE_BASE_DIR}/app-data/dashy/user-data"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}" "${DATA}"
DOMAIN="${CALEOPE_DOMAIN:-localhost}"

cat > "${_SECRETS}" <<ENV
NODE_ENV=production
ENV
chmod 600 "${_SECRETS}"

# Dashy refuse de démarrer sans conf.yml : il ne crée PAS de configuration par
# défaut dans un volume monté vide. Sans ce fichier, le conteneur boucle en
# erreur — c'est le piège n°1 de cette image.
if [ ! -s "${DATA}/conf.yml" ]; then
  cat > "${DATA}/conf.yml" <<YAML
pageInfo:
  title: Tableau de bord
  description: Vos applications, au même endroit

appConfig:
  theme: nord-frost
  layout: auto
  iconSize: medium
  language: fr

sections:
  - name: Applications
    icon: fas fa-rocket
    items:
      - title: Caleope
        description: Gestion des applications de ce serveur
        icon: fas fa-server
        url: /
YAML
  echo "  ✓ conf.yml créé"
else
  echo "  → conf.yml conservé (déjà configuré)"
fi

# L'image tourne en utilisateur non-root : sans ces droits, Dashy ne peut pas
# réécrire sa configuration depuis son éditeur intégré.
chmod -R 0777 "${DATA}" 2>/dev/null || true

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                  Dashy — tableau de bord                         │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${DOMAIN}/
  │                                                                  │
  │  Deux façons de le configurer :                                  │
  │    • à la souris, via l'éditeur intégré (icône crayon)           │
  │    • en éditant app-data/dashy/user-data/conf.yml                │
  │                                                                  │
  │  Plus de 20 thèmes disponibles dans le sélecteur en haut.        │
  │                                                                  │
  │  Ce fichier n'est JAMAIS écrasé par une mise à jour.             │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Dashy prêt — https://${DOMAIN}/"
