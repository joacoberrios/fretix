import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'router/app_router.dart';
import 'services/auth_service.dart';
import 'services/fcm_service.dart';
import 'theme/fretix_theme.dart';

// ─── NavigatorKey global ──────────────────────────────────────────────────────
// Declarado aquí (top-level) para que sea accesible desde FcmService y
// FretixAuthService sin necesidad de pasar BuildContext entre capas.
final GlobalKey<NavigatorState> fretixNavigatorKey = GlobalKey<NavigatorState>();

// Handler de FCM para mensajes recibidos con la app completamente cerrada.
// Debe ser una función top-level (no método de clase) por restricción de Flutter.
@pragma('vm:entry-point')
Future<void> _fcmBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('[FCM Background] data: ${message.data}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Conectar al emulador si estamos en debug (ver FretixAuthService para Auth)
  await FretixAuthService.instance.initEmulatorIfDebug();

  // Configurar handler de background antes de runApp
  FirebaseMessaging.onBackgroundMessage(_fcmBackgroundHandler);

  // Inicializar FCM (permisos + token + handlers de foreground)
  await FcmService.instance.init();

  runApp(const FretixApp());
}

class FretixApp extends StatelessWidget {
  const FretixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:         'Fretix',
      debugShowCheckedModeBanner: false,
      navigatorKey:  fretixNavigatorKey,     // ← invariante #1
      theme:         FretixTheme.dark(),
      onGenerateRoute: AppRouter.onGenerateRoute,
      initialRoute:  AppRouter.splash,
    );
  }
}
