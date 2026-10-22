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

La console est `/admin`, sans lien dans la navigation publique. Son accès exige un compte confirmé, un rôle administrateur et un déverrouillage par code secret lié à la session Auth. L’activation initiale unique se fait avec le code généré dans `.admin-access.local.txt`, exclu de Git et de la publication. Aucun premier inscrit ne devient administrateur sans ce code. Voir `ADMIN_GUIDE.md`.

## Validation et limites de recette
55 tests automatiques passent : paiements, permissions, restauration physique locale, coffres, combinaisons poker, pots secondaires, cartes privées, règles du Blackjack/Baccarat, missions, événements, révocation, paramètres, offres, stocks, sessions administrateur, rotation du code et affichage du prix barré. PGlite sérialise les transactions ; les tests locaux ne prouvent pas seuls le comportement de connexions PostgreSQL concurrentes.

Une recette supplémentaire sur le Supabase hébergé a utilisé une identité synthétique sans adresse e-mail ni mot de passe, supprimée après les tests : deux demandes quotidiennes concurrentes ont versé une seule récompense ; douze ouvertures concurrentes avec 5 750 crédits ont produit exactement onze titres, onze historiques et un solde de 250. Les douze assertions de `supabase/verify.sql` passent sur l’hébergement.

Contrôle visuel effectué dans le navigateur intégré sur une largeur mobile : accueil, coffres, probabilités et album réel. La compilation ne remplace pas la recette de deux navigateurs authentifiés : inscription/e-mail, Realtime entre deux utilisateurs, perte de connexion et charge prolongée restent à valider sur l’hébergement avant de qualifier le multijoueur de prêt à grande échelle. Les timeouts sont traités par le serveur à la synchronisation ou à la reconnexion ; il n’y a pas de tâche planifiée autonome quand tous les clients sont fermés.

Les règles du Blackjack sont configurables côté administrateur : S17/H17, paiement naturel 3:2 ou 6:5, deux à quatre mains, double après séparation. Leur version est fixée au début de chaque manche et ne peut changer une manche en cours. Les classements de victoires concernent les parties solo. Les modes publics sont sans vrai argent ni conversion. Les sauvegardes hors site et PITR ne sont pas activées automatiquement : voir `BACKUPS.md`.

Le contrôle Supabase relève aussi des alertes sur les anciennes tables du projet parent. Ce nouveau site ne les utilise pas et ce travail n’a pas modifié leurs politiques. Les nouvelles tables privées sans politique de lecture sont volontairement fermées ; les RPC publiques de classement/profil ne renvoient que leur projection publique.
