Kavelynt Apex — Flutter + plateformes natives

Arborescence fournie :
- lib/main.dart : code Dart de l'application Flutter
- pubspec.yaml : dépendances Flutter
- android/ : hôte Android natif Gradle + Kotlin + manifeste + ressources
- ios/ : hôte iOS natif Swift + Xcode project + Podfile + storyboards
- functions/ : fonctions Firebase
- .github/workflows/build-apk.yml : compilation APK Android

Important :
- GoogleService-Info.plist doit être téléchargé depuis Firebase et placé dans ios/Runner/.
- Le projet n'a pas été compilé dans cet environnement. Le premier workflow GitHub doit vérifier la compatibilité réelle des fichiers et dépendances.
- Pour compiler iOS, un environnement macOS avec Xcode est nécessaire.
