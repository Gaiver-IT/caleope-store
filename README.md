# caleope-store

Dépôt officiel des applications Caleope.

## Branches

| Branche | Canal | Usage |
|---------|-------|-------|
| `main` | stable | Production |
| `alpha` | alpha | Tests bêta / nouvelles fonctionnalités |

---

## Tester une modification (canal alpha)

### 1. Synchroniser le cache store sur le serveur

Après avoir commité et poussé sur `origin/alpha`, mettre à jour le cache sur le serveur de test :

```bash
sudo git -C /opt/gaiver-it/caleope/core/cache/official fetch origin alpha
sudo git -C /opt/gaiver-it/caleope/core/cache/official reset --hard FETCH_HEAD
```

Vérifier le commit courant :
```bash
git -C /opt/gaiver-it/caleope/core/cache/official log --oneline -3
```

### 2. Réinstaller l'application

```bash
# Réinstall complète (--force = réinstall même si déjà installée)
sudo caleope install <app> --force

# Exemples
sudo caleope install jellyfin --force
sudo caleope install authentik --force
```

> **Note :** `caleope update` sert uniquement à mettre à jour l'image Docker d'une app (nouvelle version upstream). Pour appliquer un changement de `setup.sh` ou `docker-compose.yml`, utiliser `caleope install --force`.

### 3. Vérifier les logs

```bash
# Logs d'une app
sudo caleope logs <app>

# Logs bootstrap (container one-shot)
sudo docker logs <app>-bootstrap

# Status containers
sudo docker ps --filter "name=<app>"
```

---

## Structure d'une app

```
apps/<app>/
├── app.json            # Manifest (id, ports, volumes, capabilities)
├── docker-compose.yml  # Template compose ({{.Domain}}, {{.BaseDir}}, {{.Ports}})
├── setup.sh            # Préparation (secrets, bootstrap.sh, post-install.txt)
├── params.json         # Paramètres interactifs (CALEOPE_PARAM_*)
└── REQUIREMENTS.md     # Dépendances entre apps (optionnel)
```

### Variables injectées dans setup.sh

| Variable | Exemple |
|----------|---------|
| `CALEOPE_BASE_DIR` | `/opt/gaiver-it/caleope` |
| `CALEOPE_APP_ID` | `jellyfin` |
| `CALEOPE_APP_DIR` | `/opt/gaiver-it/caleope/apps-installed/jellyfin` |
| `CALEOPE_DOMAIN` | `jellyfin.caleope-redberry.guernaham.bzh` |
| `CALEOPE_APP_DATA_DIR` | `/opt/gaiver-it/caleope/app-data/jellyfin` |
| `CALEOPE_PARAM_<ID>` | Valeurs des params.json |

### Rendre une variable disponible pour docker compose

Le daemon (`buildEnvFile`) écrase `apps-installed/<app>/app.env` après `setup.sh`.  
Pour qu'une variable soit disponible dans le template docker-compose (ex: `${MA_VAR}`), l'écrire dans `app-config/<app>/secrets.env` — ce fichier est fusionné automatiquement :

```bash
# Dans setup.sh (après avoir calculé MA_VAR) :
if grep -q "^MA_VAR=" "${_SECRETS}" 2>/dev/null; then
    sed -i "s|^MA_VAR=.*|MA_VAR=${MA_VAR}|" "${_SECRETS}"
else
    printf "MA_VAR=%s\n" "${MA_VAR}" >> "${_SECRETS}"
fi
```
