#!/bin/bash
# Traducteur systemd → supervisor.
#
# POURQUOI CE FICHIER EXISTE
# Centreon pilote ses services par systemd. Dans un conteneur il n'y en a pas,
# et l'échec est SILENCIEUX : quand on applique une configuration, Centreon
# annonce « A reload signal has been sent to 'Central' » et rend le code 0 —
# alors que rien n'a été envoyé. Le moteur continue de tourner sur son ancienne
# configuration, l'utilisateur voit « configuration déployée », et la supervision
# ne montre jamais les nouveaux hôtes. Constaté le 12/08/2026 : un hôte ajouté et
# appliqué n'apparaissait pas, jusqu'à ce qu'on relance le moteur à la main.
#
# Ce script rend les appels systemd fonctionnels en les traduisant pour
# supervisor. Il est placé avant /usr/bin dans le PATH.
SUP="supervisorctl -c /etc/supervisor/supervisord.conf"

action="${1:-}"; shift || true

# Les unités que nous gérons réellement, sous le nom que supervisor connaît.
traduire() {
  case "${1%.service}" in
    centengine)               echo centengine ;;
    cbd|centreon-broker)      echo cbd ;;
    gorgoned|centreon-gorgone) echo gorgoned ;;
    apache2|httpd)            echo apache2 ;;
    php-fpm|php8.2-fpm)       echo php-fpm ;;
    *)                        echo "" ;;
  esac
}

case "$action" in
  start|stop|restart|reload|reload-or-restart|try-restart)
    [ "$action" = "reload" ] && action=restart
    [ "$action" = "reload-or-restart" ] && action=restart
    [ "$action" = "try-restart" ] && action=restart
    rc=0
    for u in "$@"; do
      p="$(traduire "$u")"
      # Une unité qu'on ne gère pas n'est pas une erreur : Centreon pilote aussi
      # des services optionnels (snmpd, centreontrapd) absents de cette image.
      [ -z "$p" ] && continue
      $SUP "$action" "$p" >/dev/null 2>&1 || rc=1
    done
    exit $rc
    ;;
  is-active|status)
    for u in "$@"; do
      p="$(traduire "$u")"
      [ -z "$p" ] && { echo inactive; continue; }
      if $SUP status "$p" 2>/dev/null | grep -q RUNNING; then echo active; else echo inactive; exit 3; fi
    done
    exit 0
    ;;
  enable|disable|daemon-reload|mask|unmask|is-enabled|preset)
    # Sans objet dans un conteneur : ce qui doit tourner est décrit par supervisor.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
