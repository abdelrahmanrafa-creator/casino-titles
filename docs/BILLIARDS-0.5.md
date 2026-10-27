# Billard professionnel / Professional billiards — 0.5.0

## Architecture

- `src/features/Pool.tsx`: orchestration, matchmaking, actions et intégration économique existante.
- `src/features/pool3d/PoolSurface.tsx`: pointeur, souris, pincement et repli WebGL vers SVG.
- `src/features/pool3d/scene.ts`: scène Three.js, géométrie trouée, bandes biseautées, matériaux, éclairage, caméra interpolée, quaternions et nettoyage GPU.
- `src/features/pool3d/materials.ts`: textures procédurales originales, sans téléchargement externe.
- `src/features/PoolPower.tsx`: tirer-relâcher, annulation latérale, commande clavier accessible.
- `src/features/PoolSpin.tsx`: disque de contact limité, combinaison des effets, flèches et Début au clavier.
- `src/features/PoolBoard.tsx`, `src/lib/poolPlayback.ts`: interpolation des trajectoires calculées par le serveur, horodatages et animation synchronisée de la queue.
- Migration `pool_pro_physics_rules`: simulation déterministe PostgreSQL et règles versionnées. Aucun résultat financier ne dépend du rendu client.
- `src/features/admin/AdminUpdates.tsx`: historique administratif bilingue, recherche et dates dans le fuseau du navigateur.
- `scripts/record-update.mjs`: empreinte des sources et historique par version. Les builds identiques ne créent pas de doublon. `implemented_at` désigne la première détection de cette version au build, `recorded_at` le dernier enregistrement de ses sources. Ces dates ne prétendent pas reconstituer un historique antérieur absent.

## Physique / Physics

Le moteur spécialisé est exécuté côté serveur : pas fixe de 1/240 s, rayon 28,575 mm (11 unités), masse 170 g, inertie de sphère pleine 2/5 mr², impulsions normales et friction tangentielle, glissement puis roulement, résistance au roulement, rotation latérale et effet contre les bandes. Les contacts balayés résolvent les croisements rapides entre deux billes. Les entrées de poche comportent des mâchoires arrondies et une zone de capture distincte. Les quaternions sont intégrés à partir des vitesses angulaires puis normalisés. L’IA utilise exactement ce moteur, sans générer de données d’animation pendant sa recherche.

Server-authoritative specialized equal-mass simulation: fixed 240 Hz step, 28.575 mm radius, 170 g mass, solid-sphere inertia, normal and tangential collision impulses, sliding-to-rolling transitions, rolling resistance and cushion spin. Swept pair contacts prevent high-speed crossing; rounded pocket jaws and a separate capture throat model pocket entry. Angular velocities drive normalized quaternions. AI planning uses the same solver with animation capture disabled.

The client interpolates server samples; the physical result is never a predefined animation. The development-only visual fixture is a real local SQL simulation and is excluded from production bundles.

## Règles du club / Club rules

Référence : [WPA Rules of Play](https://wpapool.com/rules/). Les règles du club sont inspirées du huit américain, avec des différences explicites : seule la poche de la noire est annoncée, sans déclaration de sécurité/push-out ; une casse irrégulière donne directement la bille en main partout au lieu du choix de remise en place ; pas de zone de départ imposée ; noire à la casse remise sur un emplacement libre de la ligne du point de replacement ; délai de deux minutes et match nul à 200 tirs. Les nouvelles parties 0.5 utilisent `club-v2`. Les parties existantes et les anciennes applications gardent `house-v1` pour les règles. Le moteur physique est commun. Une bille empochée ou quatre billes distinctes à la bande rendent la casse régulière ; la table reste ouverte après la casse.

WPA-inspired house rules, not a certified implementation of every WPA tournament regulation. Only the eight requires a called pocket. An illegal break grants ball in hand anywhere, rather than a rerack election. There is no head-string placement restriction or safety declaration. The eight is respotted on a free foot-spot line position on the break. Existing two-minute turns and the 200-shot draw remain. Existing matches retain their original rule version; new 0.5 matches request `club-v2`.

## Commandes / Controls

- Souris : déplacer pour viser ; glisser pour ajuster ; visée fine, boutons et clavier disponibles.
- Tir : tirer la queue latérale vers le bas et relâcher. Glisser sur le côté annule ; un petit clic ne déclenche rien. Le bouton de tir et le curseur accessible au clavier restent disponibles.
- Effets : déplacer le point sur la grande bille blanche ; flèches au clavier ; double-clic ou Début pour centrer.
- Camera: perspective or overhead, smooth zoom, fullscreen. Pinch with two pointers to zoom. Lightweight 2D mode is available and WebGL failure falls back automatically.
- Graphics: capped device pixel ratio, adaptive reduction of shadows/resolution after sustained slow frames, demand-driven drawing, hidden-page rendering pause and GPU disposal on unmount. No universal FPS guarantee.

## Exécution / Run and build

```sh
npm ci
npm run dev
npm test
npm run build
npm run app:windows
npm run app:android
npx cap sync ios
```

La migration doit être appliquée avant de publier le client 0.5. Les commandes complètes de signature et de distribution sont dans [APPLICATIONS.md](APPLICATIONS.md). iOS nécessite macOS, Xcode et la signature Apple ; un projet synchronisé sur Windows n’est pas une IPA testée.

Apply the new migration before shipping the 0.5 client. Windows and Android builders preserve the existing online accounts and automatic-update mechanism. See APPLICATIONS.md for signing, installation and iOS requirements.

Pour les prochaines mises à jour : incrémenter la version, mettre à jour `release-notes.json` en français et en anglais, puis lancer le build. L’historique est versionné dans Git avec le code. Build timestamps record preparation, not a fabricated deployment time.

## Limites / Limitations

Simulation sur table plane : pas de saut, massé, courbure de queue ou bille projetée hors table. Frottements et restitution sont calibrés, pas mesurés sur une table réelle. Le rendu interpole des échantillons réseau : il n’est pas une capture vidéo à 240 images/s. Le calcul est borné à 30 secondes simulées par tir pour protéger le serveur. Les capteurs tactiles, performances GPU et politiques audio diffèrent selon les appareils ; une validation responsive en navigateur ne remplace pas des tests physiques sur tous les téléphones. Les transitions de caméra et effets sont réduits selon les préférences d’accessibilité.

Planar simulation with calibrated coefficients, not a laboratory table model. No jumps, masse shots or balls leaving the table. Network rendering interpolates sampled positions and rotations. Simulation is bounded to 30 seconds per shot. Adaptive graphics and responsive tests do not certify performance on every phone. Platform-specific audio and touch behavior still depend on the device. No physical iPhone testing or IPA compilation is implied by a successful web build.

## Dépendances / Dependencies

Three.js 0.186.1 (MIT), with @types/three 0.186.0 for development. No generic physics library: the specialized authoritative solver runs in PostgreSQL. RoomEnvironment and RoundedBoxGeometry are bundled Three.js add-ons. Textures and sound synthesis are original; no unlicensed external assets are fetched.
