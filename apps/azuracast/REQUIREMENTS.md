# AzuraCast — Prérequis

## Ports à ouvrir dans le pare-feu

AzuraCast utilise des ports **fixés** (non dynamiques) pour les flux radio.
Ces ports doivent être accessibles par les auditeurs directement (pas via Traefik).

| Port | Protocole | Usage |
|------|-----------|-------|
| 2022 | TCP | SFTP — upload des fichiers audio |
| 8000 | TCP | Icecast — Station 1 (flux principal) |
| 8005 | TCP | Icecast — Station 1 (flux backup/HTTPS) |
| 8010 | TCP | Icecast — Station 2 |
| 8015 | TCP | Icecast — Station 2 (backup) |
| 8020 | TCP | Icecast — Station 3 |
| 8025 | TCP | Icecast — Station 3 (backup) |
| 8030 | TCP | Icecast — Station 4 |
| 8035 | TCP | Icecast — Station 4 (backup) |
| 8040 | TCP | Icecast — Station 5 |
| 8045 | TCP | Icecast — Station 5 (backup) |

> Pour plus de 5 stations, ajouter les ports 8050, 8055, 8060… dans
> `docker-compose.yml` et dans les règles pare-feu.

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
