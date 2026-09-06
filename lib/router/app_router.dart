import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'role_routing.dart';

import '../models/cotizacion_args.dart';
import '../screens/admin/admin_tarifas_screen.dart';
import '../screens/admin/admin_validaciones_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/auth/phone_input_screen.dart';
import '../screens/customer/buscando_chofer_screen.dart';
import '../screens/customer/cotizacion_screen.dart';
import '../screens/customer/search_location_screen.dart';
import '../screens/home/home_cliente_screen.dart';
import '../screens/chofer/subir_tarjeta_verde_screen.dart';
import '../screens/chofer/viaje_activo_screen.dart';
import '../screens/home/home_chofer_screen.dart';
import '../screens/onboarding/role_selection_screen.dart';

/// Centraliza todas las rutas nombradas de la app.
/// Se usa onGenerateRoute (no routes: {}) para poder pasar argumentos tipados.
abstract class AppRouter {
  static const splash        = '/';
  static const login         = '/login';
  static const otp           = '/otp';
  static const roleSelection = '/onboarding/role';
  static const home          = '/home';

  // Rutas de home según rol — resueltas por FretixAuthService.ejecutarOnboardingBackend
  static const homeCliente = '/home/cliente';
  static const homeChofer  = '/home/chofer';

  // ── Rutas del chofer
  static const ofertaViaje        = '/chofer/oferta';
  static const tripControl        = '/chofer/trip_control';
  static const subirTarjetaVerde  = '/chofer/subir-tarjeta-verde';
  static const viajeActivo        = '/chofer/viaje_activo';

  // ── Rutas del cliente
  static const searchLocation = '/cliente/buscar';
  static const cotizacion     = '/cliente/cotizar';
  static const buscandoChofer = '/cliente/buscando';
  static const tripTracking   = '/cliente/tracking';

  // ── Compartidas
  static const rating        = '/rating';

  // ── Admin (Módulo 5)
  static const adminTarifas        = '/admin/tarifas';
  static const adminValidaciones   = '/admin/validaciones';

  // ── Web / corporativo
  static const portalCliente    = '/web/cliente';
  static const portalTransporte = '/web/transporte';

  /// Devuelve la ruta de home correspondiente al onboardingRole guardado en
  /// Firestore. Fuente única de verdad: usada por _SplashGate y OtpScreen.
  /// La lógica vive en role_routing.dart para permitir tests VM.
  static String homeForRole(String? onboardingRole) =>
      resolveHomeForRole(onboardingRole);

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {

      case splash:
        return _fadeRoute(const _SplashGate(), settings);

      case login:
        return _fadeRoute(const PhoneInputScreen(), settings);

      case otp:
        return _fadeRoute(const OtpScreen(), settings);

      case roleSelection:
        return _fadeRoute(const RoleSelectionScreen(), settings);

      case homeCliente:
        return _fadeRoute(const _ClienteGuard(), settings);

      case homeChofer:
        return _fadeRoute(const _ChoferGuard(), settings);

      case subirTarjetaVerde:
        return _fadeRoute(const SubirTarjetaVerdeScreen(), settings);

      case viajeActivo:
        final viajeId = settings.arguments as String?;
        if (viajeId == null) {
          return _fadeRoute(const HomeChoferScreen(), settings);
        }
        return _fadeRoute(ViajeActivoScreen(viajeId: viajeId), settings);

      case searchLocation:
        return _fadeRoute(const SearchLocationScreen(), settings);

      case cotizacion:
        final args = settings.arguments as CotizacionArgs?;
        return _fadeRoute(CotizacionScreen(args: args), settings);

      case buscandoChofer:
        final viajeId = settings.arguments as String?;
        return _fadeRoute(BuscandoChoferScreen(viajeId: viajeId), settings);

      case adminTarifas:
        return _fadeRoute(const _AdminGuard(), settings);

      case adminValidaciones:
        return _fadeRoute(
          const _AdminGuard(child: AdminValidacionesScreen()),
          settings,
        );


      default:
        // Ruta no encontrada — pantalla de error temporal
        return MaterialPageRoute(
          settings: settings,
          builder:  (_) => Scaffold(
            backgroundColor: const Color(0xFF0D0D0D),
            body: Center(
              child: Text(
                'Ruta no encontrada: ${settings.name}',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        );
    }
  }

  /// Transición de fade personalizada (en lugar del slide default de Material)
  static PageRouteBuilder _fadeRoute(Widget page, RouteSettings settings) {
    return PageRouteBuilder(
      settings:        settings,
      pageBuilder:     (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: animation,
        child:   child,
      ),
      transitionDuration: const Duration(milliseconds: 250),
    );
  }
}

// ─── Splash / auth gate ───────────────────────────────────────────────────────
//
// Primera pantalla que ve la app al arrancar (initialRoute: AppRouter.splash).
// Espera el primer evento de authStateChanges() para que el SDK de Firebase Auth
// rehidrate el token desde IndexedDB (web). Sin este gate la app siempre arrancaba
// en /login aunque hubiera una sesión activa — BUG-SESION-01 (ver VALIDACION_LOG.md).

class _SplashGate extends StatefulWidget {
  const _SplashGate();
  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final user = await FirebaseAuth.instance.authStateChanges().first;
    if (!mounted) return;

    if (user == null) {
      Navigator.pushReplacementNamed(context, AppRouter.login);
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final role = doc.data()?['onboardingRole'] as String?;
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, AppRouter.homeForRole(role));
    } catch (_) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, AppRouter.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0D0D0D),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFFD4A373)),
      ),
    );
  }
}

