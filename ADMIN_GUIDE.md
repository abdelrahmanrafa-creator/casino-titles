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

84 tests automatisés réussis, compilation TypeScript/Vite et dix-neuf contrôles réseau. L’aperçu du panneau a été contrôlé visuellement avec des données de test identifiées. Le parcours complet avec le véritable compte du propriétaire reste à effectuer lors de son activation initiale ; les tests ne consomment pas cette activation.

Les sauvegardes et les limites du multijoueur sont documentées dans `BACKUPS.md` et `README.md`. Aucun encaissement ni retrait d’argent réel n’est intégré.

## Codes promotionnels
Dans Codes promo, choisir Nouveau code, définir le texte du code, son nom, les crédits et/ou un titre offert, les dates, le plafond global éventuel et son activation. Ajouter une justification en haut du panneau puis enregistrer. Partager ensuite le code choisi avec les joueurs : ils le saisissent dans Crédits gratuits. Une utilisation par compte. Pour arrêter une campagne, sélectionner son code puis décocher Code actif et enregistrer. Une modification conserve les utilisations déjà effectuées.

## Économie & coffre-fort
Ouvrir cet onglet pour suivre la circulation des crédits et vérifier la ligne Comptabilité équilibrée. Le journal affiche pour chaque mouvement le montant du coffre-fort et le montant opposé côté joueur. Une prime de bienvenue produit −5 000 au coffre-fort et +5 000 au joueur ; un coffre acheté 500 produit +500 et −500. Les dates et catégories permettent de filtrer le journal ; les graphiques et totaux de période restent indépendants du filtre de catégorie. Les crédits engagés aux tables sont affichés à part et ne sont pas disponibles pour le serveur. Le suivi reprend aussi les opérations antérieures à son activation.

## Bots
1. Ouvrir Bots → Créer un lot. Choisir 1 à 25 comptes, le style de noms et l’avatar. Vérifier ou remplacer les pseudos affichés.
2. Répartir le nombre de bots par meilleure rareté ; la somme doit correspondre au lot. Exemple pour dix bots : deux Communs, trois Rares, deux Épiques, un Légendaire, un Rainbow et un Xtrem. Le nombre de titres de la meilleure rareté est réglable séparément. Aucun Cosmique n’est autorisé.
3. Fixer les fourchettes de titres uniques, de soldes, de coffres simulés et de parties, ainsi que le taux de victoire. Une sélection facultative précise les titres autorisés. Chaque rareté doit disposer d’assez de titres pour la fourchette demandée.
4. Ajouter une justification en haut du panneau et cliquer Créer et figer. La liste permet ensuite de renommer, ajuster le solde, masquer des classements ou archiver un bot. Les titres peuvent être attribués/révoqués dans Joueurs, jusqu’à Xtrem.

Les comptes restent figés sans activité automatique. Les historiques générés sont étiquetés simulés et les profils portent le badge Bot. Archiver ne restitue pas automatiquement le solde : le régler à zéro pour le rendre au coffre-fort. Le journal économique distingue financement, coffres, mises, gains et ajustements des bots. Créer plusieurs lots pour dépasser vingt-cinq bots, avec un maximum de cinq mille profils simulés.

Profils publics : le solde, les statistiques solo agrégées, les mises complètes au blackjack et les places actuelles dans les dix Top 50 sont affichés. Aucun historique d’apparitions n’est inventé. La collection affiche les exemplaires du compte, les exemplaires actifs en circulation, les détenteurs distincts et le pourcentage sur tous les comptes actifs (sans suspension), avec ou sans titre. Actualisation toutes les 30 secondes. L’identification des comptes simulés est réservée à l’administration : indicateurs exclus des RPC publics et accès direct aux colonnes privées des profils révoqué.

Les lots de bots proposent un taux de victoire minimum et maximum (35–68 % par défaut). Le serveur choisit un taux indépendant par bot ; le nombre de victoires est entier, donc le pourcentage affiché dépend aussi du nombre de parties. Des bornes égales imposent un taux fixe. Les anciennes requêtes avec win_percent restent compatibles. La migration 20261022190004 varie une fois les résultats Coinflip simulés des bots actifs existants ; les soldes sont conservés via deux écritures opposées et chaque ajustement est tracé dans le journal admin. Les parties réelles ne sont pas modifiées.

