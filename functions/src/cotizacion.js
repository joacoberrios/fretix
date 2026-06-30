// functions/src/cotizacion.js
// Cloud Function: cotizarViajeFretix
//
// Responsabilidad: dado un array de coordenadas (paradas) y una categoría de flete,
// devuelve la cotización completa con distancia, duración, desglose y total.
//
// Fuente de ruta primaria:  Google Maps Directions API (axios, timeout 8 s)
// Fuente de ruta fallback:  Haversine × factor de corrección 1.35 para Mendoza
// Config de tarifas:        Firestore /config/tarifas  (leída en runtime)
// Config de app:            Firestore /config/app       (comisión, helperFee)
// API Key de Maps:          Firebase Secret → defineString('MAPS_API_KEY')

'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore }       = require('firebase-admin/firestore');
const axios                  = require('axios');

const db = getFirestore();

// API Key leída de variable de entorno — compatible con emulador (.env) y producción
// (Firebase Secret Manager expone secrets como env vars en runtime v2).
// En emulador: crear functions/.env con MAPS_API_KEY=tu_clave
// En prod: firebase functions:secrets:set MAPS_API_KEY
const getMapsApiKey = () => process.env.MAPS_API_KEY || '';

// ─── Constantes ──────────────────────────────────────────────────────────────

const CATEGORIAS_VALIDAS         = new Set(['mini', 'plus', 'max', 'heavy']);
const COMISION_DEFAULT           = 0.15;
const HELPER_FEE_DEFAULT         = 5000;

// Factor de corrección: Mendoza tiene trazado en damero con algunos
// bulevares diagonales. En promedio, la distancia real por calles es
// un 35 % mayor que la distancia en línea recta (crow-fly).
const FACTOR_CORRECCION_MENDOZA  = 1.35;

// Velocidad urbana conservadora para estimar tiempo en contingencia.
const VELOCIDAD_CONTINGENCIA_KMH = 30;

const RADIO_TIERRA_KM            = 6371;
const MAPS_TIMEOUT_MS            = 8_000;

// ─── Haversine ───────────────────────────────────────────────────────────────

/**
 * Distancia en línea recta entre dos puntos geográficos (km).
 */
function haversineKm(lat1, lng1, lat2, lng2) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const dLat  = toRad(lat2 - lat1);
  const dLng  = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * RADIO_TIERRA_KM * Math.asin(Math.sqrt(a));
}

/**
 * Calcula distancia y duración estimada usando Haversine para cada tramo.
 * Aplica el factor de corrección y velocidad urbana de contingencia.
 */
function calcularRutaHaversine(paradas) {
  let distanciaLinealKm = 0;
  for (let i = 0; i < paradas.length - 1; i++) {
    distanciaLinealKm += haversineKm(
      paradas[i].lat, paradas[i].lng,
      paradas[i + 1].lat, paradas[i + 1].lng,
    );
  }

  // Distancia corregida: línea recta × 1.35 ≈ recorrido real por calles
  const distanciaKm = round2(distanciaLinealKm * FACTOR_CORRECCION_MENDOZA);

  // Tiempo estimado a velocidad urbana de contingencia
  const duracionMin = round1((distanciaKm / VELOCIDAD_CONTINGENCIA_KMH) * 60);

  return {
    distanciaKm,
    duracionMin,
    polyline:   null,
    mapsFuente: 'haversine_contingencia',
  };
}

// ─── Google Maps Directions ───────────────────────────────────────────────────

/**
 * Llama a la API de Google Maps Directions.
 * Soporta múltiples paradas intermedias (waypoints).
 * Suma todos los legs para obtener distancia y duración totales del recorrido.
 *
 * @throws Error si la respuesta no es OK o hay timeout.
 */
