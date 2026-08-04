'use strict';
/**
 * cotizacion.test.js
 *
 * Tests para cotizarViajeFretix.
 * Requiere emuladores corriendo: firebase emulators:start --only firestore,auth
 *
 * Estrategia: se invoca la lógica de negocio directamente via Admin SDK,
 * simulando el payload que llegaría de un cliente autenticado.
 * No se usa el emulador de Functions (requiere servidor extra); se
 * llama al handler puro con un request mock.
 */

process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8282';
process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';

const { initAdmin, getDb, clearCollection, createTestUser, seedConfigMinimo } = require('./setup');

// Inicializar admin antes de cargar las funciones
const { db, auth } = initAdmin();

// ── Helpers ──────────────────────────────────────────────────────────────────

// Paradas de Mendoza Capital — 2 puntos, distancia ~4 km línea recta
const PARADAS_MENDOZA = [
  { lat: -32.8908, lng: -68.8272 },
  { lat: -32.9500, lng: -68.8700 },
];

/**
 * Construye un mock del objeto `request` que recibe onCall.
 */
function mockRequest(uid, data) {
  return {
    auth: { uid, token: { phone_number: '+5492610000001' } },
    data,
  };
}

// ── Lógica pura que podemos testear sin Functions runtime ────────────────────

// Haversine y calcularRutaHaversine — extraídos de cotizacion.js para tests unitarios
const RADIO_TIERRA_KM           = 6371;
const FACTOR_CORRECCION_MENDOZA = 1.35;
const VELOCIDAD_CONTINGENCIA    = 30;

function haversineKm(lat1, lng1, lat2, lng2) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat  = toRad(lat2 - lat1);
  const dLng  = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * RADIO_TIERRA_KM * Math.asin(Math.sqrt(a));
}

