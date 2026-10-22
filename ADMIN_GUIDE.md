# Administration Casino & Titles

Ouvrir `/admin` sur le nouveau site, se connecter à son compte confirmé puis entrer le code contenu dans le fichier local privé `.admin-access.local.txt`. Le premier déverrouillage attribue le rôle à ce compte et ferme définitivement l’activation initiale. Ce fichier ne fait partie ni de Git ni du site publié.

Les prochains administrateurs doivent recevoir explicitement le rôle depuis Sécurité et connaître le code. Une adresse discrète seule ne protège rien : toutes les opérations vérifient les droits côté serveur. Le code n’est jamais enregistré dans le navigateur, les reçus ou les journaux. Cinq échecs déclenchent un blocage de dix minutes. Le déverrouillage expire après trente minutes et dépend de la session Auth. La rotation du code invalide les autres déverrouillages.

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

55 tests automatisés réussis, compilation TypeScript/Vite et neuf contrôles réseau. L’aperçu du panneau a été contrôlé visuellement avec des données de test identifiées. Le parcours complet avec le véritable compte du propriétaire reste à effectuer lors de son activation initiale ; les tests ne consomment pas cette activation.

Les sauvegardes et les limites du multijoueur sont documentées dans `BACKUPS.md` et `README.md`. Aucun encaissement ni retrait d’argent réel n’est intégré.
