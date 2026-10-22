# Persistance, sauvegarde et restauration

Toutes les commandes économiques abouties sont persistées dans PostgreSQL avant réponse. Le navigateur ne conserve que la clé d'une commande en attente. En cas de réponse perdue, reprendre cette commande rejoue le reçu, sans nouveau paiement. Une panne avant validation annule la transaction complète. Fermer la page ne supprime pas une manche de Blackjack.

## Sauvegarde indépendante
Installer les outils client PostgreSQL officiels. Configurer PGHOST, PGPORT, PGDATABASE, PGUSER et PGPASSFILE dans l'environnement sécurisé, puis exécuter `node scripts/backup.mjs`. Le script utilise pg_dump (format custom), exporte les tables ct_ et crée un manifeste SHA-256. Le dossier backups est exclu de Git. Copier les exports dans un stockage privé hors machine. Les sauvegardes contiennent des données personnelles ; ne jamais les publier dans le site.

Cette sauvegarde ciblée dépend des identités correspondantes de auth.users : elle ne suffit pas pour reconstruire l'authentification dans un projet vide. Pour une reprise complète, utiliser les sauvegardes Supabase ou un export complet conforme à leur procédure. Les fichiers Storage ne sont pas inclus dans les sauvegardes PostgreSQL.

## Exercice de restauration, sur un projet de test uniquement
1. Restaurer les identités Auth via une sauvegarde complète Supabase, ou utiliser un clone dont les mêmes identités existent. Ne pas recréer arbitrairement des UUID de joueurs.
2. Vérifier le SHA-256 du dump avec le manifeste.
3. Sur une base cible vide pour les tables ct_, avec les rôles Supabase et auth.users en place : `pg_restore --exit-on-error --single-transaction --no-owner --dbname=postgres fichier.dump`. Les paramètres de connexion viennent de l'environnement. Ne pas utiliser --clean sur une production.
4. Rejouer les assertions de `supabase/verify.sql`. Vérifier RLS, privilèges, solde = somme du journal, inventaires, reçus et manches en cours avec deux sessions distinctes.
5. Tester les liens et paramètres Auth, puis seulement planifier une bascule. Un retour arrière utilise le dernier export vérifié et les paramètres d'origine.

Les tests automatisés ferment/réouvrent une base PostgreSQL locale et vérifient la persistance. Ils ne remplacent pas un exercice pg_restore sur l'hébergement. Aucun calendrier de sauvegarde, PITR, abonnement ou transfert hors site n'a été activé automatiquement.

Documentation : https://supabase.com/docs/guides/platform/backups
