# XiVO PBX — appliance (Pro)

App de type **`appliance`** : Caleope crée une **VM KVM** (feature Pro) depuis la
**netinst Debian 11 officielle** (URL + SHA256 dans `app.json`), injecte
`preseed.cfg` (installation Debian automatique), puis au **premier boot** la VM
lance le **`xivo_install.sh` officiel** du miroir XiVO → vrai XiVO reconnu.

**Rien n'est hébergé par Caleope** : Debian vient de `cdimage.debian.org`, XiVO de
`mirror.xivo.solutions`. Intégrité garantie par le SHA256 de l'ISO.

## Fichiers
- `app.json` — manifeste (`type: appliance` + section `appliance`).
- `preseed.cfg` — preseed Debian **auto-suffisant** : `xivo-firstboot.sh` et
  `xivo-firstboot.service` y sont **embarqués en base64** dans `late_command`.
- `xivo-firstboot.sh` / `xivo-firstboot.service` — **sources** de ces deux fichiers
  (source de vérité, à éditer ici).

## Régénérer le preseed après édition des sources
Ré-encoder les deux sources en base64 et remplacer les blobs dans
`preseed/late_command` de `preseed.cfg` (voir l'historique de génération).

## À confirmer au build
- Version Debian épinglée = 11.11 (Bullseye = socle XiVO documenté). Bumper
  `iso_url`+`iso_sha256` quand XiVO passe à une Debian plus récente.
- Flag de version/non-interactif de `xivo_install.sh` (`-a`/`-d`) à valider contre
  `xivo_install.sh -h` lors du test sur hôte KVM.
- `network: bridge` nécessite un pont (`br0`) configuré sur l'hôte.
