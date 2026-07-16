#!/bin/bash
set -euo pipefail

# Service Samba de Caleope — sert les Partages (User Shares) en SMB.
# La config (smb.conf) et les utilisateurs sont gérés par le daemon
# depuis la page « Partages » ; ce setup ne fait que préparer les dossiers
# et un smb.conf minimal de démarrage.

BASE="${CALEOPE_BASE_DIR}"
CONFIG_DIR="${BASE}/app-config/caleope-samba"
SHARES_DIR="${BASE}/app-data/_shares"
PRIV_DIR="${BASE}/app-data/caleope-samba/private"

mkdir -p "${CONFIG_DIR}" "${SHARES_DIR}" "${PRIV_DIR}"

# smb.conf initial minimal (le daemon le régénère à chaque changement de partage).
# Ne pas écraser une config existante (idempotent).
if [ ! -f "${CONFIG_DIR}/smb.conf" ]; then
  cat > "${CONFIG_DIR}/smb.conf" <<'CONF'
# Généré par Caleope — ne pas éditer à la main
[global]
   workgroup = CALEOPE
   server string = Caleope
   security = user
   map to guest = never
   server min protocol = SMB2
   passdb backend = tdbsam
   load printers = no
   disable spoolss = yes
CONF
fi

# secrets.env (vide — requis par le pattern d'app Caleope)
: > "${CONFIG_DIR}/secrets.env"
chmod 600 "${CONFIG_DIR}/secrets.env"

echo "  ✓ Service Samba prêt — gère tes partages depuis la page « Partages »"

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │              Partages réseau (SMB) — service Samba                │
  ├──────────────────────────────────────────────────────────────────┤
  │  Le service tourne en réseau LAN (ports 139/445).                 │
  │                                                                    │
  │  → Crée et gère tes partages depuis la page « Partages ».         │
  │  → Chaque utilisateur définit son mot de passe réseau dans l'UI.  │
  │  → Monte un partage : \\\\<ip-caleope>\\<nom-du-partage>           │
  └──────────────────────────────────────────────────────────────────┘
INFO
