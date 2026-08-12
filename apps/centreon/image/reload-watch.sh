#!/bin/bash
# Recharge le moteur quand sa configuration change.
#
# POURQUOI CE VEILLEUR EXISTE
# Quand l'utilisateur applique une configuration, Centreon écrit les fichiers du
# moteur puis demande à gorgone de le recharger. Dans un conteneur, ce signal
# n'arrive JAMAIS — et l'échec est muet : Centreon affiche « OK: A reload signal
# has been sent to 'Central' » et rend le code 0. Le moteur continue sur son
# ancienne configuration, l'utilisateur croit avoir déployé, et ses nouveaux
# hôtes ne remontent jamais.
#
# J'ai remonté la chaîne le 12/08/2026 : la commande en base est « systemctl
# restart centengine » (sans sudo), or la liste blanche de gorgone n'accepte ce
# motif QU'AVEC sudo — la commande est donc rejetée sans un mot. Ajouter notre
# propre motif à la liste blanche n'a pas suffi non plus.
#
# Plutôt que de continuer à rétro-concevoir un mécanisme conçu pour systemd, on
# assume : dans un conteneur, c'est supervisor qui pilote les processus, donc
# c'est à nous de recharger. Ce veilleur surveille l'empreinte des fichiers de
# configuration et relance le moteur dès qu'elle bouge.
#
# Conséquence assumée : un rechargement est un redémarrage du moteur (quelques
# secondes sans collecte). Sur une appliance mono-collecteur, c'est acceptable ;
# ce serait discutable sur un parc de plusieurs milliers d'hôtes.
set -u
CFG=/etc/centreon-engine
SUP="supervisorctl -c /etc/supervisor/supervisord.conf"

empreinte() { cat "$CFG"/*.cfg 2>/dev/null | md5sum | cut -d' ' -f1; }

# On attend que le moteur tourne avant de mémoriser une première empreinte,
# sinon le tout premier passage déclencherait un redémarrage inutile.
while ! $SUP status centengine 2>/dev/null | grep -q RUNNING; do sleep 5; done
REF=$(empreinte)
echo "[reload-watch] surveillance active (empreinte ${REF:0:12})"

while true; do
  sleep 10
  NOUV=$(empreinte)
  [ "$NOUV" = "$REF" ] && continue
  echo "[reload-watch] configuration modifiée (${REF:0:12} → ${NOUV:0:12}) — rechargement du moteur"
  REF="$NOUV"
  # On laisse Centreon finir d'écrire : APPLYCFG copie plusieurs fichiers.
  sleep 3
  REF=$(empreinte)
  if $SUP restart centengine >/dev/null 2>&1; then
    echo "[reload-watch] ✓ moteur rechargé"
  else
    echo "[reload-watch] ✗ échec du rechargement du moteur" >&2
  fi
done
