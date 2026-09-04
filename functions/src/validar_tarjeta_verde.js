'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');

// Rangos de razonabilidad por categoría — rol secundario (ver REPORTE_CEO_CTO_04092026.md)
const CATALOGO_REFERENCIA = {
  utilitario:     { minKg: 500,  maxKg: 900  },
  pickup:         { minKg: 800,  maxKg: 1200 },
  camion_liviano: { minKg: 1400, maxKg: 2600 },
  camion_frio:    { minKg: 1400, maxKg: 4100 },
  camion_mediano: { minKg: 4000, maxKg: 6000 },
  camion_mudanza: { minKg: 2400, maxKg: 5000 },
};

const CATEGORIAS_VALIDAS = new Set(Object.keys(CATALOGO_REFERENCIA));

// Flag de entorno: false = mock, true = Vision API real.
// NO activar contra producción sin aprobación explícita del CPO.
const USE_REAL_OCR = process.env.USE_REAL_OCR === 'true';

// ── Parseo del texto extraído por OCR ─────────────────────────────────────────

// Tarjetas Verdes argentinas usan '.' como separador de miles y ',' como decimal.
// Ej: "1.750 Kg" = 1750 kg, "1.750,5 Kg" = 1750.5 kg.
function _parsearNumeroArg(str) {
  // 1. Quitar puntos de miles (aparecen antes de exactamente 3 dígitos)
  // 2. Reemplazar coma decimal por punto
  return parseFloat(str.replace(/\.(?=\d{3})/g, '').replace(',', '.'));
}

function parsearPBT(texto) {
  const match = texto.match(/P\.?B\.?T\.?[:\s]+(\d[\d.,]+)\s*[Kk][Gg]/i);
  if (!match) return null;
  return _parsearNumeroArg(match[1]);
}

function parsearTara(texto) {
  const match = texto.match(/[Tt][Aa][Rr][Aa][:\s]+(\d[\d.,]+)\s*[Kk][Gg]/i);
  if (!match) return null;
  return _parsearNumeroArg(match[1]);
}

// ── OCR real (Google Cloud Vision API) ───────────────────────────────────────

async function extraerTextoVisionAPI(storagePath) {
  const { ImageAnnotatorClient } = require('@google-cloud/vision');
  const client  = new ImageAnnotatorClient();
  const bucket  = getStorage().bucket();
  const gsUri   = `gs://${bucket.name}/${storagePath}`;

  const [result] = await client.textDetection({ image: { source: { imageUri: gsUri } } });
  const detections = result.textAnnotations;
  if (!detections || detections.length === 0) return { texto: '', confianzaBaja: true };

  // La primera anotación es el bloque completo de texto
  return { texto: detections[0].description ?? '', confianzaBaja: false };
}

// ── OCR mock (para tests sin costo real) ─────────────────────────────────────

function extraerTextoMock() {
  // Simula una Tarjeta Verde de Kangoo Furgón 1.6
  return {
    texto: 'TARJETA VERDE\nMarca: RENAULT\nModelo: KANGOO FURGON 1.6\nP.B.T.: 1.750 Kg\nTARA: 1.190 Kg\n',
    confianzaBaja: false,
  };
}

// ── Lógica de validación de razonabilidad ─────────────────────────────────────

function validarRazonabilidad(capacidadKg, categoria) {
  const rango = CATALOGO_REFERENCIA[categoria];
  if (!rango) return false;
  return capacidadKg >= rango.minKg && capacidadKg <= rango.maxKg;
}

// ── Notificación push al operador ─────────────────────────────────────────────

async function notificarOperador(db, vehiculoId, choferUid) {
  // Buscar todos los admins con fcmToken registrado
  const adminsSnap = await db.collection('users')
    .where('roles', 'array-contains', 'admin')
    .get();

  const tokens = adminsSnap.docs
    .map(d => d.data().fcmToken)
    .filter(Boolean);

  if (tokens.length === 0) {
    console.warn('[validar_tv] No hay admins con fcmToken registrado para notificar.');
    return;
  }

  // Registrar la notificación pendiente en Firestore para que el sistema de FCM la procese
  await db.collection('notificaciones_operador').add({
    tipo:       'revision_tarjeta_verde',
    vehiculoId,
    choferUid,
    tokens,
    creadoEn:   FieldValue.serverTimestamp(),
    procesado:  false,
  });
}

