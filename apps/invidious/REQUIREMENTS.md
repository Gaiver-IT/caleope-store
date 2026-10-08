# Invidious — exigences et exploitation

- Au moins **2 Go de RAM libre** pour Invidious, Companion et PostgreSQL.
- Au moins **20 Go d'espace disque libre**.
- La lecture vidéo consomme la bande passante du serveur : ce paquet est prévu
  pour une instance personnelle, pas pour une instance publique.
- Invidious Companion est inclus et obligatoire pour la lecture des vidéos.
- Authentik est utilisé automatiquement comme ForwardAuth lorsqu'il est déjà
  installé sur Caleope.
- Les sources du schéma PostgreSQL proviennent d'Invidious
  `v2.20260804.1` (`48c6110a83fc`).

La documentation officielle recommande un redémarrage fréquent d'Invidious
(au moins quotidien) si la lecture devient instable.
