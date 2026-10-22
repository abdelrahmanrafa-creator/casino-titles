# Casino & Titles

Nouveau site autonome créé le 22 octobre 2026. Aucun import du code, aucune économie, aucune session de joueur historique du casino parent. Le projet possède son propre package, sa compilation, ses tests et son dépôt Sites. Supabase reste le projet connecté existant, avec des tables `ct_` isolées et de nouvelles identités Supabase Auth ; ce n’est pas un second projet Supabase.

## Démarrer
`npm ci`, renseigner les deux variables publiques décrites dans `.env.example`, puis `npm run dev`. URL locale : http://127.0.0.1:5180. `npm test` exécute les tests PostgreSQL et les moteurs multijoueurs ; `npm run build` vérifie TypeScript strict et produit `dist/`. Déploiement Vercel prêt via `vercel.json` ; la publication Sites conserve son identité dans `.openai/hosting.json`.

## Architecture
- React, Vite, TypeScript strict, Tailwind, React Router, TanStack Query, Framer Motion et Lucide.
- Auth géré par Supabase, jamais de comparaison de mot de passe dans le navigateur. E-mail confirmé requis pour créer un profil.
- PostgreSQL : contraintes, RLS, commandes métier SECURITY DEFINER au search_path fermé ; aucune écriture du client sur le portefeuille, le journal ou les états privés des jeux.
- Une commande économique = une transaction, verrou du portefeuille, clé d’idempotence UUID par joueur, reçu, journal et changement métier.
- Le journal indique montant, solde après et version. Son total est réconcilié avec chaque portefeuille par `supabase/verify.sql`.
- Les commandes interrompues conservent seulement leurs identifiants et paramètres dans le navigateur. La reprise réutilise la même clé ; aucun solde ou résultat local n’est considéré comme valide.
- Limite de 30 nouvelles commandes validées/minute/compte ; les relectures d’un reçu restent possibles. Les échecs annulés ne consomment pas le compteur transactionnel. La protection volumétrique en amont et le débit Auth relèvent aussi de Supabase et de l’hébergeur.
- Multijoueur : Edge Function `ct-tables`, vérification du JWT via Auth `getUser`, moteur autoritaire, écritures réservées au service, révisions optimistes et séquestre transactionnel. Realtime ne transporte que l’identifiant du salon et sa version. Les réponses masquent le paquet et les cartes adverses. Rafraîchissement de secours toutes les cinq secondes.

## Fonctionnalités installées
1. Comptes, profils publics, pseudos uniques, avatar, session et attribution unique de 5 000 crédits.
2. Économie, journal, sauvegarde automatique PostgreSQL, récompense quotidienne de 750 crédits à minuit UTC, missions gratuites, idempotence et reprise réseau.
3. Catalogue de 320 titres, huit raretés, effets CSS animés réutilisables, inventaire avec doublons, équipement, recherche, filtres et collection.
4. Huit coffres aux prix et probabilités demandés, tirage serveur avec rejet du biais modulo, titre, débit et historique atomiques, révélation et animation pouvant être passée.
5. Boutique, missions, succès persistants, événement de lancement et paramètres sauvegardés.
6. Blackjack (tirer/rester/doubler/séparer, 3:2, as, égalités, reprise), Coinflip, roulette européenne, Punto Banco et Slots. Résultats et gains sont calculés sur le serveur.
7. Salons publics/privés pour 2–8 joueurs : Texas Hold’em avec blinds, tours, mains, all-in, pots secondaires et partage ; Chromatic original avec pioche, défausse, prisme, inversion et passage. Une manche par salon, puis règlement et retour aux salons.
8. Classements permanents/hebdomadaires, profils publics, administration vérifiée côté serveur avec recherche, crédits justifiés, titres, suspension, prix, probabilités et audit.
9. Interface responsive, chargement des modules par page, réduction des animations, tests et compilation.

## Backend et déploiement
Les migrations de ce dossier ont été appliquées au Supabase connecté et la fonction `ct-tables` y est déployée. Sur un nouveau projet, appliquer uniquement ces migrations dans l’ordre des noms, puis déployer `supabase/functions/tables`. Les rôles standards Supabase doivent exister. Le script de création des salons fait référence aux suspensions ; ne pas ouvrir le site avant d’avoir terminé toutes les migrations.

Dans Supabase Auth, conserver la confirmation d’e-mail et autoriser l’origine déployée ainsi que http://127.0.0.1:5180 dans les URL de redirection. Le connecteur disponible ne permet pas de modifier ces paramètres Auth. Un e-mail de confirmation doit être testé de bout en bout avant une ouverture générale. Le flux de récupération utilise `/settings`.