// ── Cloud Function principal ───────────────────────────────────────────────────

exports.validarTarjetaVerdeFretix = onCall(
  {
    region: 'us-central1',
    cors: [
      'https://fretix-dev-jb.web.app',
      'https://fretix-dev-jb.firebaseapp.com',
      'http://127.0.0.1:3000',
    ],
    timeoutSeconds: 60,
  },
  async (request) => {
    const db  = getFirestore();
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Se requiere autenticación.');

    const { vehiculoId } = request.data;
    if (!vehiculoId || typeof vehiculoId !== 'string') {
      throw new HttpsError('invalid-argument', 'vehiculoId requerido.');
    }

    // ── Leer el documento del vehículo ────────────────────────────────────────
    const vehiculoRef  = db.collection('vehiculos').doc(vehiculoId);
    const vehiculoSnap = await vehiculoRef.get();

    if (!vehiculoSnap.exists) {
      throw new HttpsError('not-found', `Vehículo ${vehiculoId} no encontrado.`);
    }

    const vehiculo = vehiculoSnap.data();

    if (vehiculo.choferUid !== uid) {
      throw new HttpsError('permission-denied', 'Solo el dueño del vehículo puede iniciar la validación.');
    }

    if (vehiculo.estadoValidacion === 'validado') {
      return { success: true, ya_validado: true };
    }

    const { tarjetaVerdeStoragePath, categoriaVehiculo } = vehiculo;
    if (!tarjetaVerdeStoragePath) {
      throw new HttpsError('failed-precondition', 'El vehículo no tiene Tarjeta Verde cargada.');
    }

    // ── OCR ───────────────────────────────────────────────────────────────────
    let textoExtraido, confianzaBaja;
    try {
      const resultado = USE_REAL_OCR
        ? await extraerTextoVisionAPI(tarjetaVerdeStoragePath)
        : extraerTextoMock();
      textoExtraido = resultado.texto;
      confianzaBaja = resultado.confianzaBaja;
    } catch (err) {
      console.error('[validar_tv] Error en OCR:', err.message);
      await vehiculoRef.update({ estadoValidacion: 'pendiente_revision' });
      await notificarOperador(db, vehiculoId, uid);
      return { success: false, estado: 'pendiente_revision', motivo: 'error_ocr' };
    }

    const pbt  = parsearPBT(textoExtraido);
    const tara = parsearTara(textoExtraido);

    // ── Evaluación de resultado ───────────────────────────────────────────────
    if (confianzaBaja || pbt === null || tara === null || pbt <= tara) {
      await vehiculoRef.update({
        estadoValidacion: 'pendiente_revision',
        pbtExtraido:      pbt,
        taraExtraida:     tara,
      });
      await notificarOperador(db, vehiculoId, uid);
      return { success: false, estado: 'pendiente_revision', motivo: 'extraccion_incompleta' };
    }

    const capacidadMaxKg = Math.round(pbt - tara);
    const razonable      = validarRazonabilidad(capacidadMaxKg, categoriaVehiculo);

    if (!razonable) {
      await vehiculoRef.update({
        estadoValidacion: 'pendiente_revision',
        pbtExtraido:      pbt,
        taraExtraida:     tara,
      });
      await notificarOperador(db, vehiculoId, uid);
      return { success: false, estado: 'pendiente_revision', motivo: 'fuera_de_rango_catalogo' };
    }

    // ── Éxito: Capa 1 completa ────────────────────────────────────────────────
    await vehiculoRef.update({
      estadoValidacion: 'validado',
      capacidadMaxKg,
      pbtExtraido:      pbt,
      taraExtraida:     tara,
      validadoEn:       FieldValue.serverTimestamp(),
      validadoPor:      null,  // null = validado por OCR automático
    });

    return { success: true, estado: 'validado', capacidadMaxKg };
  }
);
