# Arr Stack — Exigences d'automatisation

> Tout ce qui est listé ici doit être configuré **automatiquement** au premier démarrage,
> sans aucune intervention manuelle, sauf les exceptions explicitement marquées *(manuel)*.

---

## Langue

| Service | Cible |
|---------|-------|
| Prowlarr | Interface **française** (`uiLanguage` via API) |
| Radarr | Interface **française** |
| Sonarr | Interface **française** |
| Lidarr | Interface **française** |
| Bazarr | Profil sous-titres **Français + Anglais** (FR priorité, EN fallback) |
| Jellyfin | Métadonnées FR + interface FR (`PreferredMetadataLanguage=fr`, `UICulture=fr-FR`) |
| Jellyseerr | Interface **française** (`locale: fr`) |

---

## Connexions inter-services (tout via réseau Docker interne)

### Prowlarr
- [x] Connecté à **Radarr** (fullSync, catégories films)
- [x] Connecté à **Sonarr** (fullSync, catégories séries)
- [x] Connecté à **Lidarr** (fullSync, catégories musique)
- [x] **FlareSolverr** configuré comme proxy indexer (`http://arr-flaresolverr:8191`)
- *(manuel)* Indexeurs à ajouter manuellement (YggTorrent, 1337x, etc.)

### Radarr
- [x] Client torrent : **qBittorrent** (host=`qbittorrent` ou `arr-gluetun` selon profil VPN)
- [x] Client Usenet : **SABnzbd** (host=`sabnzbd`, port=8080, urlBase=`/`)
- [x] Dossier racine : `/data/media/movies`
- [x] Interface française

### Sonarr
- [x] Client torrent : **qBittorrent**
- [x] Client Usenet : **SABnzbd**
- [x] Dossier racine : `/data/media/tv`
- [x] Interface française

### Lidarr
- [x] Client torrent : **qBittorrent**
- [x] Client Usenet : **SABnzbd**
- [x] Dossier racine : `/data/media/music`
- [x] Interface française

### Bazarr
- [x] Connecté à **Sonarr** (via `config.ini` au démarrage : host=`sonarr`, port=8989)
- [x] Connecté à **Radarr** (via `config.ini` : host=`radarr`, port=7878)
- [x] Profil sous-titres **Français + Anglais** créé et appliqué à toutes les séries/films

### Jellyfin
- [x] Wizard de démarrage complété automatiquement (compte admin créé, credentials dans post-install)
- [x] Bibliothèques créées :
  - Films → `/media/movies`
  - Séries → `/media/tv`
  - Musique → `/media/music`
- [x] Métadonnées + interface en français
- *(manuel)* Compte utilisateur final (admin est dans les notes post-install)

### Jellyseerr
- [x] Connecté à **Jellyfin** (`http://jellyfin:8096`)
- [x] Connecté à **Radarr** (profil 1, dossier `/data/media/movies`)
- [x] Connecté à **Sonarr** (profil 1, dossier `/data/media/tv`)
- [x] Interface française

---

## Accès web (sous-domaines)

| Service | URL |
|---------|-----|
| Jellyseerr | `https://jellyseerr.<domain>` |
| Jellyfin | `https://jellyfin.<domain>` |
| Jellyfin Vue | `https://vue.<domain>` |
| Prowlarr | `https://prowlarr.<domain>` |
| Radarr | `https://radarr.<domain>` |
| Sonarr | `https://sonarr.<domain>` |
| Lidarr | `https://lidarr.<domain>` |
| Bazarr | `https://bazarr.<domain>` |
| qBittorrent | `https://qbt.<domain>` |
| SABnzbd | `https://sabnzbd.<domain>` |
| FlareSolverr | Interne uniquement (`http://arr-flaresolverr:8191`) |

> DNS requis : `*.<domain>` → IP du serveur (wildcard)

---

## VPN (qBittorrent via Gluetun)

- [x] Wizard interactif au premier `caleope install arr-stack`
- [x] Reconfigurable via `caleope configure arr-stack`
- [x] Providers supportés : ProtonVPN, Mullvad, NordVPN, PIA, Surfshark, ExpressVPN
- [x] Protocoles : WireGuard, OpenVPN
- [x] Profil Docker Compose switché automatiquement (`novpn` ↔ `vpn`)

---

## SABnzbd

- [x] `host_whitelist = sabnzbd.<domain>` → accès sans erreur hostname check
- [x] Configuré dans Radarr, Sonarr, Lidarr (clients de téléchargement)
- *(manuel)* Provider Usenet : à configurer dans Settings → Servers

---

## Post-install attendu

Après `caleope install arr-stack` + wizard VPN, les notes affichées doivent montrer :
- URLs correctes de tous les services
- Statut VPN réel (pas "désactivé" si VPN configuré)
- Credentials Jellyfin admin
- Credentials qBittorrent

---

## Ce qui reste intentionnellement manuel

1. **Prowlarr → Indexeurs** : au choix de l'utilisateur
2. **SABnzbd → Provider Usenet** : credentials sensibles, à saisir dans l'UI
3. **Jellyfin → Compte utilisateur** : admin créé auto, autres comptes manuels
