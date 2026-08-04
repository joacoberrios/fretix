// Tests de humo que no requieren Firebase ni librerías web.
// Para tests de integración contra el emulador, ver test/functions/.
import 'package:flutter_test/flutter_test.dart';

import 'package:fretix/models/user_role.dart';

void main() {
  group('FretixUserRole — firestoreId', () {
    test('cada rol produce el string correcto para Firestore', () {
      expect(FretixUserRole.clienteParticular.firestoreId,     'cliente_particular');
      expect(FretixUserRole.clienteEmpresaMaestro.firestoreId, 'cliente_empresa_maestro');
      expect(FretixUserRole.choferIndependiente.firestoreId,   'chofer_independiente');
      expect(FretixUserRole.empresaTransporteMaestro.firestoreId, 'empresa_transporte_maestro');
    });

    test('fromFirestoreId reconstruye el rol correctamente', () {
      expect(FretixUserRole.fromFirestoreId('cliente_particular'),        FretixUserRole.clienteParticular);
      expect(FretixUserRole.fromFirestoreId('cliente_empresa_maestro'),   FretixUserRole.clienteEmpresaMaestro);
      expect(FretixUserRole.fromFirestoreId('chofer_independiente'),      FretixUserRole.choferIndependiente);
      expect(FretixUserRole.fromFirestoreId('empresa_transporte_maestro'), FretixUserRole.empresaTransporteMaestro);
    });

    test('fromFirestoreId devuelve clienteParticular para string desconocido', () {
      expect(FretixUserRole.fromFirestoreId('rol_desconocido'), FretixUserRole.clienteParticular);
    });

    test('requiereDatosFiscales es correcto por rol', () {
      expect(FretixUserRole.clienteParticular.requiereDatosFiscales,        isFalse);
      expect(FretixUserRole.clienteEmpresaMaestro.requiereDatosFiscales,    isTrue);
      expect(FretixUserRole.choferIndependiente.requiereDatosFiscales,      isFalse);
      expect(FretixUserRole.empresaTransporteMaestro.requiereDatosFiscales, isTrue);
    });

    test('esTransportista es correcto por rol', () {
      expect(FretixUserRole.clienteParticular.esTransportista,        isFalse);
      expect(FretixUserRole.clienteEmpresaMaestro.esTransportista,    isFalse);
      expect(FretixUserRole.choferIndependiente.esTransportista,       isTrue);
      expect(FretixUserRole.empresaTransporteMaestro.esTransportista,  isTrue);
    });

    test('round-trip: firestoreId → fromFirestoreId = identidad', () {
      for (final role in FretixUserRole.values) {
        expect(FretixUserRole.fromFirestoreId(role.firestoreId), role,
            reason: 'Round-trip falló para ${role.name}');
      }
    });
  });
}
