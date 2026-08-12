# Centreon — paquet Caleope

Supervision d'infrastructure : hôtes, services, métriques, alertes. Ce paquet
livre un Centreon 24.10 **déjà installé** — pas un formulaire d'installation à
remplir. Environ trente secondes après le démarrage du conteneur, l'interface
est utilisable et les moteurs de collecte tournent.

> **Canal : alpha.** Le paquet fait ce qu'il annonce et a été vérifié de bout en
> bout (voir « Comment vérifier »), mais il n'a pas encore d'usage prolongé
> derrière lui. Il passera en stable après quelques semaines en production.

---

## Pourquoi une image maison

Centreon ne publie **aucune image Docker officielle**. Les images disponibles
sur Docker Hub sont des travaux personnels sans mainteneur — quelques milliers
de téléchargements, pas de mise à jour de sécurité, et l'une d'elles est
explicitement un environnement de démonstration de faille. Caleope installe chez
ses utilisateurs avec les droits root : faire tourner ça n'était pas une option.

L'image est donc construite ici, à partir des **dépôts APT officiels de
l'éditeur**, par `setup.sh`, à la première installation. Environ deux à trois
minutes, une seule fois. Si la construction échoue, l'installation s'arrête avec
un message — elle ne retombe **jamais** en silence sur une image tierce.

---

## Les huit pièges, et ce qu'ils coûtent quand on les ignore

Chacun a été trouvé en mesurant, pas en lisant la documentation. Ils sont écrits
ici parce qu'ils reviendront à la prochaine montée de version.

### 1. Il faut **deux** dépôts APT, la documentation n'en cite qu'un

| dépôt | ce qu'il apporte |
|---|---|
| `apt-standard-24.10-stable` | le produit (1176 paquets) |
| `apt-plugins-stable` | les dépendances Perl de gorgone (18998 paquets) |

Sans le second, `centreon-gorgone` réclame `libmojo-ioloop-signal-perl`,
`libnet-curl-perl` et `libssh-session-perl`, introuvables, et l'installation du
paquet `centreon-central` échoue.

### 2. Pas de paquets serveur pour Debian 13 (trixie)

Le dépôt `trixie/` **existe** — c'est le piège, on le voit et on conclut trop
vite. Il ne contient que l'agent : **12 paquets contre 1176 en bookworm**. Il n'y
a aucun paquet serveur pour trixie à ce jour.

L'image part donc de `debian:12-slim`. L'hôte Caleope reste en Debian 13 : c'est
tout l'intérêt d'un conteneur, il apporte son propre système.

### 3. Gorgone refuse **en silence** les commandes hors liste blanche

Symptôme : l'utilisateur ajoute un hôte, applique la configuration, Centreon
répond `OK: A reload signal has been sent to 'Central'`, code de retour 0 — et
l'hôte n'apparaît jamais dans la supervision.

En remontant la chaîne : la commande enregistrée en base est
`systemctl restart centengine`, sans `sudo`, alors que le motif de la liste
blanche livrée par l'éditeur n'accepte ce verbe **qu'avec** `sudo`. La commande
est rejetée, et rien n'est journalisé côté utilisateur.

Le fichier `image/gorgone-whitelist-caleope.yaml` est déposé dans
`whitelist.conf.d/` — le point d'extension prévu, qui survit aux mises à jour du
paquet. **Il ne suffit pas à lui seul** : voir le point suivant.

### 4. Dans un conteneur, le signal de rechargement n'arrive jamais

Même liste blanche corrigée, il n'y a pas de systemd dans le conteneur pour
recevoir l'ordre. Trois demi-solutions ont été essayées avant d'abandonner la
rétro-conception : un traducteur `systemctl` → `supervisorctl`
(`image/systemctl-shim.sh`, gardé, il sert ailleurs), les droits de la prise
supervisor pour le compte `centreon-gorgone` (gardés aussi), et l'ajout à la
liste blanche.

Ce qui a réellement débloqué la supervision : `image/reload-watch.sh`, un
veilleur qui surveille l'empreinte des fichiers de `/etc/centreon-engine` et
relance le moteur dès qu'elle change.

