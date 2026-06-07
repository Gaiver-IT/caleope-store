# Jellyfin — Exigences d'automatisation

> Tout ce qui est listé ici doit être configuré **automatiquement** au premier démarrage,
> sans aucune intervention manuelle, sauf les exceptions explicitement marquées *(manuel)*.

---

## Wizard de démarrage

- [x] Wizard complété automatiquement via le service `jellyfin-bootstrap` (alpine, restart:no)
- [x] Nom serveur : `Caleope`
- [x] Métadonnées + interface : **français** (`fr-FR`, `FR`)
- [x] Compte admin créé avec credentials générés aléatoirement
- [x] Accès distant activé (`EnableRemoteAccess: true`)
- *(manuel)* Bibliothèques médias (Films, Séries, Musique…) — à ajouter dans Paramètres

---

## Credentials

- [x] `JELLYFIN_USER` + `JELLYFIN_PASSWORD` générés automatiquement par `setup.sh`
- [x] Conservés d'un reinstall à l'autre (`--force`) pour ne pas casser les apps liées
- [x] Stockés dans `app-config/jellyfin/secrets.env` — lisibles par les autres apps Caleope
- [x] Affichés dans `post-install.txt` (URL + user + password)

> **Utilisation par arr-stack** : quand arr-stack détecte Jellyfin comme instance Caleope
> (`runtime/apps/jellyfin.json`), il lit automatiquement les credentials depuis
> `app-config/jellyfin/secrets.env` pour auto-configurer Jellyseerr. Zero interaction requise.

---

## Accès web

| Élément | Valeur |
|---------|--------|
| URL | `https://<jellyfin-domain>` (CALEOPE_DOMAIN de l'app) |
| Port interne | 8096 (container Docker) |
| Proxy | Traefik (optionnel : middleware Authentik si installé) |

---

## Authentik (optionnel)

- [x] Si Authentik est installé → auto-enregistrement de l'app (Provider proxy + Application + Outpost)
- *(manuel)* Si Authentik absent → accès direct sans ForwardAuth

---

## Notes techniques

### Wizard Jellyfin 10.11+ — timing /Startup/User

Le wizard Jellyfin 10.11.x introduit un délai entre les étapes :
après `POST /Startup/Configuration` (204), l'endpoint `POST /Startup/User`
retourne **404** pendant quelques secondes (le wizard n'est pas encore à l'étape User).

**Symptôme** : bootstrap imprime "Création compte échouée" alors que le wizard se
complète (`/Startup/Complete` réussit), laissant Jellyfin sans utilisateur.

**Solution dans le bootstrap** :
1. Attendre que `GET /Startup/User` retourne **200** (max 90s, toutes les 3s)
2. Seulement alors POSTer le compte admin
3. Retry POST 10 fois si réponse transitoire

### État du wizard — codes HTTP

| Endpoint | Avant wizard | Wizard en cours | Wizard terminé |
|----------|-------------|-----------------|----------------|
| `GET /Startup/Configuration` | 503 → 200 | 200 | 401/200* |
| `GET /Startup/User` | N/A | 200 | 401 |
| `POST /Startup/User` | N/A | 204 ✓ | 404 |
| `GET /System/Info/Public` `.StartupWizardCompleted` | `false` | `false` | `true` |

*Après le wizard, les endpoints /Startup/* peuvent retourner 401 (non autorisé).

### `caleope remove` ne supprime pas app-data

`caleope remove jellyfin` arrête les containers mais **conserve** les données
(`app-data/jellyfin/`). Ainsi :
- La réinstallation (`caleope install jellyfin`) retrouve les données existantes
- `setup.sh` détecte la DB existante et fait le ménage (`rm -rf data/ log/ root/`)
- Les credentials sont conservés si `secrets.env` existe

Si le container est orphelin (Caleope a perdu le tracking mais Docker a encore le container) :
```bash
sudo docker stop jellyfin && sudo docker rm jellyfin
```
Puis relancer `caleope install jellyfin`.

---

## Ce qui reste intentionnellement manuel

1. **Bibliothèques médias** : Films, Séries, Musique — à ajouter dans l'UI
2. **Comptes utilisateurs** : seul le compte admin est créé, les autres sont à créer manuellement
3. **Plugins Jellyfin** : à installer via l'UI selon les besoins
