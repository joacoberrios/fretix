'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const CATEGORIAS_VALIDAS = new Set(['mini', 'plus', 'max', 'heavy']);

exports.confirmarViajeFretix = onCall(async (request) => {
  const db  = getFirestore(); // lazy: después de que FIRESTORE_EMULATOR_HOST esté seteado
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'Se requiere autenticación.');

  const d = request.data;

  if (!d.categoria || !CATEGORIAS_VALIDAS.has(d.categoria)) {
    throw new HttpsError('invalid-argument', 'Categoría inválida.');
  }
  if (!d.origen?.lat || !d.origen?.lng || !d.destino?.lat || !d.destino?.lng) {
    throw new HttpsError('invalid-argument', 'Origen o destino incompleto.');
  }
  if (typeof d.cotizacion?.total !== 'number' || d.cotizacion.total <= 0) {
    throw new HttpsError('invalid-argument', 'Cotización inválida.');
  }

  const docRef = await db.collection('viajes').add({
    clienteUid:    uid,
    clientType:    d.clientType ?? 'particular',
    estado:        'pending',
    pricingMethod: d.pricingMethod ?? 'haversine_contingencia',
    categoria:     d.categoria,
    ayudante:      d.ayudante === true,
    origen: {
      lat:     d.origen.lat,
      lng:     d.origen.lng,
      address: d.origen.address ?? '',
    },
    destino: {
      lat:     d.destino.lat,
      lng:     d.destino.lng,
      address: d.destino.address ?? '',
    },
    cotizacion: {
      total:       d.cotizacion.total,
      distanciaKm: d.cotizacion.distanciaKm ?? 0,
      duracionMin: d.cotizacion.duracionMin ?? 0,
    },
    creadoEn: FieldValue.serverTimestamp(),
  });

  return { viajeId: docRef.id };
});
