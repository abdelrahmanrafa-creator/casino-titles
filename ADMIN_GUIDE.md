# Administration Casino & Titles

Ouvrir `/admin` sur le nouveau site, se connecter à son compte confirmé puis entrer le code contenu dans le fichier local privé `.admin-access.local.txt`. Le premier déverrouillage attribue le rôle à ce compte et ferme définitivement l’activation initiale. Ce fichier ne fait partie ni de Git ni du site publié.

Les prochains administrateurs reçoivent explicitement le rôle depuis Sécurité. Tout compte connecté ayant ce rôle accède directement au panneau sans code supplémentaire, y compris après reconnexion. Le code reste réservé à l’activation initiale unique. Le retrait du rôle ou une suspension bloque les opérations côté serveur. Aucun code n’est mémorisé dans le navigateur. Les anciennes sessions de déverrouillage ne conditionnent plus les permissions. La rotation du code ne retire aucun rôle.

## Fonctions

- Vue d’ensemble et statistiques du cercle.
- Recherche des joueurs, historique, crédits justifiés, attribution/révocation de titres et suspension.
- Création et modification des coffres, probabilités totalisant exactement 100 %, thème, calendrier, stock, limite par joueur et sélection des titres.
- Coffres événementiels, titres exclusifs et dates de disponibilité.
- Offres programmées : prix de base réel conservé, nouveau prix inférieur, prix barré, pourcentage, stock et limite par joueur. Une offre gratuite exige une limite individuelle.
- Gestion des titres, événements, récompenses, missions et couleurs des raretés.
- Pause des sept jeux et limites de mise ; les manches déjà engagées peuvent être terminées.
- Règles du Blackjack, rôles administrateur, rotation du code et audit paginé avec recherche.

Chaque modification exige une justification. Les prix, dates, stocks, soldes et permissions sont validés par PostgreSQL ; une modification de l’offre depuis son affichage impose une nouvelle confirmation du joueur. Les stocks sont verrouillés pendant l’achat et le titre, le débit et l’historique sont enregistrés dans la même transaction.

## Vérification

64 tests automatisés réussis, compilation TypeScript/Vite et treize contrôles réseau. L’aperçu du panneau a été contrôlé visuellement avec des données de test identifiées. Le parcours complet avec le véritable compte du propriétaire reste à effectuer lors de son activation initiale ; les tests ne consomment pas cette activation.

Les sauvegardes et les limites du multijoueur sont documentées dans `BACKUPS.md` et `README.md`. Aucun encaissement ni retrait d’argent réel n’est intégré.

## Codes promotionnels
Dans Codes promo, choisir Nouveau code, définir le texte du code, son nom, les crédits et/ou un titre offert, les dates, le plafond global éventuel et son activation. Ajouter une justification en haut du panneau puis enregistrer. Partager ensuite le code choisi avec les joueurs : ils le saisissent dans Crédits gratuits. Une utilisation par compte. Pour arrêter une campagne, sélectionner son code puis décocher Code actif et enregistrer. Une modification conserve les utilisations déjà effectuées.
