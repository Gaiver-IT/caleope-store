#!/bin/bash
# Installation non interactive de Centreon.
#
# Centreon fournit un installeur officiel (unattended.sh) qui rejoue lui-même
# son formulaire web par 12 requêtes HTTP. On reprend EXACTEMENT cette séquence,
# parce que c'est l'éditeur qui la maintient — mais sans son script, qui exige
# systemd vivant (il fait des `systemctl restart`) et meurt dans un conteneur.
#
# On ajoute les deux choses que Centreon ne fait pas :
#   1. VÉRIFIER que le formulaire a réussi (leur script se contente de
#      journaliser le code HTTP sans jamais le tester : un Centreon à moitié
#      installé ressort en « successfully installed ») ;
#   2. ARMER la supervision (les moteurs sont installés mais jamais démarrés,
#      et aucune configuration n'est générée).
set -uo pipefail

MARQUE=/var/lib/centreon/.caleope-installe
BASE="http://127.0.0.1/centreon"

log() { echo "[centreon-init] $*"; }
mourir() { echo "[centreon-init] ✗ $*" >&2; exit 1; }

: "${CENTREON_ADMIN_EMAIL:=admin@localhost}"
: "${CENTREON_ADMIN_FIRSTNAME:=Admin}"
: "${CENTREON_ADMIN_LASTNAME:=Centreon}"
: "${CENTREON_DB_HOST:=centreon-db}"
: "${CENTREON_DB_PORT:=3306}"

attendre_base() {
  log "attente de la base ${CENTREON_DB_HOST}:${CENTREON_DB_PORT}"
  for i in $(seq 1 120); do
    (echo > "/dev/tcp/${CENTREON_DB_HOST}/${CENTREON_DB_PORT}") >/dev/null 2>&1 && return 0
    sleep 2
  done
  mourir "base injoignable après 4 minutes"
}

# Les moteurs sont en autostart=false : sans configuration générée, centengine
# sort en erreur et supervisor le relancerait en boucle. C'est donc à ce script
# de les démarrer — À CHAQUE DÉMARRAGE, pas seulement à l'installation.
SUP="supervisorctl -c /etc/supervisor/supervisord.conf"

demarrer_moteurs() {
  # ⚠️ COURSE AU DÉMARRAGE, mesurée le 12/08/2026. L'entrypoint lance supervisord
  # et ce script EN PARALLÈLE. Sur le chemin « déjà installé », on arrive ici en
  # une fraction de seconde — avant que supervisord ait ouvert sa prise.
  # `supervisorctl` répondait alors « unix:///var/run/supervisor.sock no such
  # file », et le script annonçait quand même « moteurs relancés ». Résultat :
  # après chaque redémarrage, interface parfaitement vivante et supervision
  # morte. Un garde-fou qui ne vérifie pas son propre résultat ne garde rien.
  # ⚠️ Ne PAS sonder avec « supervisorctl status » : il sort en code 3 dès qu'un
  # programme est à l'arrêt — et ici les moteurs le sont par conception. La
  # sonde ne réussissait donc jamais et l'installation neuve échouait à son
  # tour. « supervisorctl pid » ne dépend que de la connexion à la prise.
  local i manquants
  for i in $(seq 1 60); do
    $SUP pid >/dev/null 2>&1 && break
    [ "$i" = 60 ] && { log "✗ supervisord n'a pas ouvert sa prise après 2 min"; return 1; }
    sleep 2
  done

  log "démarrage des moteurs"
  $SUP start gorgoned cbd centengine reload-watch 2>&1 | sed 's/^/  /'

  # On vérifie au lieu d'annoncer.
  for i in $(seq 1 30); do
    manquants=$(for p in gorgoned cbd centengine reload-watch; do
                  $SUP status "$p" 2>/dev/null | grep -q RUNNING || printf '%s ' "$p"
                done)
    [ -z "$manquants" ] && { log "  ✓ moteurs en marche (gorgoned, cbd, centengine, veilleur)"; return 0; }
    sleep 2
  done
  log "✗ moteurs toujours à l'arrêt après 1 min : ${manquants}"
  log "  la supervision ne tourne PAS — voir docker logs"
  return 1
}

# ⚠️ PIÈGE MESURÉ LE 12/08/2026, ET C'EST LE PLUS SOURNOIS DE TOUS.
# Ce script se contentait de sortir quand l'installation était déjà faite. Après
# un redémarrage du conteneur — mise à jour d'image, `caleope restart centreon`,
# reboot du serveur — apache et php repartaient (autostart=true), l'interface
# répondait, les graphes d'hier s'affichaient... et gorgoned, cbd, centengine
# restaient à l'arrêt. Centreon avait l'air parfaitement vivant et ne supervisait
# plus RIEN. Une supervision qui ment est pire que pas de supervision.
if [ -f "$MARQUE" ]; then
  log "déjà installé — on remonte la supervision"
  attendre_base
  if demarrer_moteurs; then
    log "✅ supervision remontée après redémarrage"
    exit 0
  fi
  mourir "la supervision n'a PAS redémarré — l'interface répondra quand même, ne pas s'y fier"
