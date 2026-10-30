# Échanges directs — 0.6.0

Le salon présente la proposition de chaque participant côte à côte, avec des piles d’objets, leurs raretés et les diamants proposés. Chaque pile dispose de commandes de quantité et d’un bouton Tout. Tout ajouter remplit la proposition avec les groupes correspondant à l’onglet et à la recherche, dans la limite de 1 000 exemplaires par joueur.

Les modifications locales sont enregistrées automatiquement après une courte pause de saisie. Les requêtes successives sont espacées pour conserver les protections de fréquence du serveur. Le participant peut continuer à composer pendant l’enregistrement. Les modifications reçues de l’autre joueur ne remplacent pas un brouillon local. La confirmation et la fermeture sont bloquées pendant une sauvegarde en attente. Une erreur d’enregistrement est affichée et peut être réessayée ; deux nouvelles tentatives automatiques au plus sont permises lorsqu’une version concurrente a changé.

`ct_trade_workspace` renvoie des groupes et des quantités, sans charger un tableau d’identifiants pour tout l’inventaire. L’identité d’une pile de coffres tient compte du catalogue d’origine, du nom, de la rareté, des probabilités, de la sélection de titres et de l’événement. Deux coffres personnalisés aux contenus différents ne sont pas fusionnés. Les numéros de série individuels sont conservés.

`ct_trade_bulk_offer` valide le participant, sa carte, les suspensions, la version, son solde et les quantités. Une lecture de l’inventaire sélectionne les exemplaires réels, en conservant ceux déjà réservés par cette proposition en priorité. La commande délègue ensuite au moteur existant d’échange. Le plafond historique de dix objets est porté à mille. Les accès, réservations, contrôles de propriété, transferts atomiques, protection contre les relectures réseau et reçus restent appliqués. Une sauvegarde identique ne modifie ni version ni confirmations.

Les mutations du salon déclenchent les notifications privées de synchronisation déjà installées. La requête de salon conserve la racine de cache `trade-room`. Le contrôle périodique sert de secours. Toute modification effective de l’offre annule les deux confirmations ; seules deux confirmations sur la même version peuvent conclure l’échange.

L’inventaire propose séparément Caractéristiques du coffre et Signature et provenance. La fiche affiche les probabilités conservées sur le coffre, son état, sa date, son prix enregistré, son édition et la taille de sa sélection personnalisée, même lorsqu’il est réservé. Elle ne lance jamais une ouverture.

Tests : échanges de 500 coffres, transferts/diamants/reçus sans doublons, versions concurrentes, absence de modifications en cas d’erreur, accès privés, distinction des contenus personnalisés et interface français/anglais. Le parcours `/__trade-preview` est une fixture interactive réservée au développement, sans appel d’écriture au serveur ni présence dans la version de production.
