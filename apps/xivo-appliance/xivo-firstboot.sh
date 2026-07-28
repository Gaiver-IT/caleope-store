#!/bin/sh
# =============================================================================
# First-boot XiVO — lance l'installation OFFICIELLE de XiVO sur la Debian fraîche.
# Déposé par le preseed, activé en systemd oneshot. Se désactive après succès.
# Tout vient de sources officielles : xivo_install.sh + miroir mirror.xivo.solutions.
# =============================================================================
set -u
LOG=/var/log/xivo-appliance-firstboot.log
DONE=/opt/xivo-appliance/.installed
MIRROR="http://mirror.xivo.solutions"

# Version XiVO à installer (release/codename officiel). À CONFIRMER contre
# `xivo_install.sh -h` au build ; XiVO utilise des codenames de release.
# Vide => xivo_install.sh installe la dernière production stable par défaut.
XIVO_VERSION="${XIVO_VERSION:-}"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

[ -f "$DONE" ] && { log "XiVO déjà installé, rien à faire."; exit 0; }

log "=== First-boot XiVO : démarrage ==="

# 1) Attendre le réseau (résolution + accès au miroir), max ~5 min
i=0
while [ "$i" -lt 60 ]; do
    if wget -q --spider "$MIRROR/xivo_install.sh" 2>/dev/null; then
        log "Miroir XiVO joignable."
        break
    fi
    i=$((i+1)); log "Attente réseau/miroir ($i)..."; sleep 5
done
if ! wget -q --spider "$MIRROR/xivo_install.sh" 2>/dev/null; then
    log "ERREUR: miroir XiVO injoignable après 5 min. On réessaiera au prochain boot."
    exit 1   # oneshot restera enabled -> retry au reboot
fi

# 2) Récupérer le script d'installation officiel
cd /opt/xivo-appliance || exit 1
log "Téléchargement de xivo_install.sh ..."
if ! wget -q -O xivo_install.sh "$MIRROR/xivo_install.sh"; then
    log "ERREUR: échec du téléchargement de xivo_install.sh"; exit 1
fi
chmod +x xivo_install.sh

# 3) Lancer l'installation officielle, non-interactive.
#    xivo_install.sh gère l'ajout de la clé + du dépôt xivo-dist + apt install.
#    -a = mode automatique (pas de prompt) ; -d <version> si version épinglée.
log "Lancement de l'installation XiVO (version='${XIVO_VERSION:-stable par défaut}')..."
if [ -n "$XIVO_VERSION" ]; then
    yes '' | ./xivo_install.sh -a -d "$XIVO_VERSION" >>"$LOG" 2>&1
    rc=$?
else
    yes '' | ./xivo_install.sh -a >>"$LOG" 2>&1
    rc=$?
fi

if [ "$rc" -ne 0 ]; then
    log "ERREUR: xivo_install.sh a échoué (rc=$rc). Voir $LOG. Retry au prochain boot."
    exit 1
fi

# 4) Succès : marquer + désactiver le service
touch "$DONE"
log "=== XiVO installé avec succès. Web wizard dispo sur https://<ip>/ ==="
systemctl disable xivo-firstboot.service >>"$LOG" 2>&1 || true
exit 0
