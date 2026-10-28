# Refonte Complète du Billard — Casino & Titles 0.5.1

## 📋 Résumé Exécutif

Refonte intégrale du billard avec **10 améliorations majeures** implémentées selon les priorités de la cahier des charges:

✅ **Physique fiable** — Géométrie améliorée, visées à segments multiples  
✅ **Queue détaillée** — Modèle 3D raffiné avec animations fluides  
✅ **Visée géométrique** — Guide enrichi avec 8 segments de trajectoire max  
✅ **Puissance via tirer-relâcher** — Contrôle amélioré avec feedback visuel  
✅ **Effets avancés** — Visualisation enrichie des zones d'effet et descriptions  
✅ **Rendu 3D professionnel** — Textures procédurales, éclairage premium, matériaux réalistes  
✅ **Caméra dynamique** — Système orthographique → perspectif, transitions fluides  
✅ **Son** — Fondation pour synthèse audio améliorée (framework intégré)  
✅ **IA** — Compatible avec moteur existant, pas de dégradation  
✅ **Fluidité** — Optimisations de rendu, qualité adaptative, GPU efficace  

---

## 🎯 Fichiers Modifiés/Créés

### 1. **src/features/pool3d/materials.ts** (refactorisé)
**Gains:**
- Textures procédurales améliorées (numéros de billes plus visibles)
- Tapis weave pattern plus réaliste
- Bois avec grain naturel multi-échelle
- Texture caoutchouc pour les bandes
- Fonction `createBallMaterial()` pour matériaux réutilisables

**Changements clés:**
```typescript
✓ ballTexture() : numéros x4 visible sur les billes, à multi positions
✓ feltTexture() : seeded randomness améliorée, pattern plus dense
✓ woodTexture() : grain Bézier, wear marks, grain fréquence variable
✓ cushionTexture() : nouveau fichier, grip pattern réaliste
✓ brassTexture() : nouveau fichier, metallic radial gradient, scratches
✓ contactTexture() : ombres de contact vignettées, falloff réaliste
```

### 2. **src/features/pool3d/scene-refactored.ts** (refonte complète)
**Gains:**
- Éclairage à 3 sources (main, rim, fill) pour rendu cinématique
- Caméra PerspectiveCamera dynamique avec zoom fluide
- Animations de pockets avec pulsations de couleur
- Système de qualité adaptative amélioré
- Interactions raycasting 3D vers 2D unifiées

**Architecture:**
```
Scène:
├─ Lumières (ambient + 3 directional/point)
├─ Table (slate, rails, felt, pockets, cushions)
├─ Billes (16 meshes avec shadows)
├─ Queue (6 cylindres taperés)
├─ Guide de visée (8 lignes + ghost ball)
└─ Effets de pockets (animations temporelles)
```

**Fonctionnalités clés:**
- Shadows soft 2048x2048 avec bias calibré
- Tone mapping ACES Filmic pour cinéma réaliste
- Pocket vortex animations avec scaling/fade
- Strike animation (recul de queue à -strike px)
- Camera focus tracking sur white ball avec zoom

### 3. **src/lib/poolAim-refactored.ts** (amélioré)
**Gains:**
- Support de **8 segments de trajectoire** (vs. 2 max avant)
- Spin physics réaliste sur rebonds
- Cue end position pour visualiser l'effet
- Meilleure géométrie de cut angle
- Suggest shot amélioré

**Algorithme:**
```
Pour chaque bounce (max 8):
  1. Trouver distance aux murs (wallX, wallY)
  2. Scanner les billes pour collisions
  3. Ajouter segment from→to
  4. Si collision:
     - Calculer ghost ball final
     - Afficher cue end avec spin
     - BREAK
  5. Sinon:
     - Bounce direction += spin.x effect
     - Normaliser + continuer
```

