import 'package:firebase_core/firebase_core.dart';

const _apiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');
const _appId = String.fromEnvironment('FIREBASE_WEB_APP_ID');
const _messagingSenderId = String.fromEnvironment('FIREBASE_WEB_MESSAGING_SENDER_ID');
const _projectId = String.fromEnvironment('FIREBASE_WEB_PROJECT_ID', defaultValue: 'studymind-4f791');
const _authDomain = String.fromEnvironment('FIREBASE_WEB_AUTH_DOMAIN');
const _storageBucket = String.fromEnvironment('FIREBASE_WEB_STORAGE_BUCKET');
const _measurementId = String.fromEnvironment('FIREBASE_WEB_MEASUREMENT_ID');

bool get hasFirebaseWebConfig => _apiKey.isNotEmpty && _appId.isNotEmpty && _messagingSenderId.isNotEmpty && _projectId.isNotEmpty;

FirebaseOptions? get firebaseWebOptions => hasFirebaseWebConfig ? FirebaseOptions(
  apiKey: _apiKey,
  appId: _appId,
  messagingSenderId: _messagingSenderId,
  projectId: _projectId,
  authDomain: _authDomain.isEmpty ? null : _authDomain,
  storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
  measurementId: _measurementId.isEmpty ? null : _measurementId,
) : null;
