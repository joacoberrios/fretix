import 'package:cloud_firestore/cloud_firestore.dart';

class DashStats {
  const DashStats({required this.viajesHoy, required this.ganadoHoy});
  final int    viajesHoy;
  final double ganadoHoy;
}

// Mendoza: UTC-3, sin DST. Devuelve inicio del día Mendoza como DateTime UTC.
DateTime startOfTodayMendoza() {
  final nowUtc     = DateTime.now().toUtc();
  final nowMendoza = nowUtc.subtract(const Duration(hours: 3));
  final dayMendoza = DateTime.utc(nowMendoza.year, nowMendoza.month, nowMendoza.day);
  return dayMendoza.add(const Duration(hours: 3));
}

// Calcula viajes y ganancia a partir de docs crudos de Firestore.
// Función pura — sin dependencias de Firebase en runtime, testeable sin emulador.
//
// Ganancia por viaje = cotizacion.total - cotizacion.comisionApp
// (neto para el chofer: subtotal + helperFee, sin comisión de plataforma).
// Si comisionApp no está en el doc (datos legados) → fallback 0 → muestra bruto.
DashStats calcularStatsDesdeDocumentos(
    List<Map<String, dynamic>> docs, DateTime startUtc) {
  double ganado = 0;
  int    count  = 0;

  for (final data in docs) {
    final ts = data['completadoEn'];
    if (ts == null) continue;
    final completado = (ts as Timestamp).toDate().toUtc();
    if (completado.isBefore(startUtc)) continue;

    count++;
    final cot = data['cotizacion'] as Map<String, dynamic>?;
    if (cot != null) {
      final total    = (cot['total']      as num?)?.toDouble() ?? 0;
      final comision = (cot['comisionApp'] as num?)?.toDouble() ?? 0;
      ganado        += total - comision;
    }
  }
  return DashStats(viajesHoy: count, ganadoHoy: ganado);
}
