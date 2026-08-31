# Swiss Army VPN

Une page. Si vous n’en lisez qu’une, que ce soit celle-ci.

## De quoi il s’agit

Une petite fenêtre Windows pour un VPN que Windows sait déjà lancer. Elle peut aussi couper le reste d’internet si ce VPN tombe. Cette coupure s’appelle kill switch (verrou).

Ce n’est pas l’entreprise NordVPN. Ce n’est pas un nouvel abonnement. Vous apportez l’identifiant.

## Ce que ça fait à l’ordinateur

- Ajoute un VPN Windows nommé Swiss Army VPN.
- Peut activer quatre règles de pare-feu qui bloquent internet normal.
- Peut enregistrer un nom et un mot de passe que Windows garde.
- Peut changer le serveur.

Ça ne lit pas vos fichiers. Ça ne garde pas les sites visités. Ça ne garde pas votre jeton GitHub.

## Ce que ça ne fait pas

Ça n’exécute ni WireGuard ni OpenVPN.

Ça ne vous protège pas tout seul sur un mauvais réseau. Le verrou n’aide que s’il est allumé et que le tunnel est celui que l’app surveille.

## Démarrer

1. Prenez le zip de la dernière Release GitHub. Pas le bouton vert Code.
2. Ouvrez le dossier. Gardez les fichiers ensemble.
3. Lancez `Install Swiss Army VPN.exe`. Windows demande l’administrateur.
4. Ouvrez l’app. SET UP SIGN-IN. Entrez l’identifiant de votre VPN.
5. CONNECT + ARM pour le verrou. CONNECT sans le verrou.

## Arrêter

DISCONNECT + UNLOCK.

Si la fenêtre ne s’ouvre pas et qu’internet est mort : Emergency Unlock dans le menu Démarrer.

## Si ça bloque

Le verrou peut couper tout l’ordinateur. C’est le but. Déverrouillez d’abord.

N’envoyez pas un journal brut. Passez le scrubber avant de partager.

## Vie privée

Les mots de passe restent dans Windows. Pas de visage, pas de voix, pas de jeu chronométré.

Un problème de sécu : GitHub security advisories. Jamais un mot de passe dans une issue.

## Auteur

Justichuu. Non officiel. GPL-3.0-only. Le code est lisible.
