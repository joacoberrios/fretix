'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const ROLES_CHOFER = new Set(['chofer_independiente', 'empresa_transporte_maestro']);

exports.aceptarViajeFretix = onCall(
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

    // ── Verificar que el caller es un chofer ──────────────────────────────────
    const choferRef  = db.collection('users').doc(uid);
    const choferSnap = await choferRef.get();

    if (!choferSnap.exists) {
      throw new HttpsError('not-found', 'Perfil de chofer no encontrado.');
    }

    const choferData = choferSnap.data();

    if (!ROLES_CHOFER.has(choferData.onboardingRole)) {
      throw new HttpsError('permission-denied', 'Solo choferes pueden aceptar viajes.');
    }

    if (!choferData.disponibleParaViajes) {
      throw new HttpsError('failed-precondition', 'El chofer no está disponible para viajes.');
    }

    if (!choferData.categoriaVehiculo) {
      throw new HttpsError('failed-precondition', 'El chofer no tiene categoría de vehículo configurada.');
    }

    // ── Transacción: garantiza que solo un chofer acepta el viaje ─────────────
    const viajeRef = db.collection('viajes').doc(viajeId);

    try {
      await db.runTransaction(async (tx) => {
        const viajeSnap = await tx.get(viajeRef);

        if (!viajeSnap.exists) {
          throw new HttpsError('not-found', `Viaje ${viajeId} no encontrado.`);
        }

        const viaje = viajeSnap.data();

        if (viaje.estado !== 'pending') {
          throw new HttpsError(
            'failed-precondition',
            viaje.estado === 'aceptado'
              ? 'Este viaje ya fue aceptado por otro chofer.'
              : `Estado del viaje no permite aceptación: ${viaje.estado}.`
          );
        }

        // Verificar que la categoría del viaje coincide con la del chofer
        if (viaje.categoria !== choferData.categoriaVehiculo) {
          throw new HttpsError(
            'failed-precondition',
            `Este viaje requiere categoría '${viaje.categoria}', tu vehículo es '${choferData.categoriaVehiculo}'.`
          );
        }

        tx.update(viajeRef, {
          estado:    'aceptado',
          choferUid: uid,
          choferData: {
            displayName: choferData.displayName ?? null,
            photoURL:    choferData.photoURL    ?? null,
          },
          aceptadoEn: FieldValue.serverTimestamp(),
        });
      });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      console.error('[aceptar_viaje] Error en transacción:', err.message);
      throw new HttpsError('unavailable', 'No se pudo aceptar el viaje. Intentá de nuevo.');
    }

    return { success: true, viajeId };
  }
);
