// Tests unitarios para resolveHomeForRole() — BUG-SESION-01.
// Importan role_routing.dart directamente (sin dart:html chain).

import 'package:flutter_test/flutter_test.dart';
import 'package:fretix/router/role_routing.dart';

void main() {
  group('resolveHomeForRole — roles transportista', () {
    test('chofer_independiente → /home/chofer', () {
      expect(resolveHomeForRole('chofer_independiente'), kRouteHomeChofer);
    });

    test('empresa_transporte_maestro → /home/chofer', () {
      expect(resolveHomeForRole('empresa_transporte_maestro'), kRouteHomeChofer);
    });
  });

  group('resolveHomeForRole — roles cliente', () {
    test('cliente_particular → /home/cliente', () {
      expect(resolveHomeForRole('cliente_particular'), kRouteHomeCliente);
    });

    test('cliente_empresa_maestro → /home/cliente', () {
      expect(resolveHomeForRole('cliente_empresa_maestro'), kRouteHomeCliente);
    });
  });

  group('resolveHomeForRole — casos default (rol desconocido o null)', () {
    test('null → /onboarding/role (safe default)', () {
      expect(resolveHomeForRole(null), kRouteRoleSelection);
    });

    test('string vacío → /onboarding/role', () {
      expect(resolveHomeForRole(''), kRouteRoleSelection);
    });

    test('rol inventado → /onboarding/role', () {
      expect(resolveHomeForRole('rol_que_no_existe'), kRouteRoleSelection);
    });

    test('valor legacy "chofer" (bug original) → /onboarding/role, no /home/chofer', () {
      // Verifica que el valor incorrecto que había antes del fix NO produce homeChofer.
      expect(resolveHomeForRole('chofer'), kRouteRoleSelection);
    });

    test('valor legacy "empresa" (bug original) → /onboarding/role, no /home/cliente', () {
      expect(resolveHomeForRole('empresa'), kRouteRoleSelection);
    });
  });

  group('resolveHomeForRole — constantes de ruta', () {
    test('kRouteHomeChofer es /home/chofer', () {
      expect(kRouteHomeChofer, '/home/chofer');
    });

    test('kRouteHomeCliente es /home/cliente', () {
      expect(kRouteHomeCliente, '/home/cliente');
    });

    test('kRouteRoleSelection es /onboarding/role', () {
      expect(kRouteRoleSelection, '/onboarding/role');
    });
  });
}
