# Centreon 24.10 — image Caleope
#
# POURQUOI CETTE IMAGE EXISTE
# Centreon ne publie aucune image Docker officielle. Les seules disponibles sont
# des images de particuliers (≤ 10 000 téléchargements, aucun mainteneur, dont un
# environnement de démonstration de faille). Caleope installe en root chez ses
# utilisateurs : c'était non. On construit donc depuis les DÉPÔTS APT OFFICIELS.
#
# ⚠️ BASE DEBIAN 12, PAS 13. Centreon ne publie aucun paquet serveur pour trixie
# (le dépôt trixie ne contient que l'agent : 12 paquets contre 1176 en bookworm).
# L'hôte Caleope reste en Debian 13 ; le conteneur apporte son propre système.
#
# ⚠️ DEUX DÉPÔTS SONT NÉCESSAIRES, la documentation n'en cite qu'un :
#   apt-standard-24.10-stable → le produit
#   apt-plugins-stable        → les dépendances Perl de gorgone
# Sans le second, centreon-gorgone réclame libmojo-ioloop-signal-perl,
# libnet-curl-perl et libssh-session-perl, introuvables, et tout s'effondre.
FROM debian:12-slim

ARG CENTREON_VERSION=24.10

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg procps supervisor \
    ; \
    curl -fsSL https://apt-key.centreon.com | gpg --dearmor -o /etc/apt/trusted.gpg.d/centreon.gpg; \
    printf '%s\n' \
      "deb https://packages.centreon.com/apt-standard-${CENTREON_VERSION}-stable/ bookworm main" \
      "deb https://packages.centreon.com/apt-plugins-stable/ bookworm main" \
      > /etc/apt/sources.list.d/centreon.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends centreon-central; \
    rm -rf /var/lib/apt/lists/*

# La télémétrie est activée par défaut par le paquet : un cron quotidien renvoie
# des statistiques d'usage. Inacceptable sans consentement sur une appliance
# livrée à des tiers. Le formulaire d'installation la refuse aussi (étape 9).
RUN sed -i '/centreon-send-stats/d' /etc/cron.d/centreon || true

# Traducteur systemd → supervisor. Sans lui, « appliquer la configuration »
# réussit en apparence et ne fait rien : Centreon envoie un signal à systemd,
# qui n'existe pas, et le moteur reste sur son ancienne configuration.
# Gorgone refuse EN SILENCE toute commande hors liste blanche (voir le fichier).
COPY gorgone-whitelist-caleope.yaml /etc/centreon-gorgone/config.d/whitelist.conf.d/caleope.yaml

COPY systemctl-shim.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

COPY supervisord.conf /etc/supervisor/conf.d/centreon.conf
COPY reload-watch.sh /usr/local/bin/centreon-reload-watch
COPY entrypoint.sh /usr/local/bin/centreon-entrypoint
COPY init-centreon.sh /usr/local/bin/centreon-init
RUN chmod +x /usr/local/bin/centreon-entrypoint /usr/local/bin/centreon-init /usr/local/bin/centreon-reload-watch

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/centreon-entrypoint"]
