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
- YouTube Music nécessite Premium, un cookie de connexion fourni directement
  dans l'interface Music Assistant et un serveur PO Token. Le service
  `music-assistant-pot` utilise la version 2.0.0 du générateur BgUtils, la
  même pile réseau que Music Assistant et une écoute strictement limitée à
  `127.0.0.1:4416`. Aucun port n'est publié sur l'hôte ni sur Traefik.
  L'URL à saisir dans le fournisseur est `http://127.0.0.1:4416`. La version
  2.0.0 corrige une vulnérabilité de la série antérieure ; ne pas rétrograder
  pour suivre une documentation Music Assistant non mise à jour. Tester une
  lecture réelle, car les contraintes YouTube changent et le générateur de
  jetons ne garantit pas la lecture.
- Finamp reste un client Jellyfin : il ne reçoit pas directement le catalogue
  Spotify ou Deezer. Le lecteur web de Music Assistant permet d'écouter ces
  catalogues à distance.
