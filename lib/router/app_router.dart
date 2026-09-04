import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/cotizacion_args.dart';
import '../screens/admin/admin_tarifas_screen.dart';
import '../screens/admin/admin_validaciones_screen.dart';
import '../screens/auth/otp_screen.dart';
import '../screens/auth/phone_input_screen.dart';
import '../screens/customer/buscando_chofer_screen.dart';
import '../screens/customer/cotizacion_screen.dart';
import '../screens/customer/search_location_screen.dart';
import '../screens/home/home_cliente_screen.dart';
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
  static const ofertaViaje   = '/chofer/oferta';
  static const tripControl   = '/chofer/trip_control';

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

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {

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

    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D0D0D),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFFD4A373)),
            ),
          );
        }
        final data = snap.data?.data() as Map<String, dynamic>?;
        final rol  = data?['onboardingRole'] as String?;
        if (rol != null && _rolesTransportista.contains(rol)) {
          return const HomeChoferScreen();
        }
        return const _AccesoDenegadoScreen();
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
