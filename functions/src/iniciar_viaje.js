'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const ROLES_CHOFER = new Set(['chofer_independiente', 'empresa_transporte_maestro']);

exports.iniciarViajeFretix = onCall(
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

    // Verificar que el caller es un chofer
    const choferSnap = await db.collection('users').doc(uid).get();
    if (!choferSnap.exists) {
      throw new HttpsError('not-found', 'Perfil de chofer no encontrado.');
    }
    if (!ROLES_CHOFER.has(choferSnap.data().onboardingRole)) {
      throw new HttpsError('permission-denied', 'Solo choferes pueden iniciar viajes.');
    }

    const viajeRef = db.collection('viajes').doc(viajeId);

    try {
      await db.runTransaction(async (tx) => {
        const viajeSnap = await tx.get(viajeRef);

        if (!viajeSnap.exists) {
          throw new HttpsError('not-found', `Viaje ${viajeId} no encontrado.`);
        }

        const viaje = viajeSnap.data();

        if (viaje.choferUid !== uid) {
          throw new HttpsError('permission-denied', 'Solo el chofer asignado puede iniciar este viaje.');
        }

        if (viaje.estado !== 'aceptado') {
          throw new HttpsError(
            'failed-precondition',
            `Solo se puede iniciar un viaje en estado 'aceptado'. Estado actual: '${viaje.estado}'.`
          );
        }

        tx.update(viajeRef, {
          estado:     'en_curso',
          iniciadoEn: FieldValue.serverTimestamp(),
        });
      });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      console.error('[iniciar_viaje] Error en transacción:', err.message);
      throw new HttpsError('unavailable', 'No se pudo iniciar el viaje. Intentá de nuevo.');
    }

    return { success: true, viajeId };
  }
);
