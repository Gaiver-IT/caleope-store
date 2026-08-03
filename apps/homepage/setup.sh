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
# Dossier vide sur le disque SYSTÈME, pour le widget « disque » (cf compose).
mkdir -p "${CONFIG_DIR}/df-system"

DOMAIN="${CALEOPE_DOMAIN:-localhost}"

# ── secrets.env ──────────────────────────────────────────────────────────────
# HOMEPAGE_ALLOWED_HOSTS est OBLIGATOIRE depuis Homepage 1.0 : sans lui, toute
# requête dont l'en-tête Host n'est pas listé reçoit un 400 et la page reste
# blanche. C'est LA cause n°1 de « mon Homepage ne s'affiche pas ».
#
# Le PORT compte : Homepage compare l'en-tête Host TEL QUEL, donc « localhost »
# n'autorise pas « localhost:8004 ». Sans les variantes avec port, tout appel
# direct à l'API (sonde de santé, test en ligne de commande) reçoit
# « Host validation failed » alors que le navigateur, lui, fonctionne.
PORT="$(sed -n 's/^CALEOPE_PORT_WEB=//p' "${CALEOPE_BASE_DIR}/apps-installed/homepage/app.env" 2>/dev/null | head -1)"
ALLOWED="${DOMAIN},localhost,127.0.0.1,homepage"
[ -n "${PORT}" ] && ALLOWED="${ALLOWED},localhost:${PORT},127.0.0.1:${PORT}"

cat > "${_SECRETS}" <<ENV
HOMEPAGE_ALLOWED_HOSTS=${ALLOWED}
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
language: fr
theme: dark
# Base NEUTRE volontairement : une couleur de thème (`sky`, `blue`…) repeint
# tout le fond en aplat uni et écrase le dégradé de custom.css.
color: slate
headerStyle: boxedWidgets
cardBlur: md
hideVersion: true
statusStyle: dot
layout:
  Applications:
    style: row
    columns: 4
YAML

# ── Habillage par défaut ─────────────────────────────────────────────────────
# Le thème d'origine de Homepage est austère. Ces quelques règles suffisent à
# le rendre présentable, sans dépendre d'aucune ressource externe (ni image,
# ni police à télécharger : la page reste utilisable hors ligne).
write_if_absent "${CFG}/custom.css" <<'CSS'
/* ⚠️ Le dégradé DOIT être posé sur #__next, pas sur body : Next.js peint un
   aplat opaque sur ce conteneur, qui recouvrirait un fond mis sur body. */
html, body { background-color: #090d1a !important; }

#__next {
  background:
    radial-gradient(1100px 750px at 10% -12%, rgba(56,189,248,.20), transparent 62%),
    radial-gradient(950px 650px at 90% 4%,   rgba(167,139,250,.17), transparent 62%),
    radial-gradient(900px 600px at 50% 112%, rgba(45,212,191,.12), transparent 62%),
    linear-gradient(165deg, #0a0f1e 0%, #0d1528 48%, #090d1a 100%) !important;
  background-attachment: fixed !important;
  min-height: 100vh;
}

#information-widgets {
  background: rgba(255,255,255,.055) !important;
  border: 1px solid rgba(255,255,255,.09);
  border-radius: 18px !important;
  backdrop-filter: blur(16px) saturate(140%);
  -webkit-backdrop-filter: blur(16px) saturate(140%);
  box-shadow: 0 18px 40px -24px rgba(0,0,0,.85);
}

.service-card {
  background: rgba(255,255,255,.045) !important;
  border: 1px solid rgba(255,255,255,.075);
  border-radius: 14px !important;
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  transition: transform .18s ease, background .18s ease,
              border-color .18s ease, box-shadow .18s ease;
}
.service-card:hover {
  transform: translateY(-2px);
  background: rgba(255,255,255,.085) !important;
  border-color: rgba(56,189,248,.40);
  box-shadow: 0 14px 34px -18px rgba(0,0,0,.9);
}

.service-group-name,
.bookmark-group-name {
  text-transform: uppercase;
  letter-spacing: .14em;
  font-size: .95rem !important;
  color: #7dd3fc !important;
  padding-bottom: .35rem;
  border-bottom: 1px solid rgba(125,211,252,.18);
}

.service-card img,
.service-card svg { filter: drop-shadow(0 2px 6px rgba(0,0,0,.45)); }

/* Ne styler QUE la carte extérieure des raccourcis : toucher aussi les div
   internes crée une pastille parasite autour du libellé. */
.bookmark-text {
  background: rgba(255,255,255,.04) !important;
  border: 1px solid rgba(255,255,255,.07);
  border-radius: 12px !important;
  transition: background .18s ease, border-color .18s ease;
}
.bookmark-text:hover {
  background: rgba(255,255,255,.08) !important;
  border-color: rgba(56,189,248,.35);
}

.services-group { margin-bottom: .9rem; }
CSS

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
    uptime: true
    disk:
      # Disque système (dossier vide bind-monté) et disque des données
      # (/app/config est déjà dessus — ne PAS ajouter un second chemin sur le
      # même périphérique, `df` les replierait et le widget afficherait
      # « Drive not found »).
      - /mnt/df-system
      - /app/config
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