// ─── Admin route guard ────────────────────────────────────────────────────────
//
// onGenerateRoute es síncrono, no puede await. El guard verifica el custom claim
// 'role' del token JWT del usuario actual (mismo campo que usa isAdmin() en
// firestore.rules). Si el claim no está presente o no es 'admin', muestra
// _AccesoDenegadoScreen sin llegar a construir AdminTarifasScreen.

class _AdminGuard extends StatelessWidget {
  const _AdminGuard({this.child = const AdminTarifasScreen()});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IdTokenResult?>(
      future: FirebaseAuth.instance.currentUser?.getIdTokenResult(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D0D0D),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFFD4A373)),
            ),
          );
        }
        final role = snap.data?.claims?['role'] as String?;
        if (role == 'admin') return child;
        return const _AccesoDenegadoScreen();
      },
    );
  }
}

// ─── Chofer route guard ───────────────────────────────────────────────────────
//
// Verifica onboardingRole en /users/{uid} antes de renderizar HomeChoferScreen.
// Diseño en dos capas:
//   1. FutureBuilder (StatefulWidget, future cacheado en initState): rol y vehículo
//      se resuelven una sola vez — no cambian durante la sesión.
//   2. StreamBuilder anidado: viaje activo escucha en tiempo real, de modo que
//      cuando el chofer acepta un viaje la UI reacciona sin necesitar F5.
// Roles transportista: 'chofer_independiente' y 'empresa_transporte_maestro'.
// No usa custom claims porque onboarding.js no llama setCustomUserClaims para
// estos roles — la única fuente de verdad es onboardingRole en Firestore.

class _ChoferGuard extends StatefulWidget {
  const _ChoferGuard();

  @override
  State<_ChoferGuard> createState() => _ChoferGuardState();
}

class _ChoferGuardState extends State<_ChoferGuard> {
  static const _rolesTransportista = {'chofer_independiente', 'empresa_transporte_maestro'};

  static const _spinner = Scaffold(
    backgroundColor: Color(0xFF0D0D0D),
    body: Center(child: CircularProgressIndicator(color: Color(0xFFD4A373))),
  );

