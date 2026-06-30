import 'package:flutter/material.dart';

import '../screens/auth/otp_screen.dart';
import '../screens/auth/phone_input_screen.dart';
import '../screens/onboarding/role_selection_screen.dart';
// import '../screens/home/home_screen.dart';

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
  static const tripTracking  = '/cliente/tracking';

  // ── Compartidas
  static const rating        = '/rating';

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

      // ── Rutas pendientes de implementación ────────────────────────────
      // case home:
      // case homeCliente:
      // case homeChofer:
      //   return _fadeRoute(const HomeScreen(), settings);

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
