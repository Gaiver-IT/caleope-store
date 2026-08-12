#!/bin/bash
# Point d'entrée : lance supervisor, puis l'installation si elle n'a pas eu lieu.
set -euo pipefail

: "${CENTREON_DB_HOST:=centreon-db}"
: "${CENTREON_DB_PORT:=3306}"

mkdir -p /run/php /var/log/centreon /var/lib/centreon /run/supervisor

# Apache a besoin de ses modules pour parler à PHP-FPM. Le paquet les active
# normalement à l'installation ; on le refait ici car un `docker build` ne
# déclenche pas toujours les hooks des paquets.
a2enmod proxy proxy_fcgi rewrite headers >/dev/null 2>&1 || true
a2enconf centreon php8.2-fpm >/dev/null 2>&1 || true

echo "→ démarrage des services web"
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf &
SUP=$!

# Installation en tâche de fond : elle attend que le web réponde, fait le
# nécessaire, puis démarre les moteurs. Le conteneur reste vivant même si
# l'installation échoue — on veut pouvoir lire les journaux, pas une boucle
# de redémarrage qui efface les traces.
/usr/local/bin/centreon-init &

wait "$SUP"
