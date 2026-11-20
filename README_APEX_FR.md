# StudyMind Apex

Projet Flutter StudyMind Apex. Identifiant Android/iOS : `com.studymind.app`.

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
Le vrai `GoogleService-Info.plist` de l’application Firebase iOS n’est pas inclus dans cette archive. Après génération du dossier iOS, ajoute-le dans `ios/Runner/GoogleService-Info.plist`. Le Bundle ID doit être `com.studymind.app`. Ne publie pas ce fichier dans un dépôt public.

## Cloudflare Worker
Le Worker utilise les secrets `FIREBASE_WEB_API_KEY` et `GEMINI_API_KEY`, ainsi que le binding de limite `CHAT_USER_LIMITER`. Ne mets jamais leurs valeurs dans le dépôt.
