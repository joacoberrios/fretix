'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const ROLES_CHOFER = new Set(['chofer_independiente', 'empresa_transporte_maestro']);

// Opción C — mapeo provisional categoría de viaje → kg mínimo requerido.
// Basado en minKg del CATALOGO_REFERENCIA de validar_tarjeta_verde.js.
// Sin techo: vehículo grande puede tomar viaje chico (limitación conocida,
// ver VALIDACION_LOG.md § Limitación conocida — Tarea 7).
// TODO(CPO/DP-1): reemplazar por campo cargaKg explícito en el viaje
// cuando el cotizador lo capture (Opción A futura).
const UMBRAL_KG_POR_CATEGORIA = {
  mini:  500,
  plus:  800,
  max:   1400,
  heavy: 4000,
};

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

    // ── Verificar vehículo validado (prerequisito antes de comparar capacidad) ─
    // estadoValidacion == 'validado' es requisito previo. Si no está validado,
    // ni se lee capacidadMaxKg.
    const vehiculosSnap = await db.collection('vehiculos')
      .where('choferUid', '==', uid)
      .where('estadoValidacion', '==', 'validado')
      .limit(1)
      .get();

    if (vehiculosSnap.empty) {
      throw new HttpsError(
        'failed-precondition',
        'No tenés vehículo validado. Completá la verificación de la Tarjeta Verde.'
      );
    }

    const capacidadMaxKg = vehiculosSnap.docs[0].data().capacidadMaxKg;
    if (!capacidadMaxKg || capacidadMaxKg <= 0) {
      throw new HttpsError(
        'failed-precondition',
        'Tu vehículo no tiene capacidad registrada. Contactá con soporte.'
      );
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

        // Opción C: umbral mínimo por categoría; sin techo documentado.
        // Ver VALIDACION_LOG.md § Limitación conocida — Tarea 7.
        const umbral = UMBRAL_KG_POR_CATEGORIA[viaje.categoria];
        if (!umbral) {
          throw new HttpsError(
            'failed-precondition',
            `Categoría de viaje desconocida: '${viaje.categoria}'.`
          );
        }

        if (capacidadMaxKg < umbral) {
          throw new HttpsError(
            'failed-precondition',
            `Tu vehículo (${capacidadMaxKg} kg) no alcanza para este viaje (mínimo ${umbral} kg).`
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
