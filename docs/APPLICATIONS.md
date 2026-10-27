# Applications Casino & Titles

Les applications utilisent le code du jeu existant et le même Supabase. Aucun compte, solde, coffre, titre, permission ou règle économique n’est recréé. Internet reste nécessaire pour jouer. Le site fonctionne séparément comme avant.

## Fichiers et technologies

- Windows : Electron 45, installateur NSIS, `desktop/main.cjs`, `electron-builder.yml`.
- Android / iOS : Capacitor 8, projets `android/` et `ios/`.
- Interface commune : compilation Vite dans `dist-native/`. La compilation web continue dans `dist/`.
- Icône : `assets/app-icon.svg`. Régénération : `npm run app:icons`.
- Identifiant Android/iOS : `com.casinotitles.app`. Ne pas le changer après distribution.

## Préparation commune

Dans un terminal ouvert dans ce dossier :

```powershell
npm ci
npm run app:doctor
```

Utiliser Node.js 22 ou plus récent (24 recommandé). Le fichier `.env.local` doit contenir les **deux valeurs publiques du projet Supabase existant** : `VITE_SUPABASE_URL` et `VITE_SUPABASE_ANON_KEY`. Reprendre celles de ce projet ; ne jamais utiliser de clé `service_role`, de mot de passe de base ou de secret administrateur. Ne pas committer `.env.local`.

Les migrations et fonctions Supabase ne doivent pas être réinstallées pour fabriquer une application.

## Windows : générer et installer le .exe

Sur Windows 10/11 64 bits :

```powershell
npm run app:windows
```

Résultat : `release/windows/Casino-Titles-Setup-0.4.0.exe`. Double-cliquer, choisir le dossier et terminer l’assistant. Les raccourcis ouvrent directement le jeu. L’installation peut être faite sans compte administrateur. Désinstallation dans Paramètres Windows > Applications. Pour lancer sans installer : `release/windows/win-unpacked/Casino & Titles.exe`.

Le fichier généré localement n’a pas de certificat de signature commerciale. Windows peut donc afficher SmartScreen. Pour une distribution publique signée, configurer le certificat Electron Builder via `CSC_LINK` et `CSC_KEY_PASSWORD`, hors du dépôt. Aucune signature n’est simulée.

Développement : `npm run app:desktop`. Le plein écran natif est disponible via les contrôles du jeu ; les liens HTTPS externes s’ouvrent dans le navigateur système. Le moteur est isolé (sandbox, aucun accès Node depuis le jeu).

## Android : générer et installer le .apk

Installer Android Studio et son SDK Android 36 / Build Tools 36.0.0, ainsi qu’un **JDK 21**. Définir `JAVA_HOME` vers le JDK et `ANDROID_HOME` vers le SDK ; ajouter `platform-tools` au PATH. Android Studio permet de le faire dans SDK Manager. Le script reconnaît aussi les outils portables déjà présents dans `.native-tools/` sur ce PC (non inclus dans Git).

```powershell
npm run app:android
```

Résultat : `release/android/Casino-Titles-debug.apk`. C’est un vrai APK installable, signé avec la clé de développement Android locale. Android 7.0 minimum, connexion Internet requise.

Copier l’APK sur le téléphone, autoriser l’installation pour l’application qui ouvre ce fichier, puis l’ouvrir. Ou activer le débogage USB et exécuter :

```powershell
adb install -r release/android/Casino-Titles-debug.apk
```

Pour une version de diffusion signée :

```powershell
npm run build:native
npx cap sync android
npx cap open android
```

Dans Android Studio : Build > Generate Signed App Bundle or APK > APK. Créer ou sélectionner un keystore privé, choisir release. Conserver cette clé et ses mots de passe en sauvegarde sécurisée : elle est nécessaire pour toutes les mises à jour. Ne pas les ajouter à Git. Pour Google Play, générer un AAB dans le même assistant. Une version release signée avec une autre clé ne peut pas remplacer l’APK de développement sans désinstallation : convertir d’abord tout compte invité et éviter de perdre sa session locale.

