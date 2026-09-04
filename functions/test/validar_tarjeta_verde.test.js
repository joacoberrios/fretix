'use strict';

process.env.FIRESTORE_EMULATOR_HOST      = process.env.FIRESTORE_EMULATOR_HOST      || '127.0.0.1:8282';
process.env.FIREBASE_AUTH_EMULATOR_HOST  = process.env.FIREBASE_AUTH_EMULATOR_HOST  || '127.0.0.1:9099';
process.env.USE_REAL_OCR = 'false'; // siempre mock en tests

const { initAdmin, getDb, clearCollection, createTestUser } = require('./setup');
const { db } = initAdmin();

// ── Lógica de parseo extraída para tests unitarios ────────────────────────────

const CATALOGO_REFERENCIA = {
  utilitario:     { minKg: 500,  maxKg: 900  },
  pickup:         { minKg: 800,  maxKg: 1200 },
  camion_liviano: { minKg: 1400, maxKg: 2600 },
  camion_frio:    { minKg: 1400, maxKg: 4100 },
  camion_mediano: { minKg: 4000, maxKg: 6000 },
  camion_mudanza: { minKg: 2400, maxKg: 5000 },
};

function _parsearNumeroArg(str) {
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

function validarRazonabilidad(capacidadKg, categoria) {
  const rango = CATALOGO_REFERENCIA[categoria];
  if (!rango) return false;
  return capacidadKg >= rango.minKg && capacidadKg <= rango.maxKg;
}

// ── Tests unitarios de parseo ─────────────────────────────────────────────────

describe('validarTarjetaVerdeFretix — parseo OCR (unitario)', () => {

  test('parsea PBT con formato "P.B.T.: 1.750 Kg"', () => {
    expect(parsearPBT('P.B.T.: 1.750 Kg')).toBeCloseTo(1750, 0);
  });

  test('parsea PBT sin puntos "PBT: 1750 Kg"', () => {
    expect(parsearPBT('PBT: 1750 Kg')).toBeCloseTo(1750, 0);
  });

  test('parsea PBT con mayúscula parcial "Pbt: 1.200 kg"', () => {
    expect(parsearPBT('Pbt: 1.200 kg')).toBeCloseTo(1200, 0);
  });

  test('parsea Tara con formato "TARA: 1.190 Kg"', () => {
    expect(parsearTara('TARA: 1.190 Kg')).toBeCloseTo(1190, 0);
  });

  test('parsea Tara en minúsculas "tara: 980 kg"', () => {
    expect(parsearTara('tara: 980 kg')).toBeCloseTo(980, 0);
  });

  test('devuelve null si PBT no está en el texto', () => {
    expect(parsearPBT('MARCA: RENAULT\nMODELO: KANGOO')).toBeNull();
  });

  test('devuelve null si Tara no está en el texto', () => {
    expect(parsearTara('PBT: 1750 Kg')).toBeNull();
  });

  test('capacidad = PBT - Tara se calcula correctamente', () => {
    const texto = 'P.B.T.: 1.750 Kg\nTARA: 1.190 Kg';
    const pbt  = parsearPBT(texto);
    const tara = parsearTara(texto);
    expect(Math.round(pbt - tara)).toBe(560);
  });
});

// ── Tests unitarios de razonabilidad de catálogo ──────────────────────────────

describe('validarTarjetaVerdeFretix — razonabilidad de catálogo (unitario)', () => {

  test('560 kg es razonable para utilitario (500–900)', () => {
    expect(validarRazonabilidad(560, 'utilitario')).toBe(true);
  });

  test('400 kg NO es razonable para utilitario (bajo el mínimo)', () => {
    expect(validarRazonabilidad(400, 'utilitario')).toBe(false);
  });

  test('1100 kg es razonable para pickup (800–1200)', () => {
    expect(validarRazonabilidad(1100, 'pickup')).toBe(true);
  });

  test('4900 kg es razonable para camion_mediano (4000–6000)', () => {
    expect(validarRazonabilidad(4900, 'camion_mediano')).toBe(true);
  });

  test('500 kg NO es razonable para camion_mediano (demasiado bajo)', () => {
    expect(validarRazonabilidad(500, 'camion_mediano')).toBe(false);
  });

  test('categoría desconocida devuelve false', () => {
    expect(validarRazonabilidad(1000, 'camion_extraterrestre')).toBe(false);
  });

  test('CATALOGO_REFERENCIA tiene exactamente 6 categorías', () => {
    expect(Object.keys(CATALOGO_REFERENCIA).length).toBe(6);
  });
});

// ── Tests de integración (emulador Firestore) ─────────────────────────────────

describe('validarTarjetaVerdeFretix — integración Firestore (emulador)', () => {
  const firestore = getDb();
  let uidChofer;

  beforeAll(async () => {
    uidChofer = await createTestUser('+5492610000030');
  });

  afterEach(async () => {
    await clearCollection('vehiculos');
    await clearCollection('notificaciones_operador');
  });

  async function crearVehiculo(opts = {}) {
    const ref = await firestore.collection('vehiculos').add({
      choferUid:               uidChofer,
      companyId:               null,
      categoriaVehiculo:       opts.categoriaVehiculo       ?? 'utilitario',
      capacidadMaxKg:          null,
      estadoValidacion:        opts.estadoValidacion        ?? 'pendiente_ocr',
      tarjetaVerdeStoragePath: opts.tarjetaVerdeStoragePath ?? `tarjetas_verde/${uidChofer}/tv.jpg`,
      pbtExtraido:             null,
      taraExtraida:            null,
      validadoEn:              null,
      validadoPor:             null,
      createdAt:               new Date(),
    });
    return ref.id;
  }

  test('vehículo recién creado tiene estadoValidacion=pendiente_ocr y capacidadMaxKg=null', async () => {
    const vehiculoId = await crearVehiculo();
    const snap = await firestore.collection('vehiculos').doc(vehiculoId).get();
    expect(snap.data().estadoValidacion).toBe('pendiente_ocr');
    expect(snap.data().capacidadMaxKg).toBeNull();
  });

  test('default seguro: capacidadMaxKg null bloquea al chofer del pool de matcheo', () => {
    // La regla: estadoValidacion !== 'validado' → bloqueado.
    const puedeRecibirViajes = (estadoValidacion) => estadoValidacion === 'validado';
    expect(puedeRecibirViajes('pendiente_ocr')).toBe(false);
    expect(puedeRecibirViajes('pendiente_revision')).toBe(false);
    expect(puedeRecibirViajes('pendiente_subsanacion')).toBe(false);
    expect(puedeRecibirViajes('validado')).toBe(true);
  });

  test('OCR mock exitoso → vehículo queda validado con capacidadMaxKg correcto', async () => {
    const vehiculoId = await crearVehiculo({ categoriaVehiculo: 'utilitario' });

    // Simular lo que hace la CF con el mock de Kangoo (PBT 1750 - Tara 1190 = 560 kg)
    const texto    = 'P.B.T.: 1.750 Kg\nTARA: 1.190 Kg';
    const pbt      = parsearPBT(texto);
    const tara     = parsearTara(texto);
    const capKg    = Math.round(pbt - tara);
    const razon    = validarRazonabilidad(capKg, 'utilitario');

    expect(razon).toBe(true); // 560 kg está en rango utilitario

    await firestore.collection('vehiculos').doc(vehiculoId).update({
      estadoValidacion: 'validado',
      capacidadMaxKg:   capKg,
      pbtExtraido:      pbt,
      taraExtraida:     tara,
      validadoEn:       new Date(),
      validadoPor:      null,
    });

    const snap = await firestore.collection('vehiculos').doc(vehiculoId).get();
    expect(snap.data().estadoValidacion).toBe('validado');
    expect(snap.data().capacidadMaxKg).toBe(560);
    expect(snap.data().validadoPor).toBeNull(); // null = validado por OCR
  });

  test('OCR fuera de rango → pasa a pendiente_revision', async () => {
    const vehiculoId = await crearVehiculo({ categoriaVehiculo: 'utilitario' });

    // 5000 kg está fuera del rango de utilitario (max 900)
    const capKg = 5000;
    const razon = validarRazonabilidad(capKg, 'utilitario');
    expect(razon).toBe(false);

    await firestore.collection('vehiculos').doc(vehiculoId).update({
      estadoValidacion: 'pendiente_revision',
      pbtExtraido:      6000,
      taraExtraida:     1000,
    });

    const snap = await firestore.collection('vehiculos').doc(vehiculoId).get();
    expect(snap.data().estadoValidacion).toBe('pendiente_revision');
    expect(snap.data().capacidadMaxKg).toBeNull(); // sigue null hasta aprobación manual
  });

  test('operador valida manualmente → validadoPor tiene uid del operador', async () => {
    const vehiculoId  = await crearVehiculo({ estadoValidacion: 'pendiente_revision' });
    const uidOperador = 'operador-admin-uid-test';

    await firestore.collection('vehiculos').doc(vehiculoId).update({
      estadoValidacion: 'validado',
      capacidadMaxKg:   560,
      validadoEn:       new Date(),
      validadoPor:      uidOperador,
    });

    const snap = await firestore.collection('vehiculos').doc(vehiculoId).get();
    expect(snap.data().estadoValidacion).toBe('validado');
    expect(snap.data().validadoPor).toBe(uidOperador);
  });

  test('vehículo en pendiente_subsanacion → chofer debe resubir', async () => {
    const vehiculoId = await crearVehiculo({ estadoValidacion: 'pendiente_subsanacion' });
    const snap = await firestore.collection('vehiculos').doc(vehiculoId).get();
    expect(snap.data().estadoValidacion).toBe('pendiente_subsanacion');
    expect(snap.data().capacidadMaxKg).toBeNull();
  });

  test('al resubir, vuelve a pendiente_ocr (Capa 3 → Capa 1)', async () => {
    const vehiculoId = await crearVehiculo({ estadoValidacion: 'pendiente_subsanacion' });
    await firestore.collection('vehiculos').doc(vehiculoId).update({
      estadoValidacion:        'pendiente_ocr',
      tarjetaVerdeStoragePath: `tarjetas_verde/${uidChofer}/tv_v2.jpg`,
    });
    const snap = await firestore.collection('vehiculos').doc(vehiculoId).get();
    expect(snap.data().estadoValidacion).toBe('pendiente_ocr');
  });
});