async function calcularRutaGoogleMaps(paradas, apiKey) {
  const origen  = coordStr(paradas[0]);
  const destino = coordStr(paradas[paradas.length - 1]);

  // Paradas intermedias (excluye origen y destino)
  const waypoints = paradas.slice(1, -1).map(coordStr).join('|');

  const params = {
    origin:      origen,
    destination: destino,
    key:         apiKey,
    mode:        'driving',
    language:    'es',
    region:      'ar',
    ...(waypoints && { waypoints }),
  };

  const response = await axios.get(
    'https://maps.googleapis.com/maps/api/directions/json',
    { params, timeout: MAPS_TIMEOUT_MS },
  );

  const { status, routes } = response.data;

  if (status !== 'OK' || !routes?.length) {
    throw new Error(`Google Maps status: ${status}`);
  }

  const route = routes[0];

  // Acumular distancia y duración de todos los tramos (legs).
  // Habrá N legs si hay N-1 waypoints intermedios.
  let distanciaMetros   = 0;
  let duracionSegundos  = 0;
  for (const leg of route.legs) {
    distanciaMetros  += leg.distance.value;
    duracionSegundos += leg.duration.value;
  }

  return {
    distanciaKm: round2(distanciaMetros / 1000),
    duracionMin: round1(duracionSegundos / 60),
    polyline:    route.overview_polyline?.points ?? null,
    mapsFuente:  'google_maps',
  };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const coordStr = (p) => `${p.lat},${p.lng}`;
const round2   = (n) => parseFloat(n.toFixed(2));
const round1   = (n) => parseFloat(n.toFixed(1));

// ─── Cloud Function ───────────────────────────────────────────────────────────

/**
 * Callable Function: cotizarViajeFretix
 *
 * Payload esperado desde Flutter:
 * {
 *   categoria: 'mini' | 'plus' | 'max' | 'heavy',
 *   paradas: [
 *     { lat: number, lng: number },   // origen
 *     { lat: number, lng: number },   // parada intermedia (opcional)
 *     { lat: number, lng: number },   // destino
 *   ],
 *   ayudante: boolean,   // opcional, default false
 * }
 *
 * Respuesta:
 * {
 *   categoria, distanciaKm, duracionMin,
 *   desglose: { base, porKm, porMin },
 *   subtotal, helperFee, comisionApp, total,
 *   polyline,       // encoded polyline de Google Maps, o null en contingencia
 *   mapsFuente,     // 'google_maps' | 'haversine_contingencia'
 * }
 */
exports.cotizarViajeFretix = onCall(
  {
    region:          'us-central1',
    enforceAppCheck: false,
    cors:            true, // permite todos los orígenes — restringir a dominio propio en prod
  },
  async (request) => {

    // ── 1. Autenticación ──────────────────────────────────────────────────────
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Autenticación requerida para cotizar.');
    }

    // ── 2. Validación de payload ──────────────────────────────────────────────
    const { categoria, paradas, ayudante = false } = request.data;

    if (!CATEGORIAS_VALIDAS.has(categoria)) {
      throw new HttpsError(
        'invalid-argument',
        `Categoría inválida: "${categoria}". Valores aceptados: mini, plus, max, heavy.`,
      );
    }
    if (!Array.isArray(paradas) || paradas.length < 2) {
      throw new HttpsError(
        'invalid-argument',
        'paradas debe ser un array con al menos 2 elementos (origen y destino).',
      );
    }
    for (let i = 0; i < paradas.length; i++) {
      const p = paradas[i];
      if (typeof p?.lat !== 'number' || typeof p?.lng !== 'number') {
        throw new HttpsError(
          'invalid-argument',
          `paradas[${i}] debe tener lat y lng numéricos.`,
        );
      }
      if (p.lat < -90 || p.lat > 90 || p.lng < -180 || p.lng > 180) {
        throw new HttpsError(
          'invalid-argument',
          `paradas[${i}] tiene coordenadas fuera de rango.`,
        );
      }
    }

    // ── 3. Leer configuración desde Firestore (runtime) ───────────────────────
    const [tarifasSnap, appSnap] = await Promise.all([
      db.collection('config').doc('tarifas').get(),
      db.collection('config').doc('app').get(),
    ]);

    if (!tarifasSnap.exists) {
      throw new HttpsError(
        'not-found',
        'Documento /config/tarifas no existe en Firestore. Ejecutá el seed de configuración.',
      );
    }

    const tarifasDoc = tarifasSnap.data();
    const appDoc     = appSnap.exists ? appSnap.data() : {};

    const configCategoria = tarifasDoc[categoria];
    if (!configCategoria?.base || !configCategoria?.perKm || !configCategoria?.perMin) {
      throw new HttpsError(
        'not-found',
        `Configuración de tarifa para "${categoria}" está incompleta.`,
      );
    }

    const comisionRate  = appDoc.comisionPlatforma ?? COMISION_DEFAULT;
    const helperFeeMonto = appDoc.helperFee ?? HELPER_FEE_DEFAULT;

    // ── 4. Obtener ruta: Google Maps → Haversine en contingencia ─────────────
    let routeData;
    try {
      routeData = await calcularRutaGoogleMaps(paradas, getMapsApiKey());
      console.info('[cotizar] Ruta obtenida de Google Maps:', routeData.distanciaKm, 'km');
    } catch (err) {
      console.warn('[cotizar] Google Maps falló — activando contingencia Haversine:', err.message);
      routeData = calcularRutaHaversine(paradas);
    }

    const { distanciaKm, duracionMin, polyline, mapsFuente } = routeData;

    // ── 5. Algoritmo de tarifa ────────────────────────────────────────────────
    //
    // subtotal  = base + (perKm × distanciaKm) + (perMin × duracionMin)
    // helperFee = si ayudante=true → monto fijo (100% al chofer, fuera de comisión)
    // comisionApp = subtotal × 15%   ← NO incluye helperFee (invariante de negocio)
    // total     = subtotal + comisionApp + helperFee

    const costoBase = configCategoria.base;
    const costoKm   = round2(configCategoria.perKm  * distanciaKm);
    const costoMin  = round2(configCategoria.perMin * duracionMin);
    const subtotal  = round2(costoBase + costoKm + costoMin);

    const helperFee  = ayudante ? helperFeeMonto : 0;
    const comisionApp = round2(subtotal * comisionRate);
    const total       = round2(subtotal + comisionApp + helperFee);

    console.info(
      `[cotizar] uid=${request.auth.uid} cat=${categoria} dist=${distanciaKm}km `+
      `dur=${duracionMin}min subtotal=${subtotal} total=${total} fuente=${mapsFuente}`,
    );

    return {
      categoria,
      distanciaKm,
      duracionMin,
      desglose: {
        base:   costoBase,
        porKm:  costoKm,
        porMin: costoMin,
      },
      subtotal,
      helperFee,
      comisionApp,
      total,
      polyline,
      mapsFuente,
    };
  },
);
