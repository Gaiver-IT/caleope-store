#!/bin/bash
set -euo pipefail

# ── Homepage — tableau de bord d'accueil ─────────────────────────────────────
# RÈGLE CARDINALE DE CE SCRIPT : on n'écrase JAMAIS un fichier de configuration
# existant. `caleope install --force` rejoue ce setup à chaque mise à jour ; un
# `cat >` inconditionnel détruirait le tableau de bord patiemment construit par
# l'utilisateur. Tout est donc écrit « si absent » (voir write_if_absent).

CONFIG_DIR="${CALEOPE_BASE_DIR}/app-config/homepage"
DATA_DIR="${CALEOPE_BASE_DIR}/app-data/homepage"
CFG="${DATA_DIR}/config"
_SECRETS="${CONFIG_DIR}/secrets.env"

mkdir -p "${CONFIG_DIR}" "${CFG}"
# Deux dossiers vides, un par système de fichiers à mesurer (cf docker-compose).
mkdir -p "${CONFIG_DIR}/df-system" "${DATA_DIR}/df-appdata"

DOMAIN="${CALEOPE_DOMAIN:-localhost}"

# ── secrets.env ──────────────────────────────────────────────────────────────
# HOMEPAGE_ALLOWED_HOSTS est OBLIGATOIRE depuis Homepage 1.0 : sans lui, toute
# requête dont l'en-tête Host n'est pas listé reçoit un 400 et la page reste
# blanche. C'est LA cause n°1 de « mon Homepage ne s'affiche pas ».
cat > "${_SECRETS}" <<ENV
HOMEPAGE_ALLOWED_HOSTS=${DOMAIN},localhost,127.0.0.1
ENV
chmod 600 "${_SECRETS}"

# ── écriture prudente ────────────────────────────────────────────────────────
write_if_absent() {
  local target="$1"
  if [ -s "${target}" ]; then
    echo "  → ${target##*/} conservé (déjà configuré)"
    cat > /dev/null                      # on consomme le heredoc sans l'écrire
  else
    cat > "${target}"
    echo "  ✓ ${target##*/} créé"
  fi
}

write_if_absent "${CFG}/settings.yaml" <<'YAML'
title: Tableau de bord
theme: dark
color: slate
headerStyle: boxed
layout:
  Applications:
    style: row
    columns: 4
  Système:
    style: row
    columns: 3
YAML

write_if_absent "${CFG}/docker.yaml" <<'YAML'
# Permet à Homepage d'afficher l'état RÉEL des conteneurs (démarré, arrêté,
# santé), et pas seulement si l'URL répond.
caleope:
  socket: /var/run/docker.sock
YAML

write_if_absent "${CFG}/widgets.yaml" <<'YAML'
- resources:
    label: Serveur
    cpu: true
    memory: true
    disk:
      - /mnt/df-system
      - /mnt/df-appdata
- search:
    provider: duckduckgo
    target: _blank
YAML

write_if_absent "${CFG}/bookmarks.yaml" <<'YAML'
- Caleope:
    - Documentation:
        - abbr: DOC
          href: https://caleope.gaiver-it.fr/
YAML

# ── services.yaml : découverte des apps déjà installées ──────────────────────
# Plutôt qu'un fichier vide, on fabrique une tuile par app Caleope installée en
# lisant le domaine réel dans son compose. L'utilisateur arrive donc sur un
# tableau de bord déjà rempli, pas sur une page à remplir.
if [ ! -s "${CFG}/services.yaml" ]; then
  {
    echo "- Applications:"
    found=0
    for dir in "${CALEOPE_BASE_DIR}"/apps-installed/*/; do
      [ -d "${dir}" ] || continue
      app="$(basename "${dir}")"
      [ "${app}" = "homepage" ] && continue
      # Le domaine est dans la règle Traefik du compose généré par le daemon.
      # `|| true` est INDISPENSABLE : sous `set -euo pipefail`, un grep sans
      # correspondance (app sans domaine) fait échouer toute la substitution et
      # avorte silencieusement la génération entière du fichier.
      host="$(grep -ohE 'Host\(`[^`]+`\)' "${dir}"compose.yml "${dir}"docker-compose.yml 2>/dev/null \
              | head -1 | sed -E 's/.*`(.*)`.*/\1/' || true)"
      [ -z "${host}" ] && continue || true
      found=1
      printf '    - %s:\n' "${app}"
      printf '        href: https://%s/\n' "${host}"
      printf '        siteMonitor: https://%s/\n' "${host}"
      printf '        server: caleope\n'
      printf '        container: %s\n' "${app}"
    done
    [ "${found}" = "0" ] && printf '    - Caleope:\n        href: /\n'
  } > "${CFG}/services.yaml"
  echo "  ✓ services.yaml créé depuis les apps installées"
else
  echo "  → services.yaml conservé (déjà configuré)"
fi

cat > "${CONFIG_DIR}/post-install.txt" <<INFO

  ┌──────────────────────────────────────────────────────────────────┐
  │                Homepage — tableau de bord d'accueil              │
  ├──────────────────────────────────────────────────────────────────┤
  │  Interface : https://${DOMAIN}/
  │                                                                  │
  │  Configuration : fichiers YAML dans                              │
  │    app-data/homepage/config/                                     │
  │      settings.yaml   titre, thème, disposition                   │
  │      services.yaml   les tuiles d'applications                   │
  │      widgets.yaml    bandeau du haut (CPU, RAM, disque)          │
  │      bookmarks.yaml  liens rapides                               │
  │                                                                  │
  │  Homepage recharge à chaud : enregistrer suffit.                 │
  │                                                                  │
  │  Ces fichiers ne sont JAMAIS écrasés par une mise à jour.        │
  └──────────────────────────────────────────────────────────────────┘
INFO

echo "✓ Homepage prêt — https://${DOMAIN}/"