## iPhone : générer l’IPA sur un Mac

La compilation et la signature iOS ne sont pas possibles sur Windows. Le projet Xcode est déjà généré. Utiliser un Mac, **Xcode 26 ou plus récent**, Node 22+, un compte Apple et les profils/certificats adaptés au mode de distribution. Le projet utilise Swift Package Manager, pas CocoaPods.

1. Cloner ce dépôt sur le Mac et créer `.env.local` avec les mêmes valeurs publiques Supabase.
2. Exécuter :

```bash
npm ci
npm run build:native
npx cap sync ios
npx cap open ios
```

3. Dans Xcode, sélectionner App > Signing & Capabilities, son équipe Apple, puis activer Automatically manage signing. Garder `com.casinotitles.app` ou, si indisponible dans son équipe, attribuer son identifiant avant la première distribution.
4. Connecter l’iPhone, sélectionner l’appareil puis Run pour installer en développement.
5. Pour exporter un IPA : Product > Archive > Distribute App. Choisir le mode autorisé par son compte (développement / appareils enregistrés / TestFlight ou App Store). Un IPA signé ne s’installe que selon ce mode ; ce n’est pas un fichier universel installable sur tous les iPhone.

Un script est également prêt :

```bash
export APPLE_TEAM_ID=VOTRE_EQUIPE
export IOS_EXPORT_METHOD=debugging
npm run app:ios
```

Sortie : `release/ios/`, archive Xcode et IPA si la signature/provisioning réussit. Pour TestFlight/App Store, exporter avec Xcode ou `IOS_EXPORT_METHOD=app-store-connect` selon la version de Xcode. Ouvrir d’abord Xcode, accepter sa licence et connecter le compte Apple. Les profils de distribution et l’éligibilité Apple restent nécessaires. Le script ne crée ni compte Apple ni certificat. Le projet iOS n’est pas compilé ni testé sur iPhone depuis ce PC Windows.

## Connexion, comptes invités et courriels

Se connecter avec les mêmes identifiants que sur le site : toutes les données sont côté Supabase. Les sessions sont propres à chaque installation ; un invité du navigateur n’est pas automatiquement le même invité dans une application. **Transformer son compte invité en compte avec mail et mot de passe sur l’appareil d’origine avant de changer d’appareil.** Ne pas désinstaller l’application d’un invité avant cette conversion.

Les confirmations de mail et réinitialisations de mot de passe continuent à ouvrir le site officiel dans le navigateur, avec son contrôle d’accès actuel. Une fois le mail confirmé ou le mot de passe changé, revenir à l’application et se connecter. Les liens ne redirigent pas vers une fausse adresse locale de WebView. Le site actuellement privé conserve sa restriction d’accès : un lien email ouvert dans le navigateur reste soumis à celle-ci. Aucun paramètre global Supabase d’authentification ou d’autorisation n’est modifié par l’empaquetage.

## Reçus, affichage et données

Sur mobile, le téléchargement d’un reçu PDF ouvre la feuille système pour enregistrer/partager le fichier. Les boutons, jeux et langues FR/EN sont ceux du site. La zone sûre des écrans à encoche est prise en compte. Sur Android, Retour utilise l’historique interne ; à la racine il ne ferme pas brutalement le jeu. Les crédits et transactions restent validés par le serveur ; un installateur ne contient aucune autorisation administrateur.

## Après une modification du site

```powershell
git pull
npm ci
npm test
npm run build
npm run app:windows
npm run app:android
```

Sur le Mac, refaire `npm run app:ios`. Le contenu serveur (soldes, annonces, titres attribués) se met à jour en ligne ; une modification du code de l’interface nécessite de reconstruire et redistribuer les applications. À partir de la version 0.4.0, Windows télécharge les nouvelles versions en arrière-plan et les installe à la fermeture de l’application. Android affiche une proposition de mise à jour avec installation confirmée par le système.

