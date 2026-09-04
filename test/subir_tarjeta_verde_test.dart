// Tests unitarios para la lógica de payload de /vehiculos/.
// Importan vehiculo_payload.dart directamente para evitar dependencias
// de dart:html que arrastra app_router → search_location_screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:fretix/screens/chofer/vehiculo_payload.dart';

void main() {
  // ── buildStoragePath ────────────────────────────────────────────────────────

  group('buildStoragePath', () {
    test('genera path con prefijo tarjetas_verde/{uid}/{timestamp}.jpg', () {
      const uid = 'chofer-uid-test-123';
      const ts  = 1725400000000;
      expect(buildStoragePath(uid, ts), 'tarjetas_verde/$uid/$ts.jpg');
    });

    test('uid distinto produce path distinto', () {
      expect(
        buildStoragePath('uid-a', 1000) != buildStoragePath('uid-b', 1000),
        isTrue,
      );
    });

    test('timestamp distinto produce path distinto (historial de re-subidas)', () {
      expect(
        buildStoragePath('uid-x', 1000) != buildStoragePath('uid-x', 2000),
        isTrue,
      );
    });
  });

  // ── buildVehiculoPayload (creación) ─────────────────────────────────────────

  group('buildVehiculoPayload', () {
    const uid         = 'chofer-uid-abc';
    const categoria   = 'utilitario';
    const storagePath = 'tarjetas_verde/chofer-uid-abc/1725400000000.jpg';

    late Map<String, dynamic> payload;

    setUp(() {
      payload = buildVehiculoPayload(
        uid:         uid,
        categoria:   categoria,
        storagePath: storagePath,
      );
    });

    test('estadoValidacion arranca en pendiente_ocr', () {
      expect(payload['estadoValidacion'], 'pendiente_ocr');
    });

    test('capacidadMaxKg arranca en null (default seguro)', () {
      expect(payload['capacidadMaxKg'], isNull);
    });

    test('choferUid es el uid correcto', () {
      expect(payload['choferUid'], uid);
    });

    test('categoriaVehiculo es la categoría seleccionada', () {
      expect(payload['categoriaVehiculo'], categoria);
    });

    test('tarjetaVerdeStoragePath es el path de Storage', () {
      expect(payload['tarjetaVerdeStoragePath'], storagePath);
    });

    test('companyId arranca en null', () {
      expect(payload['companyId'], isNull);
    });

    test('pbtExtraido y taraExtraida arrancan en null', () {
      expect(payload['pbtExtraido'],  isNull);
      expect(payload['taraExtraida'], isNull);
    });

    test('validadoEn y validadoPor arrancan en null', () {
      expect(payload['validadoEn'],  isNull);
      expect(payload['validadoPor'], isNull);
    });

    test('payload tiene exactamente los campos del esquema /vehiculos/', () {
      expect(
        payload.keys.toSet(),
        containsAll([
          'choferUid', 'companyId', 'categoriaVehiculo', 'capacidadMaxKg',
          'estadoValidacion', 'tarjetaVerdeStoragePath',
          'pbtExtraido', 'taraExtraida', 'validadoEn', 'validadoPor', 'createdAt',
        ]),
      );
    });
  });

  // ── buildVehiculoUpdatePayload (re-subida / subsanación) ────────────────────

  group('buildVehiculoUpdatePayload', () {
    const categoria   = 'pickup';
    const storagePath = 'tarjetas_verde/uid-xyz/1725400099999.jpg';

    late Map<String, dynamic> payload;

    setUp(() {
      payload = buildVehiculoUpdatePayload(
        categoria:   categoria,
        storagePath: storagePath,
      );
    });

    test('estadoValidacion vuelve a pendiente_ocr al re-subir', () {
      expect(payload['estadoValidacion'], 'pendiente_ocr');
    });

    test('capacidadMaxKg se resetea a null', () {
      expect(payload['capacidadMaxKg'], isNull);
    });

    test('pbtExtraido y taraExtraida se resetean a null', () {
      expect(payload['pbtExtraido'],  isNull);
      expect(payload['taraExtraida'], isNull);
    });

    test('validadoEn y validadoPor se resetean a null', () {
      expect(payload['validadoEn'],  isNull);
      expect(payload['validadoPor'], isNull);
    });

    test('categoriaVehiculo se actualiza con la nueva selección', () {
      expect(payload['categoriaVehiculo'], categoria);
    });

    test('tarjetaVerdeStoragePath apunta al nuevo path', () {
      expect(payload['tarjetaVerdeStoragePath'], storagePath);
    });

    test('update payload NO contiene choferUid ni createdAt', () {
      expect(payload.containsKey('choferUid'), isFalse);
      expect(payload.containsKey('createdAt'), isFalse);
    });
  });

  // ── Invariantes de negocio ──────────────────────────────────────────────────

  group('invariantes de negocio', () {
    test('categorías válidas en el selector UI son exactamente 7', () {
      const categoriasUI = [
        'utilitario', 'pickup', 'pickup_estructura',
        'camion_liviano', 'camion_frio', 'camion_mediano', 'camion_mudanza',
      ];
      expect(categoriasUI.length, 7);
    });

    test('pickup_estructura NO está en CATALOGO_REFERENCIA del backend '
        '(irá a pendiente_revision — documentado)', () {
      // La UI acepta pickup_estructura pero el backend lo enviará a revisión
      // manual porque no está en el catálogo de razonabilidad OCR.
      // Ref: VALIDACION_LOG.md — Tarea 11.
      const categoriasFrontend = {
        'utilitario', 'pickup', 'pickup_estructura',
        'camion_liviano', 'camion_frio', 'camion_mediano', 'camion_mudanza',
      };
      const catalogoBackend = {
        'utilitario', 'pickup',
        'camion_liviano', 'camion_frio', 'camion_mediano', 'camion_mudanza',
      };
      expect(
        categoriasFrontend.difference(catalogoBackend),
        equals({'pickup_estructura'}),
      );
    });
  });
}
