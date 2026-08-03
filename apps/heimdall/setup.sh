#!/bin/bash
set -euo pipefail

# ── Heimdall — page d'accueil ────────────────────────────────────────────────
# Toute la configuration de Heimdall vit dans SA base de données (/config), pas
# dans des fichiers texte : il n'y a donc rien à générer ici, et rien à écraser.
# On se contente de préparer le dossier et les variables de l'image linuxserver.

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/heimdall"
DATA="${CALEOPE_BASE_DIR}/app-data/heimdall/config"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}" "${DATA}"
DOMAIN="${CALEOPE_DOMAIN:-localhost}"

# PUID/PGID : les images linuxserver tournent sous cet utilisateur et se
# plaignent (ou perdent leurs droits) si on ne les fixe pas. 1000 est le
# premier utilisateur non-système sur Debian, celui qui possède app-data.
# ⚠️ Écrit à chaque fois SANS variable d'environnement à préserver : ce fichier
# ne contient aucun secret saisi par l'utilisateur, contrairement aux apps qui
# demandent un jeton — le motif « param > existant > défaut » ne s'applique pas.
cat > "${_SECRETS}" <<ENV
PUID=1000
PGID=1000
TZ=Europe/Paris
ENV
chmod 600 "${_SECRETS}"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                  Heimdall — page d'accueil                       │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${DOMAIN}/
  │                                                                  │
  │  Tout se fait dans l'interface : bouton « + » en bas à gauche    │
  │  pour ajouter une application, puis choisir son icône dans la    │
  │  liste intégrée (plus de 500 applications reconnues).            │
  │                                                                  │
  │  Volontairement minimaliste : Heimdall affiche des raccourcis,   │
  │  pas d'état de santé ni de statistiques. Pour cela, voir         │
  │  l'application « Homepage » du magasin.                          │
  │                                                                  │
  │  Sauvegarde : toute la configuration est dans /config, prise en  │
  │  charge par les sauvegardes Caleope.                             │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Heimdall prêt — https://${DOMAIN}/"