La console est `/admin`, sans lien dans la navigation publique. Son accès exige un compte confirmé, un rôle administrateur attribué côté serveur. Une fois activé, le compte connecté accède au panneau sans ressaisir le code. L’activation initiale unique se fait avec le code généré dans `.admin-access.local.txt`, exclu de Git et de la publication. Aucun premier inscrit ne devient administrateur sans ce code. Voir `ADMIN_GUIDE.md`.

## Validation et limites de recette
84 tests automatiques passent : paiements, permissions, restauration physique locale, coffres, combinaisons poker, pots secondaires, cartes privées, règles du Blackjack/Baccarat, missions, événements, révocation, paramètres, offres, stocks, sessions administrateur, rotation du code et affichage du prix barré. PGlite sérialise les transactions ; les tests locaux ne prouvent pas seuls le comportement de connexions PostgreSQL concurrentes.

Une recette supplémentaire sur le Supabase hébergé a utilisé une identité synthétique sans adresse e-mail ni mot de passe, supprimée après les tests : deux demandes quotidiennes concurrentes ont versé une seule récompense ; douze ouvertures concurrentes avec 5 750 crédits ont produit exactement onze titres, onze historiques et un solde de 250. Les douze assertions de `supabase/verify.sql` passent sur l’hébergement.

Contrôle visuel effectué dans le navigateur intégré sur une largeur mobile : accueil, coffres, probabilités et album réel. La compilation ne remplace pas la recette de deux navigateurs authentifiés : inscription/e-mail, Realtime entre deux utilisateurs, perte de connexion et charge prolongée restent à valider sur l’hébergement avant de qualifier le multijoueur de prêt à grande échelle. Les timeouts sont traités par le serveur à la synchronisation ou à la reconnexion ; il n’y a pas de tâche planifiée autonome quand tous les clients sont fermés.

Les règles du Blackjack sont configurables côté administrateur : S17/H17, paiement naturel 3:2 ou 6:5, deux à quatre mains, double après séparation. Leur version est fixée au début de chaque manche et ne peut changer une manche en cours. Les classements de victoires concernent les parties solo. Les modes publics sont sans vrai argent ni conversion. Les sauvegardes hors site et PITR ne sont pas activées automatiquement : voir `BACKUPS.md`.

Le contrôle Supabase relève aussi des alertes sur les anciennes tables du projet parent. Ce nouveau site ne les utilise pas et ce travail n’a pas modifié leurs politiques. Les nouvelles tables privées sans politique de lecture sont volontairement fermées ; les RPC publiques de classement/profil ne renvoient que leur projection publique.

La collection propose un album par rareté, filtres de découverte, fiches et exemplaires. Les titres Rainbow, Xtrem et Cosmiques non possédés sont masqués visuellement (nom, description et source) et la recherche utilise uniquement le nom révélé. Ce masquage concerne l’album, pas la confidentialité du catalogue public ni les titres affichés sur les profils des autres joueurs.

## Atelier de crédits et communauté
La page `/rewards` regroupe un clicker (1 à 11 crédits par clic, dix améliorations payantes), cinq paliers de progression, un cadeau quotidien de 100 à 500 crédits, les 750 crédits quotidiens, missions, événements et saisie des codes promo. Les clics sont encaissés par lots de 1 à 20 ; PostgreSQL limite à 8 clics par seconde avec une réserve de 20, et 5 000 par jour UTC. Les clics non encaissés sont uniquement une animation locale et sont perdus en quittant la page. Les améliorations, paliers et clics encaissés sont persistants. Cette limitation serveur borne les gains ; elle ne prétend pas identifier un humain ou empêcher toute automatisation.

L’administration possède un onglet Codes promo : crédits, titre ou les deux, calendrier, activation, plafond total et compteur. Une utilisation par compte, verrouillage du stock et versement atomique ; modifier un code ne réinitialise pas les utilisations. Aucun code actif fictif n’a été créé. Les codes se partagent depuis l’équipe, ils ne sont pas publiés dans un catalogue accessible aux joueurs.

La recherche de pseudos est disponible sur l’accueil et les classements (2 caractères minimum, 30 résultats au maximum). Les profils affichent les titres actuellement possédés et leurs exemplaires, sans journal financier ni données Auth. Les cartes de collection affichent le nombre de détenteurs distincts, hors titres révoqués et comptes suspendus. Le compteur est rafraîchi toutes les 60 secondes.

