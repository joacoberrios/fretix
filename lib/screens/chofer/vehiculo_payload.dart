import 'package:cloud_firestore/cloud_firestore.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Funciones puras para construir payloads de /vehiculos/.
// Extraídas de SubirTarjetaVerdeScreen para poder ser testeadas en VM.
// ─────────────────────────────────────────────────────────────────────────────

/// Path de Storage: tarjetas_verde/{uid}/{timestampMs}.jpg
String buildStoragePath(String uid, int timestampMs) =>
    'tarjetas_verde/$uid/$timestampMs.jpg';

/// Payload para crear un doc /vehiculos/ nuevo (primera subida).
Map<String, dynamic> buildVehiculoPayload({
  required String uid,
  required String categoria,
  required String storagePath,
}) =>
    {
      'choferUid':               uid,
      'companyId':               null,
      'categoriaVehiculo':       categoria,
      'capacidadMaxKg':          null,
      'estadoValidacion':        'pendiente_ocr',
      'tarjetaVerdeStoragePath': storagePath,
      'pbtExtraido':             null,
      'taraExtraida':            null,
      'validadoEn':              null,
      'validadoPor':             null,
      'createdAt':               FieldValue.serverTimestamp(),
    };

/// Payload para actualizar doc existente al re-subir (subsanación).
/// No incluye choferUid ni createdAt — no deben sobreescribirse.
Map<String, dynamic> buildVehiculoUpdatePayload({
  required String categoria,
  required String storagePath,
}) =>
    {
      'categoriaVehiculo':       categoria,
      'estadoValidacion':        'pendiente_ocr',
      'tarjetaVerdeStoragePath': storagePath,
      'capacidadMaxKg':          null,
      'pbtExtraido':             null,
      'taraExtraida':            null,
      'validadoEn':              null,
      'validadoPor':             null,
    };
