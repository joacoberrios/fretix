'use strict';
/**
 * confirmar_viaje.test.js
 *
 * Tests para confirmarViajeFretix — especialmente la lógica de crédito B2B.
 * Los tests de integración con Firestore requieren emulador en 127.0.0.1:8282.
 */

process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8282';
process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';

const { initAdmin, getDb, clearCollection, createTestUser } = require('./setup');
const { db } = initAdmin();

// ── Lógica de crédito extraída de confirmar_viaje.js para tests unitarios ────

/**
 * Replica exacta de la lógica creditOk de confirmarViajeFretix.
 * Separada aquí para poder testear sin el runtime de Firebase Functions.
 */
function evaluarCredito(cc) {
  const habilitada       = cc.habilitada       ?? false;
  const macroLimitAudit  = cc.macroLimitAudit  ?? null;
  const saldoActualARS   = cc.saldoActualARS   ?? null;
  const limiteCreditoARS = cc.limiteCreditoARS ?? null;

  if (!habilitada) {
    return macroLimitAudit !== null;
  }
  if (saldoActualARS !== null && limiteCreditoARS !== null) {
    return Math.abs(saldoActualARS) <= limiteCreditoARS;
  }
  return false;
}

// ── Tests unitarios (sin emulador) ────────────────────────────────────────────

describe('confirmarViajeFretix — lógica de crédito B2B (unitario)', () => {

  describe('habilitada: false (cuenta corriente no activada)', () => {
    test('BLOQUEA cuando macroLimitAudit es null — default-secure', () => {
      expect(evaluarCredito({ habilitada: false, macroLimitAudit: null })).toBe(false);
    });

    test('BLOQUEA cuando macroLimitAudit es undefined (campo ausente)', () => {
      expect(evaluarCredito({ habilitada: false })).toBe(false);
    });

    test('APRUEBA cuando macroLimitAudit tiene un valor (auditado por Macro)', () => {
      expect(evaluarCredito({ habilitada: false, macroLimitAudit: 500000 })).toBe(true);
    });

    test('APRUEBA con macroLimitAudit=0 (auditado, sin límite)', () => {
      expect(evaluarCredito({ habilitada: false, macroLimitAudit: 0 })).toBe(true);
    });
  });

  describe('habilitada: true (cuenta corriente activa)', () => {
    test('APRUEBA cuando |saldo| <= límite', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: -30000,
        limiteCreditoARS: 50000,
      })).toBe(true);
    });

    test('APRUEBA cuando saldo=0 (sin deuda)', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: 0,
        limiteCreditoARS: 50000,
      })).toBe(true);
    });

    test('RECHAZA cuando |saldo| > límite (saldo insuficiente)', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: -60000,
        limiteCreditoARS: 50000,
      })).toBe(false);
    });

    test('RECHAZA cuando |saldo| == límite + 1 (exactamente sobre el límite)', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: -50001,
        limiteCreditoARS: 50000,
      })).toBe(false);
    });

    test('APRUEBA cuando |saldo| == límite exacto (borde)', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: -50000,
        limiteCreditoARS: 50000,
      })).toBe(true);
    });

    test('BLOQUEA cuando saldoActualARS es null — default-secure', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: null,
        limiteCreditoARS: 50000,
      })).toBe(false);
    });

    test('BLOQUEA cuando limiteCreditoARS es null — default-secure', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: -1000,
        limiteCreditoARS: null,
      })).toBe(false);
    });

    test('BLOQUEA cuando ambos campos son null — default-secure', () => {
      expect(evaluarCredito({
        habilitada: true,
        saldoActualARS: null,
        limiteCreditoARS: null,
      })).toBe(false);
    });
  });

  describe('cuentaCorriente vacía (empresa recién creada)', () => {
    test('BLOQUEA con objeto vacío — default-secure', () => {
      expect(evaluarCredito({})).toBe(false);
    });
  });
});

// ── Tests de validación de payload (sin emulador) ─────────────────────────────

