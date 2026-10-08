# Music Assistant — exigences et limites

- Version empaquetée : **2.10.5** (`452e23745588`).
- Le conteneur utilise le réseau Docker `caleope-public` et Traefik. Le lecteur
  web et les lecteurs purement logiciels fonctionnent ; la découverte mDNS/UPnP
  des enceintes locales n'est pas fournie par ce paquet. Cette limitation évite
  une passerelle vers le réseau hôte que le pare-feu Caleope ne laisse pas passer.
- Si Authentik est installé, le paquet crée son fournisseur proxy et son
  application avant d'activer ForwardAuth. Sans Authentik, le premier démarrage
  doit être protégé en configurant immédiatement le compte admin Music Assistant.
- Spotify nécessite un abonnement **Premium**.
- Deezer nécessite un abonnement **Premium, HiFi ou Family** ; Deezer Free
  n'est pas pris en charge.
- Le fournisseur Jellyfin permet d'agréger la musique déjà présente sur le
  serveur sans déplacer la bibliothèque.
- Finamp reste un client Jellyfin : il ne reçoit pas directement le catalogue
  Spotify ou Deezer. Le lecteur web de Music Assistant permet d'écouter ces
  catalogues à distance.