  String? _uid;
  Future<List<Object>>? _profileFuture;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    _uid = uid;
    if (uid != null) {
      _profileFuture = Future.wait([
        FirebaseFirestore.instance.collection('users').doc(uid).get(),
        FirebaseFirestore.instance
            .collection('vehiculos')
            .where('choferUid', isEqualTo: uid)
            .limit(1)
            .get(),
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) return const _AccesoDenegadoScreen();

    return FutureBuilder<List<Object>>(
      future: _profileFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return _spinner;

        if (snap.hasError || snap.data == null) {
          return _ErrorCargaScreen(onReintentar: () {
            Navigator.pushNamedAndRemoveUntil(
                context, AppRouter.homeChofer, (_) => false);
          });
        }

        final results      = snap.data!;
        final userDoc      = results[0] as DocumentSnapshot;
        final vehiculoSnap = results[1] as QuerySnapshot;
        final data = userDoc.data() as Map<String, dynamic>?;
        final rol  = data?['onboardingRole'] as String?;

        if (rol == null || !_rolesTransportista.contains(rol)) {
          return const _AccesoDenegadoScreen();
        }
        if (vehiculoSnap.docs.isEmpty) return const SubirTarjetaVerdeScreen();

        // Rol + vehículo OK — escuchar viaje activo en tiempo real.
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('viajes')
              .where('choferUid', isEqualTo: uid)
              .where('estado', whereIn: ['aceptado', 'en_curso', 'en_transito'])
              .limit(1)
              .snapshots(),
          builder: (context, viajeSnap) {
            if (viajeSnap.connectionState == ConnectionState.waiting) {
              return _spinner;
            }
            if (viajeSnap.hasError) {
              return _ErrorCargaScreen(onReintentar: () {
                Navigator.pushNamedAndRemoveUntil(
                    context, AppRouter.homeChofer, (_) => false);
              });
            }
            final docs = viajeSnap.data?.docs;
            if (docs != null && docs.isNotEmpty) {
              return ViajeActivoScreen(viajeId: docs.first.id);
            }
            return const HomeChoferScreen();
          },
        );
      },
    );
  }
}

// ─── Error de carga (red / permisos) — distinto a acceso denegado ────────────
//
// Se muestra cuando el FutureBuilder del guard falla por razón técnica
// (Firestore permission-denied temporal, sin conectividad, etc.).
// Intencionalmente diferente a _AccesoDenegadoScreen para no confundir
// un fallo de infraestructura con una restricción de autorización de rol.

class _ErrorCargaScreen extends StatelessWidget {
  const _ErrorCargaScreen({required this.onReintentar});
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, color: Colors.white30, size: 48),
              const SizedBox(height: 16),
              const Text(
                'No pudimos cargar tu perfil',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Verificá tu conexión e intentá de nuevo.',
                style: TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: onReintentar,
                child: const Text(
                  'Reintentar',
                  style: TextStyle(color: Color(0xFFD4A373), fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Cliente route guard ──────────────────────────────────────────────────────
//
// Equivalente simétrico de _ChoferGuard para el cliente. Escucha en tiempo real
// si el cliente tiene un viaje activo (pending, aceptado, en_curso, en_transito).
// Si lo hay, monta BuscandoChoferScreen directamente — sin F5. Si no hay, monta
// HomeClienteScreen normal. Ante error de red, muestra _ErrorCargaScreen igual
// que _ChoferGuard (no asume "sin viaje" frente a un fallo de conectividad).

class _ClienteGuard extends StatefulWidget {
  const _ClienteGuard();

  @override
  State<_ClienteGuard> createState() => _ClienteGuardState();
}

class _ClienteGuardState extends State<_ClienteGuard> {
  static const _spinner = Scaffold(
    backgroundColor: Color(0xFF0D0D0D),
    body: Center(child: CircularProgressIndicator(color: Color(0xFFD4A373))),
  );

  String? _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) return const HomeClienteScreen();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('viajes')
          .where('clienteUid', isEqualTo: uid)
          .where('estado', whereIn: ['pending', 'aceptado', 'en_curso', 'en_transito'])
          .limit(1)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return _spinner;
        if (snap.hasError) {
          return _ErrorCargaScreen(onReintentar: () {
            Navigator.pushNamedAndRemoveUntil(
                context, AppRouter.homeCliente, (_) => false);
          });
        }
        final docs = snap.data?.docs;
        if (docs != null && docs.isNotEmpty) {
          return BuscandoChoferScreen(viajeId: docs.first.id);
        }
        return const HomeClienteScreen();
      },
    );
  }
}

class _AccesoDenegadoScreen extends StatelessWidget {
  const _AccesoDenegadoScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: Colors.white30, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Acceso denegado',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Esta sección es solo para administradores.',
                style: TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Volver',
                  style: TextStyle(color: Color(0xFFD4A373)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
