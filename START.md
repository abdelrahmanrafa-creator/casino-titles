# 🚀 DÉMARRAGE RAPIDE — Billard Refactorisé

## ⚡ Faire fonctionner en 2 minutes

### **Option 1: Script Automatisé (Recommandé)**

Ouvre **PowerShell** dans `C:\Users\roxeqs\Desktop\casino-titles\` et exécute:

```powershell
.\validate-and-integrate.ps1
```

✅ Le script va:
- ✓ Vérifier que tous les fichiers sont en place
- ✓ Vérifier TypeScript
- ✓ Vérifier i18n
- ✓ Lancer les tests
- ✓ Faire le build
- ✓ Afficher le statut Git

Après, tu verra les prochaines étapes.

---

### **Option 2: Commandes Manuelles**

Si tu préfères les commandes une par une:

```bash
# 1. Vérifier les types
npx --no-install tsc --noEmit

# 2. Construire les traductions
npm run i18n:build
npm run i18n:check

# 3. Lancer les tests
npm test

# 4. Build production
npm run build

# 5. Vérifier les changements
git status
```

---

## 🎮 Tester Localement

Une fois les validations passées:

```bash
npm run dev
```

Puis ouvre: **http://127.0.0.1:5180/**

Clique sur **Billard** → **Contre l'ordinateur** → **Jouer**

### À vérifier:
- ✓ Billes avec numéros visibles
- ✓ Table 3D réaliste
- ✓ Barres de puissance (0-100%)
- ✓ Zones de spin colorées
- ✓ Trajectoires détaillées (5-8 segments)

---

## 📤 Déployer

Une fois testé localement:

```bash
# Ajouter les fichiers modifiés
git add src/features/pool3d/materials.ts \
        src/features/pool3d/scene.ts \
        src/lib/poolAim.ts \
        src/features/PoolPower.tsx \
        src/features/PoolSpin.tsx

# Créer le commit
git commit -m "refactor(pool): professional 3D rendering with advanced geometry

Major improvements:
- Enhanced 3D materials with procedural textures (wood, felt, brass, cushions)
- Complete scene refactor: perspective camera, dynamic lighting (3 lights)
- Pocket animations with temporal effects
- Aim guide extended to 8 trajectory segments with spin physics
- Power control redesigned with visual bars and momentum feedback
- Spin control with 4 effect zones and intensity indicator
- Adaptive quality system and GPU-optimized rendering

All gameplay constraints preserved. Backward compatible with existing matches."

# Pusher
git push origin main
```

---

## 📚 Documentation

| Fichier | Contenu |
|---------|---------|
| **REFONTE_BILLARD.md** | Résumé technique complet |
| **GUIDE_INTEGRATION_COMPLET.md** | Procédure détaillée + FAQ |
| **validate-and-integrate.ps1** | Script de validation |

---

## ✨ C'est tout!

Voilà, tu as maintenant un billard professionnel avec:
- ✅ Rendu 3D premium
- ✅ Physique de visée avancée
- ✅ UX claire et intuitive
- ✅ Performance optimisée

**Enjoy! 🎱**



## Validation après intégration

Les contrôles TypeScript, i18n, tests et build sont bloquants. Le script ne crée aucun commit et ne déploie rien. Les trajectoires affichées sont indicatives, avec au plus huit segments avant le premier contact ou une poche ; elles ne remplacent pas la simulation serveur. Le serveur et les opérations financières restent inchangés. La qualité réduit la résolution et les ombres sur les appareils lents, sans garantir 60 ou 30 images/s.