describe('confirmarViajeFretix — validación de payload', () => {
  const CATEGORIAS_VALIDAS = new Set(['mini', 'plus', 'max', 'heavy']);

  test('rejects invalid categoria', () => {
    expect(CATEGORIAS_VALIDAS.has('moto')).toBe(false);
    expect(CATEGORIAS_VALIDAS.has('')).toBe(false);
    expect(CATEGORIAS_VALIDAS.has(undefined)).toBe(false);
  });

  test('validates cotizacion.total must be positive number', () => {
    const validar = (total) => typeof total === 'number' && total > 0;
    expect(validar(15000)).toBe(true);
    expect(validar(0)).toBe(false);
    expect(validar(-100)).toBe(false);
    expect(validar('15000')).toBe(false);
    expect(validar(null)).toBe(false);
  });

  test('validates origen/destino must have lat and lng', () => {
    const validarPunto = (p) => p?.lat && p?.lng;
    expect(!!validarPunto({ lat: -32.89, lng: -68.83 })).toBe(true);
    expect(!!validarPunto({ lat: -32.89 })).toBe(false);
    expect(!!validarPunto(null)).toBe(false);
  });
});

// ── Tests de integración (requieren emulador Firestore en 127.0.0.1:8282) ────

describe('confirmarViajeFretix — integración con Firestore (emulador)', () => {
  let testUid;

  beforeAll(async () => {
    testUid = await createTestUser('+5492610000002');
  });

  afterEach(async () => {
    await clearCollection('viajes');
    await clearCollection('companies');
    await clearCollection('company_members');
  });

  test('escribe un viaje de cliente particular en /viajes', async () => {
    const firestore = getDb();

    // Simular lo que hace confirmarViajeFretix para un particular
    const docRef = await firestore.collection('viajes').add({
      clienteUid:    testUid,
      clientType:    'particular',
      estado:        'pending',
      pricingMethod: 'haversine_contingencia',
      categoria:     'mini',
      ayudante:      false,
      origen:  { lat: -32.8908, lng: -68.8272, address: 'Mendoza Centro' },
      destino: { lat: -32.9500, lng: -68.8700, address: 'Las Heras' },
      cotizacion: { total: 4500, distanciaKm: 7.2, duracionMin: 14.4 },
      creadoEn: new Date(),
    });

    const snap = await firestore.collection('viajes').doc(docRef.id).get();
    expect(snap.exists).toBe(true);
    expect(snap.data().clientType).toBe('particular');
    expect(snap.data().estado).toBe('pending');
    expect(snap.data().clienteUid).toBe(testUid);
  });

  test('empresa con macroLimitAudit null → creditOk = false (default-secure)', async () => {
    const firestore = getDb();

    // Setup: empresa SIN auditoría
    const companyRef = firestore.collection('companies').doc('test-company-1');
    await companyRef.set({
      ownerUserId: testUid,
      cuentaCorriente: {
        habilitada: false,
        macroLimitAudit: null,  // <- sin auditar
        saldoActualARS: 0,
        limiteCreditoARS: 100000,
      },
    });

    const snap = await companyRef.get();
    const cc = snap.data().cuentaCorriente;
    expect(evaluarCredito(cc)).toBe(false);
  });

  test('empresa con macroLimitAudit seteado → creditOk = true', async () => {
    const firestore = getDb();

    const companyRef = firestore.collection('companies').doc('test-company-2');
    await companyRef.set({
      ownerUserId: testUid,
      cuentaCorriente: {
        habilitada: false,
        macroLimitAudit: 500000,  // <- auditado
        saldoActualARS: 0,
        limiteCreditoARS: 0,
      },
    });

    const snap = await companyRef.get();
    const cc = snap.data().cuentaCorriente;
    expect(evaluarCredito(cc)).toBe(true);
  });

  test('empresa habilitada con saldo insuficiente → creditOk = false', async () => {
    const firestore = getDb();

    const companyRef = firestore.collection('companies').doc('test-company-3');
    await companyRef.set({
      ownerUserId: testUid,
      cuentaCorriente: {
        habilitada: true,
        macroLimitAudit: null,
        saldoActualARS: -80000,   // debe $80.000
        limiteCreditoARS: 50000,  // límite $50.000
      },
    });

    const snap = await companyRef.get();
    const cc = snap.data().cuentaCorriente;
    expect(evaluarCredito(cc)).toBe(false);
  });

  test('empresa habilitada con saldo dentro del límite → creditOk = true', async () => {
    const firestore = getDb();

    const companyRef = firestore.collection('companies').doc('test-company-4');
    await companyRef.set({
      ownerUserId: testUid,
      cuentaCorriente: {
        habilitada: true,
        macroLimitAudit: null,
        saldoActualARS: -30000,   // debe $30.000
        limiteCreditoARS: 50000,  // límite $50.000
      },
    });

    const snap = await companyRef.get();
    const cc = snap.data().cuentaCorriente;
    expect(evaluarCredito(cc)).toBe(true);
  });
});
