'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

// Estados desde los que se puede cancelar
const ESTADOS_CANCELABLES = new Set(['pending', 'aceptado']);

exports.cancelarViajeFretix = onCall(
  {
    region: 'us-central1',
    cors: [
      'https://fretix-dev-jb.web.app',
      'https://fretix-dev-jb.firebaseapp.com',
      'http://127.0.0.1:3000',
    ],
  },
  async (request) => {
    const db  = getFirestore();
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Se requiere autenticación.');

    const { viajeId } = request.data;
    if (!viajeId || typeof viajeId !== 'string') {
      throw new HttpsError('invalid-argument', 'viajeId requerido.');
    }

    const viajeRef = db.collection('viajes').doc(viajeId);

    try {
      await db.runTransaction(async (tx) => {
        const viajeSnap = await tx.get(viajeRef);

        if (!viajeSnap.exists) {
          throw new HttpsError('not-found', `Viaje ${viajeId} no encontrado.`);
        }

        const viaje = viajeSnap.data();
        const isCliente = viaje.clienteUid === uid;
        const isChofer  = viaje.choferUid  === uid;

        if (!isCliente && !isChofer) {
          throw new HttpsError('permission-denied', 'No tenés permiso para cancelar este viaje.');
        }

        if (!ESTADOS_CANCELABLES.has(viaje.estado)) {
          throw new HttpsError(
            'failed-precondition',
            `No se puede cancelar un viaje en estado '${viaje.estado}'.`
          );
        }

        // Chofer solo puede cancelar desde 'aceptado' (no puede cancelar un pending donde no está asignado)
        if (isChofer && !isCliente && viaje.estado === 'pending') {
          throw new HttpsError('permission-denied', 'Solo el cliente puede cancelar un viaje en estado pending.');
        }

        tx.update(viajeRef, {
          estado:          'cancelado',
          canceladoEn:     FieldValue.serverTimestamp(),
          canceladoPor:    uid,
          canceladoPorRol: isCliente ? 'cliente' : 'chofer',
        });
      });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      console.error('[cancelar_viaje] Error en transacción:', err.message);
      throw new HttpsError('unavailable', 'No se pudo cancelar el viaje. Intentá de nuevo.');
    }

    return { success: true, viajeId };
  }
);
