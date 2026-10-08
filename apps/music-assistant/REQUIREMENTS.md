# Music Assistant — exigences et limites

- Version empaquetée : **2.10.5** (`452e23745588`).
- Le port hôte TCP **8095** doit être libre. Le mode réseau hôte est requis par
  Music Assistant pour la découverte mDNS/UPnP des lecteurs locaux.
- Spotify nécessite un abonnement **Premium**.
- Deezer nécessite un abonnement **Premium, HiFi ou Family** ; Deezer Free
  n'est pas pris en charge.
- Le fournisseur Jellyfin permet d'agréger la musique déjà présente sur le
  serveur sans déplacer la bibliothèque.
- Finamp reste un client Jellyfin : il ne reçoit pas directement le catalogue
  Spotify ou Deezer. Le lecteur web de Music Assistant permet d'écouter ces
  catalogues à distance.
