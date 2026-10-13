# VoIP PBX — exigences et limites

## Portée

Ce paquet enveloppe l'image Docker officielle MikoPBX `2026.2.118`. Il reste un
PBX SIP générique et ne contient aucune identité, extension ou
clé propre à Hermes/Titus. Les intégrations applicatives sont provisionnées
après l'installation par un paquet ou une procédure distincte.

## Réseau

- Canal `alpha` : écoute uniquement sur une adresse Tailscale ou RFC1918.
- Aucun trunk opérateur, numéro public, NAT automatique ou règle de pare-feu.
- SIP : UDP 5060 et TLS 5061 dans le réseau privé ; RTP : UDP 20000–20800.
- Une exposition Internet future exige un SBC, SIP TLS, SRTP, limitation de
  débit, bannissement, supervision et tests d'appel négatifs.

## Sécurité

- Pas de mode privilégié ni socket Docker. La seule capacité ajoutée est
  `NET_ADMIN`, requise par le pare-feu interne officiel MikoPBX.
- Interface web HTTPS MikoPBX ; mot de passe initial aléatoire produit dans un
  fichier root `0600`, à transférer vers le coffre puis supprimer.
- Les mots de passe SIP sont gérés par MikoPBX.
- Les enregistrements d'appels sont désactivés par défaut.

## État alpha

Le téléchargement de l'image épinglée et les appels SIP/RTP réels doivent être validés sur
une cible de test avant publication dans le canal stable. Un HTTP 200 de
l'interface ne constitue pas une preuve d'appel.
