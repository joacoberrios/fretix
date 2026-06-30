import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../main.dart';               // fretixNavigatorKey
import '../models/user_role.dart';   // FretixUserRole
import '../router/app_router.dart';  // AppRouter.home / AppRouter.login

// ─────────────────────────────────────────────────────────────────────────────
// FretixAuthService — Singleton
//
// Responsabilidades:
//   1. Conectar Firebase Auth y Cloud Functions al emulador local en debug.
//   2. Disparar el flujo OTP de Firebase Auth.
//   3. Llamar a la Cloud Function de onboarding atómico.
//   4. Navegar al home usando fretixNavigatorKey (sin BuildContext).
// ─────────────────────────────────────────────────────────────────────────────
class FretixAuthService {
  // Patrón Singleton con constructor con nombre privado
  FretixAuthService._internal();
  static final FretixAuthService instance = FretixAuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Las instancias de Functions se crean aquí con la región correcta.
  // Se reasignan en initializeEmulators() si estamos en debug.
  FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  // Expone un callable usando la instancia configurada (emulador o producción).
  // Toda la app debe usar este método — nunca FirebaseFunctions.instance directamente.
  //
  // En web+emulador: useFunctionsEmulator() genera URLs http:// que el browser bloquea
  // como Mixed Content desde la página HTTPS de Codespaces. Usamos httpsCallableFromUrl
  // con la URL HTTPS completa del túnel para evitar el bloqueo.
  HttpsCallable getCallable(String name, {Duration timeout = const Duration(seconds: 15)}) {
    return _functions.httpsCallable(
      name,
      options: HttpsCallableOptions(timeout: timeout),
    );
  }

  // Estado público
  User?         get currentUser      => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  bool          get isLoggedIn       => _auth.currentUser != null;

  // ── Invariante #2: Conexión inteligente al emulador ───────────────────────
  //
  // Llamar desde main() antes de runApp().
  // Detecta la plataforma para usar el host correcto:
  //   Android Emulator → 10.0.2.2  (redirige al localhost del host)
  //   iOS Simulator / Web → localhost
  Future<void> initializeEmulators() async {
    const useEmulator = bool.fromEnvironment('USE_EMULATOR', defaultValue: false);
    if (!useEmulator) return;

    const authPort = 9099;
    final authHost = kIsWeb ? 'localhost' : _androidHost();

    // Bug B fix: useAuthEmulator lanza "already configured" en hot-restart.
    // Aislamos solo esa llamada en try/catch — el resto del setup SIEMPRE corre.
    try {
      await _auth.useAuthEmulator(authHost, authPort);
    } catch (e) {
      debugPrint('[FretixAuth] useAuthEmulator ya configurado (hot-restart): $e');
    }

    if (kIsWeb) {
      await _auth.setSettings(appVerificationDisabledForTesting: true);
    }

    // Bug A fix: en web+Codespaces 'localhost' es la máquina del usuario, no el Codespace.
    // dev-server.js corre en el mismo origen que la app (mismo túnel, mismo puerto 3000)
    // y proxea /fretix-dev-jb/... → localhost:5001 y /google.firestore.v1.Firestore/... → localhost:8282.
    // Usamos el hostname del túnel de port 3000 para que el SDK construya URLs same-origin.
    const appTunnelHostWeb  = 'redesigned-cod-57x7rq7w9gg37x6g-3000.app.github.dev';
    final functionsHost = kIsWeb ? appTunnelHostWeb : _androidHost();
    const functionsPort = kIsWeb ? 443 : 5001;

    _functions = FirebaseFunctions.instanceFor(region: 'us-central1');
    _functions.useFunctionsEmulator(functionsHost, functionsPort);

    const firestorePort = 8282;
    final firestoreHost = kIsWeb ? appTunnelHostWeb : '${_androidHost()}:$firestorePort';
    try {
      FirebaseFirestore.instance.settings = Settings(
        host: firestoreHost,
        sslEnabled: kIsWeb,
        persistenceEnabled: false,
      );
    } catch (e) {
      debugPrint('[FretixAuth] Firestore settings ya configurado (hot-restart): $e');
    }

    debugPrint(
      '[FretixAuth] 🔧 Emuladores activos\n'
      '  Auth      → $authHost:$authPort\n'
      '  Functions → $functionsHost:$functionsPort\n'
      '  Firestore → $firestoreHost',
    );
  }