**Coût assumé, à dire à l'utilisateur :** un rechargement est un *redémarrage* du
moteur, soit quelques secondes sans collecte. Acceptable sur une appliance
mono-collecteur ; ce serait discutable sur un parc de plusieurs milliers d'hôtes.

### 5. Les volumes masquent ce que l'image apporte

Les six dossiers persistés **ne sont pas vides dans l'image** : `/etc/centreon`
en contient 7 entrées, `/var/lib/centreon` 9, et ainsi de suite. Monter un
dossier hôte vide par-dessus les cache.

Symptôme mesuré : l'installation déroule ses étapes normalement — step3, step4,
step5, step6, configFileSetup, installConfigurationDb, installStorageDb,
createDbUser — puis `insertBaseConf.php` rend un **HTTP 500**. Rien n'indique
qu'un dossier est masqué.

`setup.sh` recopie donc le contenu de l'image dans les dossiers **encore vides**,
une seule fois. Un dossier déjà peuplé n'est jamais touché : c'est ce qui rend
l'opération rejouable sans écraser les données de l'utilisateur.

### 6. Course au démarrage : `supervisorctl` avant supervisord

Le plus sournois des six, trouvé en testant un simple redémarrage.

L'entrypoint lance supervisord **et** le script d'init en parallèle. À la
première installation, l'init met plusieurs minutes (attente de la base, du web,
douze requêtes) — supervisord est prêt depuis longtemps. Mais au **redémarrage**,
l'init voit sa marque, saute tout, et appelle `supervisorctl` en une fraction de
seconde :

```
unix:///var/run/supervisor.sock no such file
```

Les moteurs ne démarrent pas. Apache et php-fpm, eux, sont en `autostart=true` :
l'interface répond, les graphes d'hier s'affichent, tout a l'air normal — et plus
rien n'est supervisé. **Une supervision qui ment est pire que pas de
supervision.**

Aggravant : la première version de ce script journalisait « ✅ moteurs relancés »
sans regarder le résultat de la commande. Le script attend maintenant la prise de
supervisord, puis **vérifie** que les quatre programmes sont bien en `RUNNING`, et
sort en erreur sinon.

### 7. « Caractère spécial » ne veut pas dire ce qu'on croit

Centreon code sa liste en dur, et elle tient en sept caractères :

```php
SecurityPolicy::SPECIAL_CHARACTERS_LIST = '@$!%*?&';
```

Un mot de passe contenant un tiret, un point ou un tiret bas n'a donc, pour
Centreon, **aucun** caractère spécial. L'étape 5 le refuse — et rend quand même
un **HTTP 200**. Le compte admin est créé avec un mot de passe **vide**
(`length(password) = 0` en base, vérifié), l'installation se poursuit
normalement, et personne ne peut se connecter.

Le générateur du paquet tirait au début dans `!@$*_.:-` : quatre caractères sur
huit étaient invalides, soit **une installation sur deux qui échouait au hasard
du tirage**. Il tire désormais dans `@$!*` — l'intersection de ce que Centreon
accepte et de ce qui traverse intact un corps `x-www-form-urlencoded` (`&`, `%`
et `?` y seraient interprétés et tronqueraient la valeur).

C'est la vérification par l'API qui a rattrapé ce piège : sans elle,
l'installation ressortait « réussie ».

### 8. La configuration de gorgone est engendrée, pas livrée

`/etc/centreon-gorgone/config.d/40-gorgoned.yaml` **n'existe pas dans l'image** :
il est créé pendant l'installation et porte les identifiants de base. Tant que ce
dossier n'était pas persisté, il disparaissait au premier redémarrage et gorgone
partait en boucle d'échec puis en `FATAL` :

```
ERROR - [core] can't find config file '/etc/centreon-gorgone/config.d/40-gorgoned.yaml'
```

