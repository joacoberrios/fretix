// Tests de la lógica de cálculo del dashboard del chofer.
// No requieren Firebase inicializado — usan Timestamp.fromDate() como valor puro.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fretix/screens/home/dashboard_stats_logic.dart';

void main() {
  // Ancla fija en UTC para reproducibilidad de tests.
  // Equivale a 2026-09-24 00:00:00 hora Mendoza (UTC-3) = 2026-09-24 03:00:00 UTC.
  final startHoy = DateTime.utc(2026, 9, 24, 3, 0, 0);
  final hoy10hs  = DateTime.utc(2026, 9, 24, 13, 0, 0); // 10:00 hs Mendoza
  final ayer23hs = DateTime.utc(2026, 9, 23, 23, 0, 0); // 20:00 hs Mendoza de ayer

  Map<String, dynamic> viajeFake({
    required DateTime completadoEn,
    required double total,
    double? comisionApp,
  }) =>
      {
        'completadoEn': Timestamp.fromDate(completadoEn),
        'cotizacion':   {
          'total':       total,
          if (comisionApp != null) 'comisionApp': comisionApp,
        },
      };

  group('calcularStatsDesdeDocumentos', () {
    test('0 viajes → no tira error, devuelve ceros', () {
      final stats = calcularStatsDesdeDocumentos([], startHoy);
      expect(stats.viajesHoy,  0);
      expect(stats.ganadoHoy, 0.0);
    });

    // Caso CPO: 3 viajes de \$10.000 total con \$1.500 de comisión
    // → \$8.500 neto por viaje × 3 = \$25.500, NO \$30.000 bruto.
    test('3 viajes de \$10.000 con comisionApp=\$1.500 → \$25.500 neto (no \$30.000 bruto)', () {
      final docs = List.generate(
        3,
        (_) => viajeFake(completadoEn: hoy10hs, total: 10000, comisionApp: 1500),
      );
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 3);
      expect(stats.ganadoHoy, closeTo(25500, 0.01));
    });

    // Verifica el bug original: sin comisionApp en el doc → muestra bruto.
    // Con el fix (guardar comisionApp en Firestore), este escenario no ocurre
    // para viajes nuevos. Para viajes legados sin comisionApp → fallback 0 → muestra bruto.
    test('viajes SIN comisionApp en doc → fallback 0, muestra bruto (escenario legado)', () {
      final docs = List.generate(
        3,
        (_) => viajeFake(completadoEn: hoy10hs, total: 10000, comisionApp: null),
      );
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 3);
      expect(stats.ganadoHoy, closeTo(30000, 0.01)); // bruto (bug para datos legados)
    });

    test('viajes de ayer NO se cuentan', () {
      final docs = [
        viajeFake(completadoEn: ayer23hs, total: 10000, comisionApp: 1500),
        viajeFake(completadoEn: hoy10hs,  total: 10000, comisionApp: 1500),
      ];
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 1);
      expect(stats.ganadoHoy, closeTo(8500, 0.01));
    });

    test('viaje con completadoEn null se ignora sin lanzar excepción', () {
      final docs = [
        {'completadoEn': null, 'cotizacion': {'total': 10000.0, 'comisionApp': 1500.0}},
        viajeFake(completadoEn: hoy10hs, total: 10000, comisionApp: 1500),
      ];
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 1);
      expect(stats.ganadoHoy, closeTo(8500, 0.01));
    });

    test('viaje con cotizacion null cuenta el viaje pero suma \$0', () {
      final docs = [
        {'completadoEn': Timestamp.fromDate(hoy10hs), 'cotizacion': null},
      ];
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 1);
      expect(stats.ganadoHoy, 0.0);
    });

    // Fórmula según cotizacion.js real:
    // subtotal=10000, comisionApp=1500 (15% de subtotal), total=11500
    // Chofer gana: total - comisionApp = 11500 - 1500 = 10000 (= subtotal)
    test('fórmula CF real: subtotal=\$10.000, total=\$11.500, comision=\$1.500 → neto=\$10.000', () {
      final docs = [
        viajeFake(completadoEn: hoy10hs, total: 11500, comisionApp: 1500),
      ];
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 1);
      expect(stats.ganadoHoy, closeTo(10000, 0.01));
    });

    test('ayudante incluido: helperFee va al chofer, no se descuenta', () {
      // subtotal=10000, helperFee=5000, comisionApp=1500, total=16500
      // Chofer gana: 16500 - 1500 = 15000 (subtotal + helperFee)
      final docs = [
        viajeFake(completadoEn: hoy10hs, total: 16500, comisionApp: 1500),
      ];
      final stats = calcularStatsDesdeDocumentos(docs, startHoy);
      expect(stats.viajesHoy, 1);
      expect(stats.ganadoHoy, closeTo(15000, 0.01));
    });
  });
}
