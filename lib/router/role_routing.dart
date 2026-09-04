// Lógica pura de routing por rol — sin imports de Flutter ni Firebase.
// Extraído para permitir tests VM (app_router.dart arrastra dart:html
// vía search_location_screen.dart y no puede importarse en tests VM).
//
// AppRouter.homeForRole() delega aquí. Si se agregan rutas nuevas,
// actualizar SOLO este archivo — el método en AppRouter se actualiza solo.

const kRouteHomeChofer    = '/home/chofer';
const kRouteHomeCliente   = '/home/cliente';
const kRouteRoleSelection = '/onboarding/role';

/// Devuelve la ruta de home correspondiente al onboardingRole de Firestore.
/// Fuente única de verdad — usada por _SplashGate y OtpScreen a través de AppRouter.
String resolveHomeForRole(String? onboardingRole) {
  switch (onboardingRole) {
    case 'chofer_independiente':
    case 'empresa_transporte_maestro':
      return kRouteHomeChofer;
    case 'cliente_particular':
    case 'cliente_empresa_maestro':
      return kRouteHomeCliente;
    default:
      return kRouteRoleSelection;
  }
}
