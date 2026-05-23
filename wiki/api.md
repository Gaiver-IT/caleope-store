---
title: API REST
description: Référence complète de l'API REST Caleope
published: true
date: 2026-05-23
---

# API REST

Caleope expose une API REST sur le port **8765** pour l'intégration avec des scripts ou des interfaces externes.

## Authentification

```bash
# Récupérer le token
caleope token
# 🔑 Token API : 330c35c7a1b2...

# Utiliser dans curl
curl -H "Authorization: Bearer <TOKEN>" http://localhost:8765/api/v1/apps
```

---

## Routes disponibles

### Système

| Méthode | Route | Auth | Description |
|---------|-------|------|-------------|
| `GET` | `/api/v1/ping` | ❌ | État du daemon |
| `GET` | `/api/v1/stats` | ✅ | Stats CPU, RAM, disque |

#### GET /api/v1/ping
```json
{ "status": "ok", "version": "v0.4.7" }
```

#### GET /api/v1/stats
```json
{
  "ram_used_mb": 1842,
  "ram_total_mb": 3941,
  "disk_used_gb": 12.5,
  "disk_total_gb": 50.0
}
```

---

### Applications

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/v1/apps` | Liste toutes les apps installées |
| `GET` | `/api/v1/apps/{id}` | Détails d'une app |
| `POST` | `/api/v1/apps/{id}/start` | Démarrer une app |
| `POST` | `/api/v1/apps/{id}/stop` | Arrêter une app |
| `POST` | `/api/v1/apps/{id}/restart` | Redémarrer une app |
| `DELETE` | `/api/v1/apps/{id}` | Désinstaller une app |

#### GET /api/v1/apps
```json
[
  {
    "id": "jellyfin",
    "name": "Jellyfin",
    "status": "running",
    "port": 8234,
    "domain": "media.home.local",
    "installed_at": "2026-05-20T14:32:11Z"
  }
]
```

#### GET /api/v1/apps/{id}
```json
{
  "id": "nextcloud",
  "name": "Nextcloud",
  "status": "running",
  "port": 8456,
  "domain": "cloud.home.local",
  "installed_at": "2026-05-18T09:15:44Z",
  "storage_location": "mon-nas"
}
```

---

### Événements

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/v1/events` | Historique des événements |

**Paramètres query :**
- `limit` — nombre d'événements (défaut: 50)
- `app` — filtrer par application
- `type` — filtrer par type d'événement

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8765/api/v1/events?limit=20&app=nextcloud"
```

```json
[
  {
    "timestamp": "2026-05-22T18:42:11Z",
    "type": "app_started",
    "app": "jellyfin",
    "details": ""
  },
  {
    "timestamp": "2026-05-22T16:00:00Z",
    "type": "backup_created",
    "app": "nextcloud",
    "details": "size=245MB"
  }
]
```

---

### Emplacements réseau

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/v1/locations` | Liste les emplacements réseau |

```json
[
  {
    "name": "mon-nas",
    "type": "smb",
    "host": "192.168.1.10",
    "share": "nas",
    "mounted": true
  }
]
```

---

## Exemples complets

### Script de monitoring

```bash
#!/bin/bash
TOKEN=$(caleope token | grep Token | awk '{print $NF}')
BASE="http://localhost:8765/api/v1"

# Vérifier toutes les apps
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/apps" | \
  jq '.[] | select(.status != "running") | "⚠️  \(.name) est \(.status)"'
```

### Démarrer toutes les apps arrêtées

```bash
TOKEN=$(caleope token | grep Token | awk '{print $NF}')
BASE="http://localhost:8765/api/v1"

curl -s -H "Authorization: Bearer $TOKEN" "$BASE/apps" | \
  jq -r '.[] | select(.status == "stopped") | .id' | \
  while read id; do
    curl -s -X POST -H "Authorization: Bearer $TOKEN" "$BASE/apps/$id/start"
    echo "✓ $id démarré"
  done
```
