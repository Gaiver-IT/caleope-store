# Invidious — exigences et exploitation

- Au moins **2 Go de RAM libre** pour Invidious, Companion et PostgreSQL.
- Au moins **20 Go d'espace disque libre**.
- La lecture vidéo consomme la bande passante du serveur : ce paquet est prévu
  pour une instance personnelle, pas pour une instance publique.
- Invidious Companion est inclus et obligatoire pour la lecture des vidéos.
- Le test de santé `/api/v1/stats` et la recherche ne prouvent pas la lecture :
  vérifier aussi `/api/v1/videos/<id>` et un flux vidéo réel. Companion doit
  obtenir un PO Token valide ; une sortie IP de datacenter ou de VPN peut être
  refusée par YouTube. Dans ce cas, voir les journaux de `invidious-companion`
  et la documentation officielle des erreurs YouTube avant de modifier le
  réseau. Ne pas considérer le service opérationnel sur son seul état `healthy`.
- Authentik est utilisé automatiquement comme ForwardAuth lorsqu'il est déjà
  installé sur Caleope.
- Les sources du schéma PostgreSQL proviennent d'Invidious
  `v2.20260804.1` (`48c6110a83fc`).

La documentation officielle recommande un redémarrage fréquent d'Invidious
(au moins quotidien) si la lecture devient instable.
