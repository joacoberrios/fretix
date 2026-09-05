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
        return _fadeRoute(const HomeClienteScreen(), settings);

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
// onGenerateRoute es síncrono; el guard usa FutureBuilder igual que _AdminGuard.
// Roles transportista: 'chofer' (independiente) y 'empresaTransporteMaestro'.
// No usa custom claims porque onboarding.js no llama setCustomUserClaims para
// estos roles — la única fuente de verdad es el campo onboardingRole en Firestore.

class _ChoferGuard extends StatelessWidget {
  const _ChoferGuard();

  static const _rolesTransportista = {'chofer_independiente', 'empresa_transporte_maestro'};

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const _AccesoDenegadoScreen();

    // Lee perfil, vehículo y viaje activo en paralelo para decidir qué pantalla mostrar.
    // empresa_transporte_maestro sin vehículo registrado también pasa por
    // SubirTarjetaVerdeScreen en esta versión (Tarea 11). El soporte de flota
    // múltiple queda documentado como Tarea 11b (ver VALIDACION_LOG.md).
    return FutureBuilder<List<Object>>(
      future: Future.wait([
        FirebaseFirestore.instance.collection('users').doc(uid).get(),
        FirebaseFirestore.instance
            .collection('vehiculos')
            .where('choferUid', isEqualTo: uid)
            .limit(1)
            .get(),
        FirebaseFirestore.instance
            .collection('viajes')
            .where('choferUid', isEqualTo: uid)
            .where('estado', whereIn: ['aceptado', 'en_curso'])
            .limit(1)
            .get(),
      ]),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D0D0D),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFFD4A373)),
            ),
          );
        }
        // Error de red / permisos Firestore — causa técnica, no de rol.
        // Mostrar pantalla de reintento distinta a "Acceso denegado" para
        // no confundir un fallo temporal con una restricción de autorización.
        if (snap.hasError) {
          return _ErrorCargaScreen(onReintentar: () {
            Navigator.pushNamedAndRemoveUntil(
                context, AppRouter.homeChofer, (_) => false);
          });
        }
        final results = snap.data;
        // snap.data solo puede ser null aquí si la plataforma no completó
        // el snapshot correctamente — tratar como error transitorio.
        if (results == null) {
          return _ErrorCargaScreen(onReintentar: () {
            Navigator.pushNamedAndRemoveUntil(
                context, AppRouter.homeChofer, (_) => false);
          });
        }

        final userDoc       = results[0] as DocumentSnapshot;
        final vehiculoSnap  = results[1] as QuerySnapshot;
        final viajeActivo   = results[2] as QuerySnapshot;
        final data = userDoc.data() as Map<String, dynamic>?;
        final rol  = data?['onboardingRole'] as String?;

        // Rol no reconocido → acceso real denegado (no es un fallo técnico).
        if (rol == null || !_rolesTransportista.contains(rol)) {
          return const _AccesoDenegadoScreen();
        }
        // Sin vehículo registrado → subida obligatoria antes de operar
        if (vehiculoSnap.docs.isEmpty) return const SubirTarjetaVerdeScreen();
        // Viaje activo (aceptado o en_curso) → redirigir directamente a ViajeActivoScreen
        if (viajeActivo.docs.isNotEmpty) {
          final viajeId = viajeActivo.docs.first.id;
          return ViajeActivoScreen(viajeId: viajeId);
        }
        return const HomeChoferScreen();
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