fi

for v in CENTREON_ADMIN_PASSWORD CENTREON_DB_ROOT_PASSWORD CENTREON_DB_PASSWORD; do
  [ -n "${!v:-}" ] || mourir "variable $v manquante"
done

attendre_base

log "attente du serveur web"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/install/install.php" 2>/dev/null)
  [ "$code" = "200" ] && break
  [ "$i" = 60 ] && mourir "le web ne répond pas (dernier code : ${code:-aucun})"
  sleep 2
done

# ── Le formulaire, rejoué ────────────────────────────────────────────────────
COOKIE=$(curl -s -i "${BASE}/install/install.php" | awk '/[Ss]et-[Cc]ookie/{print $2}' | head -1 | tr -d ';')
[ -n "$COOKIE" ] || mourir "aucun cookie de session obtenu"
curl -s -H "Cookie: ${COOKIE}" "${BASE}/install/steps/step.php?action=stepContent" >/dev/null

etape() { # $1 = script, $2 = corps
  local code
  code=$(curl -s -o /tmp/rep.$$ -w '%{http_code}' "${BASE}/install/steps/process/$1" \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    -H "Cookie: ${COOKIE}" --data "${2:-}")
  if [ "$code" != "200" ]; then
    log "✗ étape $1 → HTTP $code"; head -c 400 /tmp/rep.$$ >&2; echo >&2
    rm -f /tmp/rep.$$; return 1
  fi
  log "  $1 → 200"
  rm -f /tmp/rep.$$
}

set -e
etape process_step3.php 'centreon_engine_stats_binary=%2Fusr%2Fsbin%2Fcentenginestats&monitoring_var_lib=%2Fvar%2Flib%2Fcentreon-engine&centreon_engine_connectors=%2Fusr%2Flib64%2Fcentreon-connector&centreon_engine_lib=%2Fusr%2Flib64%2Fcentreon-engine&centreonplugins=%2Fusr%2Flib%2Fcentreon%2Fplugins%2F'
etape process_step4.php 'centreonbroker_etc=%2Fetc%2Fcentreon-broker&centreonbroker_cbmod=%2Fusr%2Flib64%2Fnagios%2Fcbmod.so&centreonbroker_log=%2Fvar%2Flog%2Fcentreon-broker&centreonbroker_varlib=%2Fvar%2Flib%2Fcentreon-broker&centreonbroker_lib=%2Fusr%2Fshare%2Fcentreon%2Flib%2Fcentreon-broker'
etape process_step5.php "admin_password=${CENTREON_ADMIN_PASSWORD}&confirm_password=${CENTREON_ADMIN_PASSWORD}&firstname=${CENTREON_ADMIN_FIRSTNAME}&lastname=${CENTREON_ADMIN_LASTNAME}&email=${CENTREON_ADMIN_EMAIL}"
etape process_step6.php "address=${CENTREON_DB_HOST}&port=${CENTREON_DB_PORT}&root_user=root&root_password=${CENTREON_DB_ROOT_PASSWORD}&db_configuration=centreon&db_storage=centreon_storage&db_user=centreon&db_password=${CENTREON_DB_PASSWORD}&db_password_confirm=${CENTREON_DB_PASSWORD}"
etape configFileSetup.php
etape installConfigurationDb.php
etape installStorageDb.php
etape createDbUser.php
etape insertBaseConf.php
etape partitionTables.php
etape generationCache.php
etape process_step8.php 'modules%5B%5D=centreon-license-manager&modules%5B%5D=centreon-pp-manager&modules%5B%5D=centreon-autodiscovery-server&widgets%5B%5D=engine-status&widgets%5B%5D=global-health&widgets%5B%5D=graph-monitoring&widgets%5B%5D=grid-map&widgets%5B%5D=host-monitoring&widgets%5B%5D=hostgroup-monitoring&widgets%5B%5D=httploader&widgets%5B%5D=live-top10-cpu-usage&widgets%5B%5D=live-top10-memory-usage&widgets%5B%5D=service-monitoring&widgets%5B%5D=servicegroup-monitoring&widgets%5B%5D=tactical-overview&widgets%5B%5D=single-metric'
# send_statistics=0 : pas de télémétrie sans consentement explicite.
etape process_step9.php 'send_statistics=0'
set +e

