---
title: Applications disponibles
description: Catalogue des applications du store Caleope
published: true
date: 2026-05-23
---

# Applications disponibles

Toutes les applications sont installables avec `caleope install <id>`.  
Pour synchroniser le catalogue avant installation : `caleope update`

---

## Média

### Jellyfin
Serveur multimédia libre — films, séries, musique, photos.

```bash
caleope install jellyfin --domain media.monserveur.fr
```

| | |
|---|---|
| **ID** | `jellyfin` |
| **Image** | `jellyfin/jellyfin:latest` |
| **Port interne** | 8096 |
| **Identifiants** | Créés lors du premier accès web |

---

## Cloud & Productivité

### Nextcloud + OnlyOffice
Suite collaborative complète — fichiers, agenda, contacts, édition de documents.

```bash
caleope install nextcloud --domain cloud.monserveur.fr
```

| | |
|---|---|
| **ID** | `nextcloud` |
| **Images** | `nextcloud:latest` + `mariadb:11` + `onlyoffice/documentserver` |
| **Port interne** | 80 |
| **Identifiants** | Affichés à la fin de l'installation |

> ⏳ Nextcloud initialise sa base de données au premier démarrage (3-5 minutes).

---

## Supervision

### Prometheus + Grafana
Stack de supervision complète — métriques système et par application, dashboards historiques.

```bash
caleope install prometheus-grafana --domain metrics.monserveur.fr
```

| | |
|---|---|
| **ID** | `prometheus-grafana` |
| **Images** | `grafana/grafana` + `prom/prometheus` |
| **Port interne** | 3000 |
| **Identifiants** | Affichés à la fin de l'installation |

Le dashboard **Caleope Overview** est préconfiguré avec :
- RAM et disque système (jauges)
- CPU et RAM par application (courbes)
- État de toutes les applications (tableau)

---

## Documentation

### Wiki.js
Wiki moderne avec éditeur web, synchronisation GitHub et lecture publique.

```bash
caleope install wikijs --domain docs.monserveur.fr
```

| | |
|---|---|
| **ID** | `wikijs` |
| **Images** | `requarks/wiki:2` + `postgres:15` |
| **Port interne** | 3000 |
| **Identifiants** | Créés lors du wizard de première configuration |

---

## Ajouter une application au store

Le store est open-source : [github.com/Gaiver-IT/caleope-store](https://github.com/Gaiver-IT/caleope-store)

Chaque application est un dossier `apps/<id>/` contenant :
- `app.json` — métadonnées et configuration
- `docker-compose.yml` — template Docker Compose (variables Go templates)
- `setup.sh` — script de préparation (génération secrets, création dossiers)