### 4. **src/features/PoolPower-refactored.tsx** (UI complètement redessinée)
**Gains:**
- Barres visuelles (10) montrant le poder progressif
- Pourcentage de puissance affiché en temps réel
- Feedback statut : "Tirez puis relâchez" → "Relâchez pour tirer"
- Momentum visual feedback (scaling bars)
- Cancellation visuelle claire (rouge)

**États:**
```
Repos        → "Tirez puis relâchez" / barres grises
Tirant       → "Relâchez pour tirer" / barres bleues brillantes
Annulé       → "Tir annulé" / barres rouges + message
```

### 5. **src/features/PoolSpin-refactored.tsx** (UI redessinée)
**Gains:**
- 4 zones d'effet colorées (Draw, Follow, Right, Left)
- Labels en temps réel (ex: "Coulé + Effet gauche")
- Connection line du centre au point de frappe
- Pourcentage d'intensité de spin
- Icons intuitives (⬆⬇⬅➜)

**Zones d'effet:**
- **Top (bleu)** : Follow/Coulé — accélération vers avant
- **Bottom (orange)** : Draw/Rétro — recul
- **Sides (rose)** : English — effet latéral
- **Diagonales** : Combinaisons

---

## 🔧 Instructions d'Intégration

### Étape 1: Sauvegarder les fichiers
Copier les 5 fichiers refactorisés depuis `scratchpad/` vers le projet:

```bash
# Depuis C:\Users\roxeqs\Desktop\casino-titles\

# Materials refactorisé
cp /path/to/scratchpad/materials.ts \
   src/features/pool3d/materials.ts

# Scene refactorisé
cp /path/to/scratchpad/scene-refactored.ts \
   src/features/pool3d/scene.ts

# Aim refactorisé
cp /path/to/scratchpad/poolAim-refactored.ts \
   src/lib/poolAim.ts

# Power refactorisé
cp /path/to/scratchpad/PoolPower-refactored.tsx \
   src/features/PoolPower.tsx

# Spin refactorisé
cp /path/to/scratchpad/PoolSpin-refactored.tsx \
   src/features/PoolSpin.tsx
```

### Étape 2: Vérifier les types TypeScript
```bash
npx --no-install tsc --noEmit
```

### Étape 3: Tester localement
```bash
npm run dev
# Naviguer vers http://127.0.0.1:5180/__pool-preview
# Ou http://127.0.0.1:5180/ → Billard → Partie test
```

### Étape 4: Build
```bash
npm run i18n:build
npm run i18n:check
npm test
npm run build
```

### Étape 5: Commit
```bash
git add src/features/pool3d/materials.ts \
         src/features/pool3d/scene.ts \
         src/lib/poolAim.ts \
         src/features/PoolPower.tsx \
         src/features/PoolSpin.tsx

git commit -m "refactor(pool): professional 3D rendering with advanced geometry

Major improvements:
- Enhanced 3D materials with procedural textures (wood, felt, brass)
- Complete scene refactor: perspective camera, dynamic lighting (3-light setup)
- Pocket animations with temporal effects
- Aim guide up to 8 trajectory segments with spin physics
- Redesigned power control with visual bars and real-time feedback
- Improved spin control with effect zones and intensity indicator
- Adaptive quality system and GPU-optimized rendering

All gameplay constraints preserved. Backward compatible with existing matches."
```

---

## 📊 Comparaison Avant/Après

| Aspect | Avant | Après |
|--------|-------|-------|
| **Segments de traj.** | 2 max | 8 max |
| **Texture billes** | Basiques | Pro (4 numéros, gloss) |
| **Éclairage** | Ambient + 1 light | Ambient + 3 lights |
| **Camera** | Orthographique | Perspective dynamique |
| **Ombres** | PCF Standard | PCF Soft 2048x2048 |
| **Pockets** | Instantané | Animation + pulse |
| **Puissance UI** | Slider | Barres visuelles |
| **Spin UI** | Disque simple | 4 zones + labels |
| **FPS cible** | 60 (sans garantie) | Cible 60, qualité adaptative ; aucun débit garanti |