# ── LA VÉRIFICATION QUE CENTREON NE FAIT PAS ─────────────────────────────────
log "vérification : ouverture de session par l'API"
jeton=$(curl -s -X POST "${BASE}/api/latest/login" \
  -H 'Content-Type: application/json' \
  -d "{\"security\":{\"credentials\":{\"login\":\"admin\",\"password\":\"${CENTREON_ADMIN_PASSWORD}\"}}}" \
  | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
[ -n "$jeton" ] || mourir "l'API refuse la connexion : l'installation n'a PAS abouti"
log "  ✓ jeton obtenu (${#jeton} caractères) — installation réellement fonctionnelle"

# ── ARMER LA SUPERVISION ─────────────────────────────────────────────────────
log "génération et application de la configuration"
/usr/share/centreon/bin/centreon -u admin -p "${CENTREON_ADMIN_PASSWORD}" -a APPLYCFG -v 1 || \
  log "⚠ APPLYCFG en échec — les moteurs démarreront quand même, à vérifier"

demarrer_moteurs || mourir "les moteurs n'ont pas démarré : Centreon est installé mais ne supervise rien"

# ── PREMIER HÔTE RÉELLEMENT SUPERVISÉ ────────────────────────────────────────
# Sans ce bloc, l'installation se termine sur une supervision VIDE : zéro hôte,
# zéro commande de contrôle. L'utilisateur ouvre une console de supervision qui
# ne supervise rien, et doit deviner qu'il faut commencer par créer une commande.
#
# ⚠️ Créer l'hôte ne suffit pas. Un hôte sans commande de contrôle entre en base
# de supervision avec l'état 4 — « pending » — et n'est JAMAIS contrôlé :
# last_check reste à 0, aucun résultat. C'est un faux vivant, pire qu'une page
# vide, parce qu'il ressemble à une supervision qui marche.
# Mesuré le 13/08/2026 : avec la commande, l'hôte passe à l'état 0 (UP) avec un
# last_check réel en moins d'une minute.
CLI="/usr/share/centreon/bin/centreon -u admin -p ${CENTREON_ADMIN_PASSWORD}"

log "création du premier hôte supervisé (le serveur lui-même)"
$CLI -o CMD -a ADD \
  -v 'caleope-check-ping;check;$USER1$/check_ping -H $HOSTADDRESS$ -w 3000,80% -c 5000,100% -p 3' \
  >/dev/null 2>&1
$CLI -o HOST -a ADD -v 'Central-Caleope;Serveur Caleope;127.0.0.1;;Central;' >/dev/null 2>&1
# ⚠️ LE RÉGLAGE QUI DÉCIDE DE TOUT : « check_interval ». Sans lui, l'hôte est
# créé, exporté, présent dans hosts.cfg — et le moteur ne le planifie JAMAIS.
# Il reste à l'état 4 (« pending »), last_check à 0, sans le moindre résultat.
# Une console de supervision qui affiche un hôte jamais contrôlé est pire qu'une
# console vide : elle a l'air de marcher.
#
# Le nom du paramètre se cherche : le CLAPI de la 24.10 refuse
# « normal_check_interval » (« Please check that your parameters are valid »)
# et accepte « check_interval ». Vérifié en base : host_check_interval = 5.
for reglage in 'check_command;caleope-check-ping' 'check_period;24x7' \
               'max_check_attempts;3' 'check_interval;1' 'retry_check_interval;1' \
               'active_checks_enabled;1' 'notifications_enabled;0'; do
  $CLI -o HOST -a setparam -v "Central-Caleope;${reglage}" >/dev/null 2>&1
done
$CLI -a APPLYCFG -v 1 2>&1 | grep -E 'Total Errors|reload signal' | sed 's/^/  /'

# On VÉRIFIE que l'hôte est contrôlé, pas seulement inscrit. La table de
# supervision est interrogée par l'API : ce script n'a pas de client mysql.
log "vérification : le premier hôte est-il réellement contrôlé ?"
etat_hote() {
  curl -s "${BASE}/api/latest/monitoring/hosts?search=%7B%22name%22:%22Central-Caleope%22%7D" \
    -H "X-AUTH-TOKEN: ${jeton}" \
    | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for h in (d.get("result") or []):
    print(h.get("state"), h.get("last_check") or 0, (h.get("output") or "").strip()[:60], sep="|")
' 2>/dev/null | head -1
}
controle=""
for _ in $(seq 1 48); do
  ligne=$(etat_hote)
  lc=$(echo "$ligne" | cut -d'|' -f2)
  case "$lc" in ''|0|None) sleep 5;; *) controle="$ligne"; break;; esac
done
if [ -n "$controle" ]; then
  log "  ✓ Central-Caleope contrôlé — état ${controle%%|*}, résultat « ${controle##*|} »"
else
  log "  ⚠ Central-Caleope créé mais pas encore contrôlé après 4 min."
  log "    L'interface l'affichera « en attente ». Voir Configuration ▸ Hôtes."
fi

# Le script officiel laisse les mots de passe en clair dans ce fichier.
rm -f /etc/centreon/generated.tobesecured

# La marque n'est posée qu'ici, une fois TOUT vérifié : jeton d'API obtenu et
# moteurs en marche. Poser la marque plus tôt ferait sauter l'installation au
# redémarrage suivant sur une base à moitié faite.
touch "$MARQUE"
log "✅ Centreon installé, vérifié, supervision armée"
