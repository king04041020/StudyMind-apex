# Kavelynt Apex

Projet Flutter Kavelynt Apex. Identifiant Android/iOS : `com.studymind.app`.

## Structure
- `lib/main.dart` : application Flutter
- `pubspec.yaml` : dépendances Flutter
- `android/app/google-services.json` : configuration Firebase Android
- `ios/` : plateforme iOS générée par Flutter dans le workflow
- `worker.js` et `wrangler.jsonc` : assistant IA Cloudflare Worker
- `functions/` : fonctions Firebase
- `firestore.rules` : règles Firestore
- `.github/workflows/build-apk.yml` : compilation Android et iOS

## Compilation
GitHub Actions génère les fichiers natifs avec `flutter create`, installe les dépendances, puis compile l’APK Android. Le build iOS est non signé et ne constitue pas une application publiable telle quelle.

## Firebase iOS
Le vrai `GoogleService-Info.plist` de l’application Firebase iOS n’est pas inclus dans cette archive. Après génération du dossier iOS, ajoute-le dans `ios/Runner/GoogleService-Info.plist`. Le Bundle ID Firebase historique reste `com.studymind.app` pour préserver la connexion existante. Ne publie pas ce fichier dans un dépôt public.

## Cloudflare Worker
Le Worker utilise les secrets `FIREBASE_WEB_API_KEY` et `GEMINI_API_KEY`, ainsi que le binding de limite `CHAT_USER_LIMITER`. Ne mets jamais leurs valeurs dans le dépôt.


## Version Web installable (PWA)

La version Web est compilée via `.github/workflows/build-web.yml` et publiée sur GitHub Pages sous le chemin `/StudyMind-apex/`. Sur iPhone, ouvre le site dans Safari puis utilise **Partager → Sur l’écran d’accueil** pour créer son raccourci en mode application.

**Attention :** l'initialisation Firebase Web nécessite une application Firebase de type Web et ses paramètres `FirebaseOptions`. Le code Firebase natif actuel ne contient pas encore cette configuration Web. Le build Web valide le code Flutter, mais la connexion/les fonctionnalités cloud Web ne seront pleinement utilisables qu'après ajout de cette configuration. Certaines fonctions (photo/caméra, accès fichiers, PDF) doivent également être testées sur Safari iOS.


## Configuration Firebase Web (nécessaire pour la connexion)

La compilation Web utilise des variables de configuration GitHub Actions, afin de ne pas coder les paramètres Web directement dans le dépôt. Dans Firebase Console, ajoute une application Web au projet `studymind-4f791`, récupère sa configuration Firebase Web, puis ajoute les secrets suivants dans **Settings → Secrets and variables → Actions → New repository secret** :

- `FIREBASE_WEB_API_KEY`
- `FIREBASE_WEB_APP_ID`
- `FIREBASE_WEB_MESSAGING_SENDER_ID`
- `FIREBASE_WEB_AUTH_DOMAIN` (facultatif)
- `FIREBASE_WEB_STORAGE_BUCKET` (facultatif)
- `FIREBASE_WEB_MEASUREMENT_ID` (facultatif)

Les valeurs doivent venir de la configuration de l'application Firebase Web enregistrée pour ce projet. Sans les trois secrets obligatoires, le site Web se compile et affiche une page de configuration plutôt que de lancer une connexion Firebase cassée.

Pour GitHub Pages, vérifier dans **Settings → Pages** que la source est **GitHub Actions**. La publication est ensuite automatisée par `build-web.yml`.