Deux corrections, complémentaires : le dossier est persisté (et amorcé depuis
l'image, cf. piège n°5), et supervisor vise désormais `config.yaml` — le point
d'entrée prévu par l'éditeur, qui fait `!include config.d/*.yaml` — au lieu de
viser directement un fichier engendré.

---

## Ce que le paquet ajoute à l'installateur de l'éditeur

Centreon fournit `unattended.sh`, qui rejoue son propre formulaire web par douze
requêtes HTTP. `image/init-centreon.sh` reprend **exactement** cette séquence —
c'est l'éditeur qui la maintient — mais sans le script, qui exige un systemd
vivant et meurt dans un conteneur. Deux choses sont ajoutées :

1. **La vérification.** Le script officiel journalise le code HTTP sans jamais le
   tester : un Centreon à moitié installé ressort en « successfully installed ».
   Ici, l'installation n'est déclarée réussie que si
   `POST /centreon/api/latest/login` rend un jeton. Sinon le conteneur crie.
2. **L'armement de la supervision.** Les moteurs sont installés mais jamais
   démarrés, et aucune configuration n'est générée. Le script lance `APPLYCFG`
   puis démarre `gorgoned`, `cbd`, `centengine` et le veilleur.

La télémétrie est refusée à deux endroits : le cron `centreon-send-stats` est
retiré de l'image, et l'étape 9 du formulaire est envoyée avec
`send_statistics=0`. Pas de statistiques d'usage sans consentement sur une
appliance livrée à des tiers.

---

## Installer

```bash
caleope install centreon
```

Les mots de passe laissés vides sont engendrés. Ils respectent la politique de
Centreon (12 caractères, majuscule, minuscule, chiffre, spécial) et **excluent**
`& = + % #` : le mot de passe transite dans un corps
`application/x-www-form-urlencoded`, un `&` le tronquerait en silence et le
compte serait créé avec un mot de passe amputé.

Le mot de passe admin est rappelé dans
`app-config/centreon/post-install.txt` (mode 600), avec les secrets dans
`app-config/centreon/secrets.env`.

Suivre la fin de l'installation :

```bash
caleope logs centreon
```

La ligne `✅ Centreon installé, vérifié, supervision armée` la signe.

---

## Comment vérifier que ça marche vraiment

Quatre contrôles, dans cet ordre. Les trois premiers peuvent réussir alors que la
supervision ne supervise rien — c'est le quatrième qui compte.

```bash
# 1. le web répond
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/centreon/

# 2. le compte admin existe réellement (et pas seulement « l'install a fini »)
curl -s -X POST http://127.0.0.1:<port>/centreon/api/latest/login \
  -H 'Content-Type: application/json' \
  -d '{"security":{"credentials":{"login":"admin","password":"<mdp>"}}}'
# → doit contenir "token"

# 3. les quatre programmes tournent
docker exec centreon supervisorctl -c /etc/supervisor/supervisord.conf status
# → php-fpm, apache2, gorgoned, cbd, centengine, reload-watch en RUNNING

# 4. LE contrôle qui compte : un hôte ajouté arrive-t-il vraiment en supervision ?
docker exec centreon /usr/share/centreon/bin/centreon -u admin -p '<mdp>' \
  -o HOST -a ADD -v 'banc;Banc;127.0.0.1;;Central;'
docker exec centreon /usr/share/centreon/bin/centreon -u admin -p '<mdp>' -a APPLYCFG -v 1
sleep 25
docker exec centreon-db sh -c \
  'mysql -uroot -p"$MARIADB_ROOT_PASSWORD" -N -B \
   -e "select count(*) from centreon_storage.hosts;"'
# → 1
```

Le contrôle 4 interroge `centreon_storage.hosts` — la table de **supervision**,
que seul le moteur remplit — et surtout pas `centreon.host`, la table de
**configuration**, que l'ajout remplit de toute façon. C'est précisément cette
confusion qui laisse croire qu'une supervision morte fonctionne.

Sur une installation neuve, avant tout ajout, ces deux tables sont **vides** :
Centreon ne crée aucun hôte pour son propre serveur central. Un compteur à zéro
juste après l'installation est donc normal ; c'est après un ajout qu'il devient
un verdict.

Mesuré sur le paquet le 12/08/2026 : hôte ajouté, `APPLYCFG` lancé, le veilleur
détecte l'empreinte modifiée, recharge le moteur, et l'hôte apparaît en
supervision **5 à 20 s** plus tard. Si le compteur reste à zéro, c'est le piège
n°4 qui est revenu — regarder `docker logs centreon | grep reload-watch`.

### 5. Et surtout : couper, relancer, refaire les contrôles

```bash
caleope restart centreon
sleep 60
docker exec centreon supervisorctl -c /etc/supervisor/supervisord.conf status
# → les SIX programmes en RUNNING, gorgoned compris
```

⚠️ **Ne pas se contenter du compteur d'hôtes après un redémarrage** : la ligne
reste en base que le moteur tourne ou non. Le premier script d'essai déclarait
donc « ✅ survit au redémarrage » avec gorgone en `FATAL`. Ce sont les états de
supervisor qui font foi.

Parcours complet vérifié le 12/08/2026 : installation 31 s → hôte supervisé en
15 s → arrêt/relance → six programmes en marche, HTTP 200, supervision intacte.

---

## Empreinte mesurée

| | mémoire | disque |
|---|---|---|
| `centreon` (web + moteurs) | 150 à 312 Mio | image 1,56 Go |
| `centreon-db` (MariaDB) | 107 à 153 Mio | 37 Mo à l'installation, croît avec la rétention |

Compter **environ 430 Mio** avec les moteurs en marche. Le bas de la fourchette
(150 Mio) correspond au conteneur juste démarré, moteurs encore à l'arrêt : ne
pas s'en servir pour dimensionner. Réponse de la page de connexion : 8 à 15 ms.

C'est l'app la plus lourde du magasin après les piles média. À mettre en regard
d'Uptime Kuma (~80 Mio) : Centreon apporte la découverte automatique, les seuils,
les graphes de métriques et les modèles d'hôtes — pas la même classe d'outil.

---

## Ce que ce paquet ne fait pas

À dire franchement plutôt que de le laisser découvrir :

- **Une installation neuve ne supervise rien du tout.** Pas même son propre
  serveur : la table des hôtes est vide. Le premier hôte s'ajoute à la main ou
  par découverte.
- **Aucune commande de contrôle n'est définie.** Les six commandes livrées sont
  toutes des commandes de *notification* (`host-notify-by-email` et compagnie) —
  vérifié en base. Les **50 sondes Nagios sont pourtant bien là**, dans
  `/usr/lib/nagios/plugins`. Il faut passer par Configuration ▸ Modèles pour les
  raccorder. C'est le comportement de Centreon, pas une lacune du paquet, mais
  personne ne s'y attend : on a une supervision installée qui ne sait encore
  rien mesurer.
- **Pas de poller distant.** Ce paquet est un central mono-collecteur.
- **Pas de SSO Authentik.** Centreon sait faire de l'OpenID Connect ; ce n'est pas
  encore câblé ici.

---

## Reconstruire l'image à la main

```bash
docker build -t caleope-centreon:24.10 <chemin-du-paquet>/image
```

Environ 136 s, ~1,6 Go. Nécessite l'accès à `packages.centreon.com`. Le
`build.log` de la dernière tentative est dans `app-config/centreon/build.log`.

Pour changer de version majeure : `--build-arg CENTREON_VERSION=25.04`, **et
vérifier d'abord** que le dépôt correspondant existe pour bookworm :

```bash
curl -sI https://packages.centreon.com/apt-standard-25.04-stable/dists/bookworm/Release
```

---

## Contenu du dossier `image/`

| fichier | rôle |
|---|---|
| `Dockerfile` | base bookworm, deux dépôts, `centreon-central`, télémétrie retirée |
| `entrypoint.sh` | active les modules Apache, lance supervisor puis l'init |
| `init-centreon.sh` | rejoue le formulaire, **vérifie**, arme la supervision |
| `supervisord.conf` | ordre de démarrage, droits de la prise pour gorgone |
| `reload-watch.sh` | recharge le moteur quand la configuration change (piège n°4) |
| `systemctl-shim.sh` | traduit `systemctl` en `supervisorctl` |
| `gorgone-whitelist-caleope.yaml` | déposé dans `whitelist.conf.d/` (piège n°3) |
