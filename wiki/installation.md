---
title: Installation
description: Installer Caleope sur Debian/Ubuntu
published: true
date: 2026-05-23
---

# Installation

## Prérequis

| Élément | Version minimale |
|---------|-----------------|
| OS | Debian 12 ou Ubuntu 22.04+ |
| Accès | Root (ou sudo) |
| Réseau | Connexion internet active |

> Docker est installé automatiquement par l'installateur si nécessaire.

---

## Installer Caleope

```bash
# 1. S'assurer que curl est disponible
apt install -y curl

# 2. Lancer l'installateur
curl -fsSL https://raw.githubusercontent.com/Gaiver-IT/caleope/main/install.sh | bash
```

L'installateur te demande deux informations :

- **Domaine de base** — ex : `home.local` ou `monserveur.fr`  
  Les applications seront accessibles sur `<app>.<domaine-base>` (ex: `jellyfin.home.local`)

- **Canal** — `stable` (recommandé) ou `alpha` (fonctionnalités en avant-première)

Après installation, le daemon `caleoped` démarre automatiquement via systemd.

---

## Vérifier l'installation

```bash
caleope ping
# → ✓ Daemon actif — version v0.4.7

caleope version
# → caleope v0.4.7
```

---

## Première application

```bash
# Synchroniser le catalogue d'apps
caleope update

# Rechercher une application
caleope search media

# Installer Jellyfin
caleope install jellyfin --domain media.monserveur.fr
```

→ L'application est accessible immédiatement à l'adresse affichée.

---

## Structure des fichiers

Caleope s'installe dans `/opt/gaiver-it/caleope/` :

```
/opt/gaiver-it/caleope/
├── app-config/       # Configuration et secrets de chaque app
├── app-data/         # Données des applications (volumes Docker)
├── apps-installed/   # Fichiers docker-compose générés
├── backups/          # Sauvegardes
├── mounts/           # Points de montage NAS
└── caleope.conf      # Configuration globale
```

---

## Mises à jour

```bash
caleope upgrade          # Mettre à jour Caleope
caleope upgrade --check  # Vérifier sans installer
caleope update           # Synchroniser le catalogue d'apps
```

---

## Désinstaller Caleope

```bash
# Arrêter le daemon
systemctl stop caleoped

# Supprimer les binaires
rm /usr/local/bin/caleope /usr/local/bin/caleoped

# Supprimer les données (optionnel)
rm -rf /opt/gaiver-it/caleope
```