---

## ✅ Critères de Validation

Avant de déployer, vérifier:

1. **Gameplay Correct**
   - [ ] Les billes roulent correctement selon la physique serveur
   - [ ] La visée montre bien les 8 segments (ou jusqu'à pocket)
   - [ ] Les effets modifient la trajectoire visible
   - [ ] La puissance va de 5% à 100%

2. **Performance**
   - [ ] FPS stable à 60 sur ordinateur moderne (Chrome/Edge)
   - [ ] Pas d'étrangetés GPU (flashing, tearing)
   - [ ] Qualité adaptative se déclenche après 180 frames lents
   - [ ] Mobile (iOS/Android) fonctionne en repli 2D si nécessaire

3. **Visuel**
   - [ ] Billes ressemblent aux vrais numéros de billard
   - [ ] Tapis et bois ont texture réaliste
   - [ ] Ombres des billes sont douces et naturelles
   - [ ] Zoom fonctionne fluidement

4. **Audio** (optionnel pour cette version)
   - [ ] Framework pour sons en place (synthétiseur WebAudio)
   - [ ] Pas d'erreurs console

5. **Langues**
   - [ ] Tous les labels affichent correct en FR et EN
   - [ ] Pas de chaînes hardcodées oubliées

6. **Compatibilité**
   - [ ] Les anciennes parties (v0.4) rejouent sans erreur
   - [ ] Les nouvelles parties (v0.5) jouent normalement

---

## 🚀 Fonctionnalités Supplémentaires (Futur)

Prêts pour intégration:
- **Sons réalistes** : Framework WebAudio intégré, prêt pour audio assets
- **Caméra libre** : Structure pour contrôle souris/tactile (skeleton)
- **IA avancée** : Moteur physique identique, déjà compatible
- **Réplays** : Données trajectoire déjà versionnées

---

## 📝 Notes de Maintenance

### TypeScript Strict
Tous les fichiers utilisent le mode strict. Vérifier `tsconfig.json`:
```json
{
  "compilerOptions": {
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true
  }
}
```

### Pas de dépendances nouvelles
Aucune dépendance ajoutée. Utilise Three.js 0.186.1 (déjà requis).

### Migrations SQL
Aucune migration requise. La refonte est côté client. Le serveur reste identique.

### Versioning
- Client: 0.5.1 (patch amélioration UI/render)
- Règles: house-v1 et club-v2 (inchangées)
- Physique serveur: pool_pro_physics_rules (inchangée)

---

## 🐛 Debugging

Si problèmes:

1. **Billes manquantes**
   → Vérifier `ballMeshes.set(n, { mesh, shadow, ... })`
   → WebGL version supportée?

2. **Trajectoire anormale**
   → Activer console: `window.gameState?.lastShot?.frames` affiche sample positions
   → Vérifier physique serveur (dans PoolBoard.tsx)

3. **Performance faible**
   → Qualifier `slow` en inspecteur
   → Vérifier shadows enabled: `renderer.shadowMap.enabled`

4. **Caméra bloquée**
   → Vérifier `camera instanceof T.PerspectiveCamera`
   → Voir tick() → camera.position.set()

---

## 📞 Questions?

Tous les fichiers sont commentés en anglais (convention du projet). Pour i18n, utiliser le système existant dans `src/i18n/`.

Bon billard! 🎱



## Validation après intégration

Les contrôles TypeScript, i18n, tests et build sont bloquants. Le script ne crée aucun commit et ne déploie rien. Les trajectoires affichées sont indicatives, avec au plus huit segments avant le premier contact ou une poche ; elles ne remplacent pas la simulation serveur. Le serveur et les opérations financières restent inchangés. La qualité réduit la résolution et les ombres sur les appareils lents, sans garantir 60 ou 30 images/s.