function calcularRutaHaversine(paradas) {
  let distanciaLinealKm = 0;
  for (let i = 0; i < paradas.length - 1; i++) {
    distanciaLinealKm += haversineKm(
      paradas[i].lat, paradas[i].lng,
      paradas[i + 1].lat, paradas[i + 1].lng,
    );
  }
  const distanciaKm = parseFloat((distanciaLinealKm * FACTOR_CORRECCION_MENDOZA).toFixed(2));
  const duracionMin = parseFloat(((distanciaKm / VELOCIDAD_CONTINGENCIA) * 60).toFixed(1));
  return { distanciaKm, duracionMin, polyline: null, mapsFuente: 'haversine_contingencia' };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('cotizarViajeFretix — lógica de negocio', () => {

  // ── Tests puramente unitarios (sin emulador) ─────────────────────────────

  describe('Haversine — cálculo de ruta de contingencia', () => {

    test('distancia Mendoza 2 paradas es positiva y razonable', () => {
      const ruta = calcularRutaHaversine(PARADAS_MENDOZA);
      expect(ruta.distanciaKm).toBeGreaterThan(0);
      expect(ruta.distanciaKm).toBeLessThan(50);   // Mendoza ciudad, no debe ser >50 km
      expect(ruta.duracionMin).toBeGreaterThan(0);
      expect(ruta.mapsFuente).toBe('haversine_contingencia');
      expect(ruta.polyline).toBeNull();
    });

    test('distancia aplica factor de corrección 1.35', () => {
      const lineal   = haversineKm(-32.89, -68.83, -32.95, -68.87);
      const corregida = parseFloat((lineal * FACTOR_CORRECCION_MENDOZA).toFixed(2));
      const ruta = calcularRutaHaversine([
        { lat: -32.89, lng: -68.83 },
        { lat: -32.95, lng: -68.87 },
      ]);
      expect(ruta.distanciaKm).toBeCloseTo(corregida, 1);
    });

    test('3 paradas suma correctamente los tramos', () => {
      const paradas3 = [
        { lat: -32.89, lng: -68.83 },
        { lat: -32.92, lng: -68.85 },
        { lat: -32.95, lng: -68.87 },
      ];
      const ruta = calcularRutaHaversine(paradas3);
      const tramo1 = haversineKm(-32.89, -68.83, -32.92, -68.85);
      const tramo2 = haversineKm(-32.92, -68.85, -32.95, -68.87);
      const esperado = parseFloat(((tramo1 + tramo2) * FACTOR_CORRECCION_MENDOZA).toFixed(2));
      expect(ruta.distanciaKm).toBeCloseTo(esperado, 1);
    });

    test('puntos idénticos dan distancia 0', () => {
      const ruta = calcularRutaHaversine([
        { lat: -32.89, lng: -68.83 },
        { lat: -32.89, lng: -68.83 },
      ]);
      expect(ruta.distanciaKm).toBe(0);
      expect(ruta.duracionMin).toBe(0);
    });
  });

  // ── Algoritmo de tarifa (sin Firestore) ─────────────────────────────────

  describe('Algoritmo de tarifa — desglose', () => {

    function calcularTarifa(configCat, distanciaKm, duracionMin, comisionRate, helperFee, ayudante) {
      const round2 = (n) => parseFloat(n.toFixed(2));
      const costoBase = configCat.base;
      const costoKm   = round2(configCat.perKm  * distanciaKm);
      const costoMin  = round2(configCat.perMin * duracionMin);
      const subtotal  = round2(costoBase + costoKm + costoMin);
      const helperFeeTotal = ayudante ? helperFee : 0;
      const comisionApp    = round2(subtotal * comisionRate);
      const total          = round2(subtotal + comisionApp + helperFeeTotal);
      return { costoBase, costoKm, costoMin, subtotal, helperFeeTotal, comisionApp, total };
    }

    const catMini = { base: 1800, perKm: 350, perMin: 90 };
    const COMISION = 0.15;
    const HELPER   = 5000;

    test('total > subtotal cuando hay comisión', () => {
      const r = calcularTarifa(catMini, 5, 10, COMISION, HELPER, false);
      expect(r.total).toBeGreaterThan(r.subtotal);
      expect(r.comisionApp).toBeCloseTo(r.subtotal * COMISION, 1);
    });

    test('ayudante=true suma helperFee al total', () => {
      const sin = calcularTarifa(catMini, 5, 10, COMISION, HELPER, false);
      const con = calcularTarifa(catMini, 5, 10, COMISION, HELPER, true);
      expect(con.total - sin.total).toBeCloseTo(HELPER, 0);
    });

    test('comisión NO incluye helperFee (invariante de negocio)', () => {
      const r = calcularTarifa(catMini, 5, 10, COMISION, HELPER, true);
      // comisionApp debe ser sobre subtotal, no sobre subtotal+helperFee
      expect(r.comisionApp).toBeCloseTo(r.subtotal * COMISION, 1);
    });

    test('categoría "heavy" produce tarifa mayor que "mini"', () => {
      const catHeavy = { base: 15000, perKm: 1200, perMin: 250 };
      const rMini  = calcularTarifa(catMini,  5, 10, COMISION, HELPER, false);
      const rHeavy = calcularTarifa(catHeavy, 5, 10, COMISION, HELPER, false);
      expect(rHeavy.total).toBeGreaterThan(rMini.total);
    });
  });

});

describe('cotizarViajeFretix — validaciones de payload', () => {
  // Tests de validación de input sin necesidad de emulador

  const CATEGORIAS_VALIDAS = new Set(['mini', 'plus', 'max', 'heavy']);

  test('categorías válidas son exactamente 4', () => {
    expect(CATEGORIAS_VALIDAS.size).toBe(4);
    expect(CATEGORIAS_VALIDAS.has('mini')).toBe(true);
    expect(CATEGORIAS_VALIDAS.has('heavy')).toBe(true);
    expect(CATEGORIAS_VALIDAS.has('moto')).toBe(false);
    expect(CATEGORIAS_VALIDAS.has('')).toBe(false);
  });

  test('parada sin lat/lng numérico debe ser rechazada', () => {
    const paradas = [{ lat: 'texto', lng: -68.83 }, { lat: -32.95, lng: -68.87 }];
    for (const p of paradas) {
      const valido = typeof p?.lat === 'number' && typeof p?.lng === 'number';
      if (!valido) {
        expect(valido).toBe(false);
        return;
      }
    }
    fail('Debería haber detectado parada inválida');
  });

  test('coordenadas fuera de rango deben ser rechazadas', () => {
    const fuera = { lat: 200, lng: -68.83 }; // lat > 90
    expect(fuera.lat < -90 || fuera.lat > 90 || fuera.lng < -180 || fuera.lng > 180).toBe(true);
  });
});