  // ── Debug-only: login directo email/password contra el emulador ───────────
  //
  // Existe porque el flujo de consola JS (window.firebase_auth.getAuth())
  // crea una instancia de Auth separada de la que usa este servicio, y esa
  // instancia hace una llamada de red a producción antes de poder conectar
  // el emulador — error reproducido 2 veces: "auth/emulator-config-failed".
  // Esta función usa _auth (el mismo objeto ya conectado al emulador por
  // initializeEmulators()), evitando el problema de raíz.
  // Solo debe llamarse si USE_EMULATOR=true — el caller es responsable de
  // ocultar el botón que la dispara en producción.
  Future<User> debugSignInEmail({
    String email    = 'test@fretix.com',
    String password = 'test1234',
  }) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return cred.user!;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        final cred = await _auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        return cred.user!;
      }
      rethrow;
    }
  }

  /// En Android el emulador AVD mapea 10.0.2.2 al localhost del host.
  /// En dispositivo físico conectado por USB no se puede usar el emulador
  /// de Auth sin un túnel — advertir en ese caso.
  static String _androidHost() {
    // defaultTargetPlatform es seguro en runtime (no compile-time como kIsWeb).
    if (defaultTargetPlatform == TargetPlatform.android) {
      return '10.0.2.2';
    }
    return 'localhost';
  }

  // ── 1. Disparo del SMS OTP ────────────────────────────────────────────────
  //
  // [phone]       Número con código de país: "+542614783921"
  // [onCodeSent]  Recibe el verificationId para el siguiente paso.
  //               Se llama por callback porque Firebase lo emite de forma
  //               asíncrona — no se puede devolver como Future.
  // [onError]     Propaga FirebaseAuthException al widget para mostrar el error.
  Future<void> verifyPhoneNumber({
    required String phone,
    required void Function(String verificationId) onCodeSent,
    void Function(FirebaseAuthException error)? onError,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phone,
      timeout:     const Duration(seconds: 60),

      // Android puede resolver el código automáticamente sin que el usuario
      // lo tipee. Lo registramos pero no navegamos aquí para mantener el
      // mismo flujo en todas las plataformas.
      verificationCompleted: (PhoneAuthCredential credential) {
        debugPrint('[FretixAuth] Auto-resolución Android disponible.');
      },

      verificationFailed: (FirebaseAuthException e) {
        debugPrint('[FretixAuth] verificationFailed: ${e.code} — ${e.message}');
        onError?.call(e);
      },

      codeSent: (String verificationId, int? resendToken) {
        debugPrint('[FretixAuth] SMS enviado. verificationId recibido.');
        onCodeSent(verificationId);
      },

      codeAutoRetrievalTimeout: (String verificationId) {
        // El timeout ocurre después de 60s. Solo loguear; el usuario
        // ya debería haber ingresado el código antes de que esto suceda.
        debugPrint('[FretixAuth] Auto-retrieval timeout.');
      },
    );
  }

  // ── 2. Validación del código OTP ──────────────────────────────────────────
  //
  // Devuelve UserCredential. El widget lee .additionalUserInfo?.isNewUser
  // para decidir si navegar al onboarding o directo al home.
  Future<UserCredential> signInWithCode({
    required String verificationId,
    required String smsCode,
  }) {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode:        smsCode,
    );
    return _auth.signInWithCredential(credential);
  }

  // ── 3. Onboarding atómico vía Cloud Function ──────────────────────────────
  //
  // Llama a `completarOnboardingFretix` en el backend y navega al home.
  // Usa fretixNavigatorKey (invariante #1) para no depender de BuildContext.
  //
  // [rol] se mapea a su .firestoreId antes de enviarlo — nunca se envía
  // el nombre del enum directamente (invariante #3).
  Future<void> ejecutarOnboardingBackend({
    required String         nombre,
    String?                 email,
    required FretixUserRole rol,
    String?                 razonSocial,
    String?                 cuit,
    String?                 nombreComercial,
  }) async {
    final callable = getCallable(
      'completarOnboardingFretix',
      timeout: const Duration(seconds: 30),
    );

    // Construir payload — solo incluir campos opcionales si tienen valor.
    final payload = <String, dynamic>{
      'displayName': nombre.trim(),
      'role':        rol.firestoreId,            // ← invariante #3
      if (email?.trim().isNotEmpty ?? false)
        'email': email!.trim(),
      if (rol.requiereDatosFiscales) ...{
        if (razonSocial?.trim().isNotEmpty ?? false)
          'razonSocial': razonSocial!.trim(),
        if (cuit?.trim().isNotEmpty ?? false)
          'cuit': cuit!.trim(),
        if (nombreComercial?.trim().isNotEmpty ?? false)
          'nombreComercial': nombreComercial!.trim(),
      },
    };

    debugPrint('[FretixAuth] Llamando completarOnboardingFretix → rol: ${rol.firestoreId}');

    try {
      final result = await callable.call(payload);
      final data   = Map<String, dynamic>.from(result.data as Map);
      debugPrint('[FretixAuth] Onboarding completado: $data');
    } catch (e) {
      const useEmulator = bool.fromEnvironment('USE_EMULATOR', defaultValue: false);
      if (useEmulator) {
        debugPrint('[FretixAuth] Function falló en emulador (ignorado): $e');
      } else {
        rethrow;
      }
    }

    // Navegar al home con GlobalKey — sin BuildContext (invariante #1)
    final targetRoute = rol.esTransportista
        ? AppRouter.homeChofer
        : AppRouter.homeCliente;

    fretixNavigatorKey.currentState
        ?.pushNamedAndRemoveUntil(targetRoute, (_) => false);
  }

  // ── 4. Actualizar token FCM ───────────────────────────────────────────────
  Future<void> actualizarFcmToken(String token) async {
    if (currentUser == null) return;
    final callable = _functions.httpsCallable('actualizarFcmTokenFretix');
    await callable.call({'fcmToken': token});
  }

  // ── 5. Cerrar sesión ──────────────────────────────────────────────────────
  Future<void> signOut() async {
    await _auth.signOut();
    fretixNavigatorKey.currentState
        ?.pushNamedAndRemoveUntil(AppRouter.login, (_) => false);
  }
}
