// lib/firebase_options.dart
// Generado para el proyecto fretix-dev-jb.
// Valores de emulador — no contienen claves de producción.
// Para producción: regenerar con `flutterfire configure`.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions no están configuradas para macOS.',
        );
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions no están configuradas para Windows.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions no están configuradas para Linux.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions no soporta esta plataforma.',
        );
    }
  }

  // Web — usado en Codespaces con emuladores.
  // apiKey puede ser cualquier string no vacío cuando se usan emuladores.
  static const FirebaseOptions web = FirebaseOptions(
    apiKey:            'AIzaSyEmulatorPlaceholderFretixDevJb',
    appId:             '1:000000000000:web:fretixdevjb00000000000',
    messagingSenderId: '000000000000',
    projectId:         'fretix-dev-jb',
    authDomain:        'fretix-dev-jb.firebaseapp.com',
    storageBucket:     'fretix-dev-jb.appspot.com',
  );

  // Android — usado con emulador AVD o dispositivo físico.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey:            'AIzaSyEmulatorPlaceholderFretixDevJb',
    appId:             '1:000000000000:android:fretixdevjb00000000000',
    messagingSenderId: '000000000000',
    projectId:         'fretix-dev-jb',
    storageBucket:     'fretix-dev-jb.appspot.com',
  );

  // iOS — placeholder para compilaciones futuras.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey:            'AIzaSyEmulatorPlaceholderFretixDevJb',
    appId:             '1:000000000000:ios:fretixdevjb00000000000',
    messagingSenderId: '000000000000',
    projectId:         'fretix-dev-jb',
    storageBucket:     'fretix-dev-jb.appspot.com',
    iosBundleId:       'com.fretix.app',
  );
}
