# AzuraCast — Prérequis

## Ports à ouvrir dans le pare-feu

AzuraCast utilise des ports **fixés** (non dynamiques) pour les flux radio.
Ces ports doivent être accessibles par les auditeurs directement (pas via Traefik).

| Port | Protocole | Usage |
|------|-----------|-------|
| 2022 | TCP | SFTP — upload des fichiers audio |
| 8099 | TCP | Web UI accès direct (sans domaine) — configurable via `AZURACAST_WEB_PORT` |
| 8500 | TCP | Icecast — Station 1 (flux principal) |
| 8505 | TCP | Icecast — Station 1 (flux backup) |
| 8510 | TCP | Icecast — Station 2 |
| 8515 | TCP | Icecast — Station 2 (backup) |
| 8520 | TCP | Icecast — Station 3 |
| 8525 | TCP | Icecast — Station 3 (backup) |
| 8530 | TCP | Icecast — Station 4 |
| 8535 | TCP | Icecast — Station 4 (backup) |
| 8540 | TCP | Icecast — Station 5 |
| 8545 | TCP | Icecast — Station 5 (backup) |

> Pour plus de 5 stations, ajouter les ports 8550, 8555, 8560… dans
> `docker-compose.yml` et dans les règles pare-feu.

> **Pourquoi 8500+ ?** La plage 8000-8200 est très utilisée par les services
> courants (nginx, web apps, Jellyfin 8096, qBittorrent 8080…). La plage 8500+
> est spécifiquement réservée pour les flux médias, ce qui minimise les conflits.

## Ressources recommandées

- **RAM** : 1 Go minimum, 2 Go recommandés (Liquidsoap + Icecast + MariaDB)
- **CPU** : 1 vCPU minimum (encodage audio en temps réel)
- **Stockage** : Variable selon la bibliothèque musicale (prévoir ≥ 20 Go)

## Notes importantes

- Le **premier démarrage prend 3 à 5 minutes** : AzuraCast initialise MariaDB,
  applique les migrations et démarre Liquidsoap. C'est normal.
- AzuraCast est une application **tout-en-un** : nginx, PHP, MariaDB, Redis et
  Liquidsoap tournent dans le même container.
- Les flux audio **contournent Traefik** — les auditeurs se connectent directement
  sur `IP:8000`. Le port web (interface admin) passe lui par Traefik si un domaine
  est configuré.
