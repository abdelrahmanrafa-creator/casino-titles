# Synchronisation des données — 0.5.2

Les écritures validées par PostgreSQL émettent des signaux Supabase Broadcast privés. Ils contiennent uniquement un domaine à actualiser, jamais de données du joueur. Les clients relisent les données par les RPC et politiques existantes.

- `ct:live:user:<uid>` : solde, inventaire, carte, accès, récompenses, messages privés et commandes du joueur concerné.
- `ct:live:global` : catalogues, marchés, actualités, profils publics et classements.
- `ct:live:admin` : tableaux de bord et outils de gestion. Réservé au rôle administrateur vérifié par le serveur.
- Les tickets et échanges avertissent les participants concernés.

Le navigateur regroupe les notifications sur 400 ms, marque les caches concernés périmés et recharge uniquement les requêtes actives. Les pages inactives liront des données fraîches à leur prochaine ouverture. Les lectures déjà en cours ne sont pas annulées ; une seconde lecture rattrape les changements reçus pendant leur exécution. Les saisies locales sont conservées.

Un retour en ligne, au premier plan ou une reconnexion WebSocket relance la synchronisation. Un contrôle toutes les 30 secondes rattrape les événements manqués et les expirations temporelles. Une page masquée ne recharge pas les données via ce mécanisme. Les intervalles plus spécifiques des jeux sont conservés ; la lecture des images d’une partie de billard n’est pas interrompue.

Le serveur déduplique les notifications par transaction, domaine et destinataire. Les changements de catalogues/marchés utilisent des déclencheurs par instruction avec tables de transition : une commande affectant beaucoup d’annonces émet un signal par domaine ; une instruction ne modifiant aucune ligne n’en émet aucun. Les signaux sont transactionnels : une opération annulée ne diffuse rien. Une défaillance du transport ne doit pas faire échouer une transaction économique valide.

Les canaux privés nécessitent une session, y compris une session invitée. Aucun droit d’écriture aux signaux n’est accordé aux joueurs. Les fonctions de notification sont réservées aux déclencheurs internes. La migration n’élargit aucun accès aux données métier. Une notification ne constitue jamais une autorisation ou une valeur financière fiable.

Les futurs ajouts doivent inclure leur clé de requête dans `src/lib/liveSync.ts` et un déclencheur sur leurs tables pertinentes. Les événements fréquents de physique/rate-limit et les journaux de lectures ne sont pas diffusés. Les déploiements de nouveau code restent distincts de la synchronisation des données : les anciennes applications doivent installer leur mise à jour pour obtenir ce mécanisme.

Vérification : `node --test tests/live-sync.test.mjs`, puis `npm test` et `npm run build`.
