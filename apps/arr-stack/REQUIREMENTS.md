# Arr Stack — Exigences d'automatisation

> Tout ce qui est listé ici doit être configuré **automatiquement** au premier démarrage,
> sans aucune intervention manuelle, sauf les exceptions explicitement marquées *(manuel)*.

---

## Langue

| Service | Cible | État |
|---------|-------|------|
| Prowlarr | Interface **française** (`uiLanguage` via API) | ✅ |
| Radarr | Interface **française** | ✅ |
| Sonarr | Interface **française** | ✅ |
| Lidarr | Interface **française** | ✅ |
| Bazarr | Profil sous-titres **Français + Anglais** (FR priorité, EN fallback) | ✅ |
| Jellyfin | Métadonnées FR + interface FR (`PreferredMetadataLanguage=fr`, `UICulture=fr-FR`) | ✅ si embarqué |
| Jellyseerr | Interface **française** (`locale: fr`) | ✅ si Jellyfin connecté |

---

## Connexions inter-services (tout via réseau Docker interne)

### Prowlarr
- [x] Connecté à **Radarr** (fullSync, catégories films)
- [x] Connecté à **Sonarr** (fullSync, catégories séries)
- [x] Connecté à **Lidarr** (fullSync, catégories musique)
- [x] **FlareSolverr** configuré comme proxy indexer (`http://arr-flaresolverr:8191`)
- [x] **YTS** ajouté automatiquement (films, public, pas de CloudFlare)
- [x] **1337x** ajouté en désactivé (CloudFlare → activer après avoir assigné FlareSolverr dans Prowlarr)
- [x] **EZTV** ajouté en désactivé (CloudFlare → même chose)
- *(manuel)* Indexeurs privés à ajouter (YGGTorrent, BetaSeries, etc. — nécessitent un compte)

> **Note technique** : Prowlarr valide l'URL à la création d'un indexeur. Pour les sites
> protégés par CloudFlare, la validation échoue même si FlareSolverr est configuré (le proxy
> n'est actif qu'après l'enregistrement). Solution : indexeur créé avec `enable:false`
> (bypass de la validation), à activer manuellement depuis l'UI Prowlarr une fois le tag
> FlareSolverr assigné.

### Radarr
- [x] Client torrent : **qBittorrent** (host=`qbittorrent` ou `arr-gluetun` selon profil VPN)
- [x] Client Usenet : **SABnzbd** (host=`sabnzbd`, port=8080)
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

> **Note technique Bazarr** : L'API Bazarr ne fournit qu'un `GET` sur
> `/api/system/languages/profiles` — aucun `POST` pour créer des profils.
> La création passe par `POST /api/system/settings` avec le champ form-data
> `languages-profiles` (JSON). La clé API est lue depuis `config/config.yaml`
> (`auth.apikey`) après le démarrage de Bazarr.

### Jellyfin (si embarqué — `JELLYFIN_MODE=embedded`)
- [x] Wizard de démarrage complété automatiquement (compte admin créé, credentials dans post-install)
- [x] Bibliothèques créées : Films → `/media/movies` · Séries → `/media/tv` · Musique → `/media/music`
- [x] Métadonnées + interface en français
- *(manuel)* Comptes utilisateurs supplémentaires

### Jellyfin (si existant — `JELLYFIN_MODE=external`)
- [x] Détecté automatiquement via `runtime/apps/jellyfin.json` (instance Caleope)
- [x] URL résolue à `http://jellyfin:8096` (bootstrap sur réseau `caleope-public` → accès direct)
- [x] Jellyseerr auto-configuré **si credentials fournis** via `JELLYFIN_EXT_USER` + `JELLYFIN_EXT_PASSWORD`
- *(manuel)* Jellyseerr si credentials non fournis

### Jellyseerr
- [x] Connecté à **Jellyfin** (embedded : compte créé auto / externe : credentials params)
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

- [x] Configurable via `params.json` : `VPN_ENABLED`, `VPN_PROVIDER`, `VPN_TYPE`, credentials WG/OpenVPN
- [x] Wizard interactif en fallback si params non fournis
- [x] Providers supportés : ProtonVPN, Mullvad, NordVPN, PIA, Surfshark, ExpressVPN, custom
- [x] Protocoles : WireGuard, OpenVPN
- [x] Profil Docker Compose switché automatiquement (`novpn` ↔ `vpn`)

---

## qBittorrent

- [x] Accès sans mot de passe (auth désactivée, subnet whitelist LAN)
- [x] Legal notice acceptée automatiquement (config pré-écrite)
- [x] Config pré-écrite pour v4 et v5 (linuxserver/qbittorrent migration)
- *(info)* L'UI est accessible sans auth depuis le réseau local — c'est intentionnel

---

## SABnzbd

- [x] `host_whitelist = sabnzbd.<domain>` → accès sans erreur hostname check
- [x] Clé API pré-générée et partagée aux *arr
- [x] Catégories créées avant connexion aux *arr (movies, tv, music, books, software)
- [x] Configuré dans Radarr, Sonarr, Lidarr
- *(manuel)* Provider Usenet : à configurer dans Settings → Servers

---

## Réseaux Docker

| Réseau | Conteneurs |
|--------|-----------|
| `arr-internal` | Tous les services arr + bootstrap |
| `caleope-public` | Jellyseerr, Jellyfin (si embarqué), Radarr, Sonarr, etc. + bootstrap |

> `arr-bootstrap` est sur les deux réseaux pour pouvoir atteindre le Jellyfin
> Caleope-managed (sur `caleope-public`) même quand il n'est pas embarqué dans la stack.

---

## params.json — paramètres configurables à l'install

| Param | Type | Défaut | Quand |
|-------|------|--------|-------|
| `STORAGE_PATH` | string | (défaut Caleope) | toujours |
| `JELLYFIN_MODE` | select | `embedded` | toujours |
| `JELLYFIN_URL` | string | — | `external` |
| `JELLYFIN_EXT_USER` | string | `admin` | `external` |
| `JELLYFIN_EXT_PASSWORD` | secret | — | `external` |
| `VPN_ENABLED` | bool | `false` | toujours |
| `VPN_PROVIDER` | select | `protonvpn` | VPN activé |
| `VPN_TYPE` | select | `wireguard` | VPN activé |
| `VPN_WG_PRIVATE_KEY` | secret | — | WireGuard |
| `VPN_WG_ADDRESSES` | string | — | WireGuard |
| `VPN_OPENVPN_USER` | string | — | OpenVPN |
| `VPN_OPENVPN_PASSWORD` | secret | — | OpenVPN |
| `VPN_SERVER_COUNTRIES` | string | — | VPN activé |

---

## Post-install attendu

Après `caleope install arr-stack`, les notes affichées montrent :
- URLs correctes de tous les services
- Statut VPN réel
- Credentials Jellyfin admin (si embarqué)
- Liste des connexions configurées automatiquement

---

## Ce qui reste intentionnellement manuel

1. **Prowlarr → Indexeurs privés** : YGGTorrent, BetaSeries, etc. (nécessitent un compte)
2. **Prowlarr → Activer 1337x/EZTV** : après avoir assigné le tag FlareSolverr dans Prowlarr
3. **SABnzbd → Provider Usenet** : credentials sensibles, à saisir dans l'UI
4. **Bazarr → Providers de sous-titres** : OpenSubtitles, etc. (nécessitent un compte)
5. **Jellyseerr → Jellyfin** : si mode external sans credentials fournis