Avant une diffusion suivante, augmenter `package.json` version, Android `versionCode`/`versionName` et iOS `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` dans Xcode. Garder les identifiants et clés de signature pour installer par-dessus l’ancienne version et conserver les sessions.

La publication du site conserve sa commande `npm run build` et son dossier `dist`. Ne pas publier `release/`, les clés, `.native-tools/` ou `.env.local` dans l’hébergement web.

## Références officielles

- [Environnement Capacitor et outils requis](https://capacitorjs.com/docs/getting-started/environment-setup)
- [Workflow Capacitor](https://capacitorjs.com/docs/basics/workflow)
- [Sécurité Electron](https://www.electronjs.org/docs/latest/tutorial/security)
- [Installateur NSIS](https://www.electron.build/nsis.html)

## Vérifications effectuées sur ce PC

- 341 tests fonctionnels réussis, plus les tests du mécanisme de mise à jour, dont les tests de roulement, de traduction des téléchargements et de protection des applications.
- Compilation TypeScript, contrôle FR/EN et compilation web réussis.
- Installateur NSIS Windows x64 produit ; lancement de l’interface locale, accueil et menu vérifiés dans Electron. Aucun compte de production modifié pour tester.
- APK Android compilé avec succès, signature APK v2 vérifiée avec apksigner ; Android API 24 minimum / cible 36.
- Synchronisation du projet iOS réussie sous Windows ; compilation et tests iPhone à effectuer sur Mac.
- Aucun test sur téléphone physique effectué ici. Les parcours connectés avec email, PDF et rotation tactile restent à valider sur les appareils cibles avant diffusion publique.
- Empreintes des installateurs : `release/SHA256SUMS.txt`. Les installateurs sont conservés localement et exclus de Git.

## Publier les installateurs sur le site

La page `/download` et le bloc de l’accueil utilisent les fichiers publics de la release GitHub `v0.4.0`. Les installateurs ne sont pas placés dans `dist` ni dans Supabase. Pour une prochaine version : augmenter les versions natives et les liens de `src/components/AppDownloads.tsx`, reconstruire les deux applications, régénérer `release/SHA256SUMS.txt`, committer et pousser la source testée, puis lancer `npm run app:publish` avec un accès GitHub d’édition sur ce dépôt (Git Credential Manager déjà connecté ou variable GITHUB_TOKEN). Le script crée une release brouillon, téléverse les fichiers et la publie seulement une fois tous les fichiers disponibles ; un fichier différent ne peut pas écraser une version distribuée. Publier ensuite le site avec les liens correspondants. Publier aussi latest.yml et le fichier EXE.blockmap : le script app:publish le fait automatiquement. Ces métadonnées activent les mises à jour Windows. Android découvre le nouvel APK via la release GitHub publique.

## Activation des mises à jour automatiques

Installer une dernière fois la version 0.4.0 par-dessus 0.2.0 ou 0.3.0 : ces anciennes versions ne contiennent pas encore le mécanisme de mise à jour. Ensuite, Windows vérifie au démarrage puis toutes les six heures, télécharge les versions stables supérieures et installe à la fermeture. Aucun redémarrage forcé pendant une partie. Le programme vérifie les empreintes SHA-512 fournies par electron-updater ; les releases viennent exclusivement de ce dépôt GitHub. Android vérifie au démarrage et au retour dans l’application (au plus une vérification automatique toutes les six heures), propose le nouvel APK, puis Android demande l’autorisation d’installation. Aucun installateur ne supprime les données utilisateur. Les invités doivent toujours convertir leur compte avant de changer d’appareil ou de désinstaller. Le panneau Paramètres > Application et mises à jour permet une vérification manuelle. Une future mise à jour réellement installée ne peut être testée qu’avec une version supérieure publiée ; aucune fausse release n’est créée pour le test.