Mode compact des bots (migration 20261022190005) : les nouveaux lots du panel utilisent une seule ligne ct_bot_summaries par bot pour les parties/coffres et 1 à 5 écritures de portefeuille selon les montants, toujours contre-passées dans le coffre-fort. Aucun événement fictif individuel n’est ajouté à ct_game_rounds ou ct_chest_openings. Les titres uniques gardent leurs instances ; les exemplaires supplémentaires sont regroupés dans quantity. Les anciens bots et leurs historiques sont conservés.

Limites : 250 bots par requête, 5 000 titres uniques maximum par lot, 50 000 bots au total en mode compact ; arrêt préventif de toute création si la taille courante de la base dépasse 350 000 000 octets. Ce seuil prudent ne constitue pas une mesure des quotas de l’abonnement. Le stockage réel est affiché dans la rubrique Bots. Le plafond total est soumis au seuil de stockage : 50 000 bots ne sont pas une capacité garantie sur l’offre gratuite.

Trafic : suppression du polling du tableau de bord et de la liste des bots, accès admin vérifié chaque minute au lieu de 5 s, catalogue mis en cache 5 min, coffres toutes les minutes, statistiques de collection/profil toutes les 2 min. Les écritures autorisées invalident les données concernées. Les 5 Go d’egress de l’offre Free sont distincts des 500 Mo de base (documentation Supabase consultée le 22 octobre 2026) ; la consommation mensuelle exacte reste à consulter dans Supabase et dépend des visiteurs et des autres usages du projet. Aucun plafond de trafic mensuel ne peut être garanti par ces optimisations.

Validation locale : lot de 250 bots, 5 000 titres uniques et 75 000 événements simulés créé puis annulé dans une transaction ; environ 1,6 s dans PGlite lors du test, sans valeur de SLA pour Supabase. Vérifications de profils, classements, exemplaires, confidentialité, répétition idempotente et comptabilité incluses.

Marché noir et diamants (20261022190007) : rubrique /market réservée aux comptes joueurs actifs. Les bots restent figés et ne peuvent ni créer d’annonce ni accepter un échange. Conversion unidirectionnelle au taux fixe 1 diamant pour 1 000 crédits (1 à 10 000 diamants par opération), crédits reversés au coffre-fort ; aucun argent réel. Ledger diamant privé distinct du portefeuille de crédits. Les ventes transfèrent exactement le prix au vendeur, sans commission.

Objets : titres de collection (un exemplaire actif), et coffres scellés achetés au tarif standard en crédits depuis le marché. Seuls les coffres standards actifs sans limites de stock/individuelles sont vendus scellés ; les promotions et coffres événementiels restent dans le flux d’ouverture immédiate existant. Un coffre scellé capture ses probabilités et les titres éligibles ; aucune facturation supplémentaire à l’ouverture, aucune seconde consommation du stock. La rareté ou suppression d’un titre référencé par un coffre scellé non ouvert est bloquée pour conserver ce contenu. Les anciens coffres déjà ouverts ne deviennent pas scellés.

Annonces : jusqu’à 20 actives par joueur, expiration après 7 jours, consultation paginée par 50. Vente en diamants ou échange contre un titre/coffre précis, avec supplément facultatif en diamants. Destinataire facultatif par pseudo exact ; les offres privées sont visibles seulement du vendeur et du destinataire. Un objet réservé ne peut pas être équipé/ouvert/engagé dans un autre échange ; mise en vente déséquipe le titre. Annulation avant acceptation, y compris après expiration. Paiement et deux transferts d’objets dans une transaction atomique avec reçu idempotent ; historique des titres acquis conservé par révocation de l’ancien exemplaire et création de l’exemplaire reçu. Aucun client n’écrit directement les tables de marché, coffres scellés ou diamants.

Admin : onglet Diamants pour attribution/retrait sur pseudo exact, justification de 8 caractères minimum et audit obligatoire. Un administrateur peut aussi annuler une annonce via la commande de marché. Historique des échanges et des mouvements visible pour chaque participant. Les données de marché ne sont pas rafraîchies en boucle ; bouton Actualiser et invalidation après opération. Le solde diamant du bandeau se rafraîchit au plus toutes les deux minutes, avec invalidation immédiate après une commande réussie.