Les sept jeux ont des explications supplémentaires ; les jeux solo affichent des exemples de retour mise comprise, des mises rapides et les limites administrateur. Les lignes gagnantes des Slots sont mises en évidence. L’aperçu de l’atelier et des guides a été vérifié visuellement sur des données de test. Les parcours complets dans le navigateur avec un véritable compte connecté restent à compléter ; les transactions ont été testées dans PostgreSQL local et les endpoints publics sur l’hébergement (19 contrôles réseau).

## Confidentialité des classements et coffre-fort
Dans Paramètres, chaque joueur peut masquer son compte de toutes les catégories du classement permanent et hebdomadaire. La préférence est enregistrée côté serveur et filtrée avant la limite de cinquante résultats. Les profils, la recherche de pseudo, les soldes et les statistiques globales restent inchangés.

Administration → Économie & coffre-fort affiche les crédits disponibles du serveur, les portefeuilles des joueurs, les crédits réservés aux tables, les flux quotidiens sur 7/30/90 jours, les totaux par origine et un journal paginé. Le capital initial virtuel est de 100 000 000 crédits. Une contre-écriture de montant opposé est créée par trigger dans la transaction de chaque mouvement du portefeuille, y compris la prime initiale de 5 000 crédits, les promotions et les ajustements administrateur. Le solde du coffre-fort est calculé depuis ce journal ; aucun verrou global supplémentaire ne sérialise les portefeuilles. Les entrées multijoueurs sont déduites du disponible tant que les tables ne sont pas réglées. La suppression d’un compte restitue son solde et conserve les traces comptables.

Le coffre-fort est un suivi comptable virtuel : un déficit éventuel apparaît explicitement sans bloquer un gain dû. Le capital total reste coffre-fort disponible + réservations + portefeuilles. La migration `20261022190000_treasury_privacy.sql` est appliquée sur le Supabase hébergé, avec reprise des transactions historiques. Les huit assertions de `supabase/verify-treasury.sql` passent sur ce serveur. La compilation et 84 tests automatiques sont complétés par dix-neuf contrôles réseau. L’aperçu visuel du coffre-fort utilise des données de recette identifiées.

## Comptes bots figés
Administration → Bots permet de préparer des lots de 1 à 25 comptes simulés (jusqu’à 5 000 au total), prévisualiser et modifier les pseudos, choisir un style de noms, répartir exactement les meilleures raretés, sélectionner les titres éligibles, définir les soldes et générer des historiques. Les styles incluent des pseudos réalistes, plus de 200 mots anglais, trois lettres, trois chiffres (zéros initiaux conservés), trois caractères mixtes et des pseudos de jeu.

Chaque bot est un profil `is_bot=true` sans compte Auth ; les comptes humains conservent leur lien Auth, leur inscription et la suppression en cascade. Les titres sont de vrais exemplaires dans l’inventaire. Les ouvertures et parties sont enregistrées avec `simulated=true`, sans prétendre avoir été jouées par un humain. Les séries Coinflip ont un nombre de victoires égal à la partie entière du taux configuré, réparti aléatoirement. Les probabilités des coffres simulés reflètent la collection autorisée du bot, sans utiliser les stocks ou promotions destinés aux joueurs. Aucun titre Cosmique, y compris par attribution administrative ou reclassification d’un titre existant.

Le financement, les achats, mises, gains et ajustements sont intégralement inscrits dans le journal et compensés dans le coffre-fort. L’excédent de financement est restitué : le coût net de création est exactement la somme des soldes finaux des bots. Les comptes ne peuvent ni se connecter, ni réclamer des récompenses, ni rejoindre les tables multijoueurs, ni devenir administrateurs. Aucun ordonnanceur ou comportement autonome n’est installé. Les dates restent celles de la création du lot.

Les profils, résultats de recherche et classements signalent les bots ; les statistiques de détenteurs précisent leur nombre. Les soldes humains ne sont pas ajoutés aux profils publics. L’édition est protégée contre les modifications concurrentes ; archiver conserve l’argent et les historiques mais masque le profil et les classements. Pour rendre ses crédits au coffre-fort, l’administrateur peut régler le solde du bot à zéro. La création est atomique et idempotente ; le budget de travail est limité à 4 000 unités par requête.

La migration des bots est appliquée au serveur. Une création complète, le gel, les statistiques et le coffre-fort ont été vérifiés dans une transaction hébergée annulée : aucun bot de recette ne reste en production. Les huit tests dédiés et les tests d’interface/génération de noms passent dans une suite de 84 tests. Les contrôles de `supabase/verify-bots.sql` complètent les vérifications économiques.
