---
title: Caleope
description: Plateforme self-hosting Docker pour Debian/Ubuntu
published: true
date: 2026-05-23
---

# Caleope

**Caleope** est une plateforme open-source de gestion d'applications self-hosted pour Debian/Ubuntu.  
Elle te permet d'installer, superviser et gérer tes applications Docker en quelques secondes — sans toucher à la configuration Docker à la main.

---

## Pourquoi Caleope ?

Le self-hosting, c'est reprendre le contrôle de ses données. Mais installer et maintenir des dizaines d'applications Docker (Jellyfin, Nextcloud, Grafana...) demande du temps : volumes, réseaux, Traefik, mises à jour...

**Caleope automatise tout ça** avec une CLI simple, comme un gestionnaire de paquets pour tes applications auto-hébergées.

```bash
caleope install jellyfin --domain media.mon-serveur.fr
# → installé, accessible, sauvegardé, supervisé
```

---

## En un coup d'œil

| Fonctionnalité | Description |
|---------------|-------------|
| 📦 **Store d'apps** | Jellyfin, Nextcloud, Grafana, Wiki.js… |
| 🔄 **Sauvegardes** | `caleope backup nextcloud` — données + config |
| 📊 **Supervision** | `caleope top` en temps réel ou Grafana |
| 🗄️ **Stockage NAS** | Données directement sur ton NAS (SMB/SFTP) |
| 🌐 **API REST** | Intégration avec tes scripts ou interfaces |
| ⬆️ **Mises à jour** | `caleope upgrade` — un seul binaire à mettre à jour |

---

## Démarrage rapide

```bash
apt install -y curl
curl -fsSL https://raw.githubusercontent.com/Gaiver-IT/caleope/main/install.sh | bash
```

→ [Guide d'installation complet](/installation)

---

## Navigation

- [Installation](/installation) — Prérequis, installation, première vérification
- [Guide utilisateur](/guide) — Toutes les commandes avec exemples
- [API REST](/api) — Référence complète des routes
- [Applications disponibles](/apps) — Le catalogue du store
