/// Enum de roles de usuario de Fretix.
///
/// Fuente de verdad del frontend. Los valores de [firestoreId] deben
/// coincidir EXACTAMENTE con los strings que persiste la Cloud Function
/// `completarOnboardingFretix` en Firestore (/users.onboardingRole).
enum FretixUserRole {
  clienteParticular,
  clienteEmpresaMaestro,
  choferIndependiente,
  empresaTransporteMaestro;

  /// String exacto que se envía a la Cloud Function y se guarda en Firestore.
  String get firestoreId {
    switch (this) {
      case FretixUserRole.clienteParticular:
        return 'cliente_particular';
      case FretixUserRole.clienteEmpresaMaestro:
        return 'cliente_empresa_maestro';
      case FretixUserRole.choferIndependiente:
        return 'chofer_independiente';
      case FretixUserRole.empresaTransporteMaestro:
        return 'empresa_transporte_maestro';
    }
  }

  /// Reconstruye el enum desde un string de Firestore.
  /// Útil al leer el perfil del usuario autenticado.
  static FretixUserRole fromFirestoreId(String id) {
    return FretixUserRole.values.firstWhere(
      (r) => r.firestoreId == id,
      orElse: () => FretixUserRole.clienteParticular,
    );
  }

  /// true si el rol requiere datos fiscales (CUIT + Razón Social).
  bool get requiereDatosFiscales =>
      this == FretixUserRole.clienteEmpresaMaestro ||
      this == FretixUserRole.empresaTransporteMaestro;

  /// true si el rol pertenece al lado transportista.
  bool get esTransportista =>
      this == FretixUserRole.choferIndependiente ||
      this == FretixUserRole.empresaTransporteMaestro;

  /// Label legible para mostrar en la UI.
  String get label {
    switch (this) {
      case FretixUserRole.clienteParticular:
        return 'Cliente Particular';
      case FretixUserRole.clienteEmpresaMaestro:
        return 'Cliente Empresa';
      case FretixUserRole.choferIndependiente:
        return 'Chofer Independiente';
      case FretixUserRole.empresaTransporteMaestro:
        return 'Empresa de Transporte';
    }
  }
}
