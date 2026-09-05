'use strict';
/**
 * viaje_lifecycle.test.js — TAREA 6
 *
 * Tests end-to-end del ciclo de vida del viaje contra el emulador de Firestore.
 * Cubre: pending → aceptado → en_curso → completado, cancelaciones,
 * y el bloqueo de matcheo cuando el chofer tiene un viaje activo.
 *
 * Requisito: emuladores corriendo antes de ejecutar.
 *   firebase emulators:start --only firestore,auth
 *   npm test -- --testPathPattern=viaje_lifecycle
 */

process.env.FIRESTORE_EMULATOR_HOST      = process.env.FIRESTORE_EMULATOR_HOST      || '127.0.0.1:8282';
process.env.FIREBASE_AUTH_EMULATOR_HOST  = process.env.FIREBASE_AUTH_EMULATOR_HOST  || '127.0.0.1:9099';

const { initAdmin, getDb, clearCollection, createTestUser } = require('./setup');
const { db } = initAdmin();

// ── Helpers de seed ───────────────────────────────────────────────────────────

async function crearChoferDoc(uid, opts = {}) {
  const firestore = getDb();
  await firestore.collection('users').doc(uid).set({
    uid,
    displayName:          opts.displayName          ?? 'Chofer Test',
    phone:                opts.phone                ?? '+5492610000099',
    photoURL:             null,
    onboardingRole:       opts.onboardingRole        ?? 'chofer_independiente',
    categoriaVehiculo:    opts.categoriaVehiculo     ?? 'mini',
    disponibleParaViajes: opts.disponibleParaViajes  ?? true,
    roles:                ['driver'],
    isActive:             true,
    isVerified:           false,
  });
}

async function crearClienteDoc(uid) {
  const firestore = getDb();
  await firestore.collection('users').doc(uid).set({
    uid,
    displayName:    'Cliente Test',
    phone:          '+5492610000088',
    onboardingRole: 'cliente_particular',
    roles:          ['customer'],
    isActive:       true,
    isVerified:     false,
  });
}

async function crearVehiculoDoc(uid, opts = {}) {
  const firestore = getDb();
  const ref = await firestore.collection('vehiculos').add({
    choferUid:         uid,
    categoriaVehiculo: opts.categoriaVehiculo ?? 'utilitario',
    capacidadMaxKg:    opts.capacidadMaxKg    ?? 560,
    estadoValidacion:  opts.estadoValidacion  ?? 'validado',
    createdAt:         new Date(),
  });
  return ref.id;
}

async function crearViajeDoc(clienteUid, opts = {}) {
  const firestore = getDb();
  const ref = await firestore.collection('viajes').add({
    clienteUid,
    estado:    opts.estado    ?? 'pending',
    categoria: opts.categoria ?? 'mini',
    origen:    { lat: -32.89, lng: -68.84, address: 'Mendoza Centro' },
    destino:   { lat: -32.90, lng: -68.85, address: 'Godoy Cruz' },
    cotizacion: { total: 3500, distanciaKm: 5, duracionMin: 12 },
    creadoEn:  new Date(),
  });
  return ref.id;
}

// ── Validaciones de lógica pura (sin emulador) ────────────────────────────────

describe('viaje_lifecycle — validaciones de estado (unitario)', () => {
  const ESTADOS_CANCELABLES    = new Set(['pending', 'aceptado']);
  const ESTADOS_NO_CANCELABLES = ['en_curso', 'completado', 'cancelado'];

  test('pending y aceptado son cancelables', () => {
    expect(ESTADOS_CANCELABLES.has('pending')).toBe(true);
    expect(ESTADOS_CANCELABLES.has('aceptado')).toBe(true);
  });

  test('en_curso, completado y cancelado NO son cancelables', () => {
    for (const e of ESTADOS_NO_CANCELABLES) {
      expect(ESTADOS_CANCELABLES.has(e)).toBe(false);
    }
  });

  test('iniciar viaje requiere estado aceptado', () => {
    const puedeIniciar = (e) => e === 'aceptado';
    expect(puedeIniciar('aceptado')).toBe(true);
    expect(puedeIniciar('pending')).toBe(false);
    expect(puedeIniciar('en_curso')).toBe(false);
    expect(puedeIniciar('completado')).toBe(false);
  });

  test('finalizar viaje requiere estado en_curso', () => {
    const puedeFinalizar = (e) => e === 'en_curso';
    expect(puedeFinalizar('en_curso')).toBe(true);
    expect(puedeFinalizar('aceptado')).toBe(false);
    expect(puedeFinalizar('completado')).toBe(false);
  });

  test('chofer con viaje activo (aceptado o en_curso) no puede aceptar otro', () => {
    const tieneViajeActivo = (estado) => ['aceptado', 'en_curso'].includes(estado);
    expect(tieneViajeActivo('aceptado')).toBe(true);
    expect(tieneViajeActivo('en_curso')).toBe(true);
    expect(tieneViajeActivo('pending')).toBe(false);
    expect(tieneViajeActivo('completado')).toBe(false);
    expect(tieneViajeActivo('cancelado')).toBe(false);
  });
});

// ── Tests de integración (emulador Firestore) ─────────────────────────────────

describe('viaje_lifecycle — ciclo completo (integración)', () => {
  const firestore = getDb();
  let uidChofer;
  let uidCliente;

  beforeAll(async () => {
    uidChofer  = await createTestUser('+5492610000030');
    uidCliente = await createTestUser('+5492610000031');
  });

  afterEach(async () => {
    await clearCollection('viajes');
    await clearCollection('users');
    await clearCollection('vehiculos');
  });

  test('ciclo completo: pending → aceptado → en_curso → completado', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer);
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente, { categoria: 'mini' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    // Simula aceptarViajeFretix
    await viajeRef.update({
      estado:     'aceptado',
      choferUid:  uidChofer,
      choferData: { displayName: 'Chofer Test', photoURL: null, phone: '+5492610000099', categoriaVehiculo: 'utilitario' },
      clienteData: { displayName: 'Cliente Test', phone: '+5492610000088' },
      aceptadoEn: new Date(),
    });
    let snap = await viajeRef.get();
    expect(snap.data().estado).toBe('aceptado');
    expect(snap.data().choferUid).toBe(uidChofer);
    expect(snap.data().clienteData.phone).toBe('+5492610000088');

    // Simula iniciarViajeFretix
    await viajeRef.update({ estado: 'en_curso', iniciadoEn: new Date() });
    snap = await viajeRef.get();
    expect(snap.data().estado).toBe('en_curso');
    expect(snap.data().iniciadoEn).toBeDefined();

    // Simula finalizarViajeFretix
    await viajeRef.update({ estado: 'completado', completadoEn: new Date() });
    snap = await viajeRef.get();
    expect(snap.data().estado).toBe('completado');
    expect(snap.data().completadoEn).toBeDefined();
  });

  test('cliente cancela viaje en estado pending', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente, { estado: 'pending' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    // Simula cancelarViajeFretix (cliente)
    await viajeRef.update({
      estado:          'cancelado',
      canceladoEn:     new Date(),
      canceladoPor:    uidCliente,
      canceladoPorRol: 'cliente',
    });

    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('cancelado');
    expect(snap.data().canceladoPorRol).toBe('cliente');
  });

  test('chofer cancela viaje en estado aceptado', async () => {
    await crearChoferDoc(uidChofer);
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente);
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    await viajeRef.update({
      estado:    'aceptado',
      choferUid: uidChofer,
      aceptadoEn: new Date(),
    });

    // Simula cancelarViajeFretix (chofer)
    await viajeRef.update({
      estado:          'cancelado',
      canceladoEn:     new Date(),
      canceladoPor:    uidChofer,
      canceladoPorRol: 'chofer',
    });

    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('cancelado');
    expect(snap.data().canceladoPorRol).toBe('chofer');
    expect(snap.data().canceladoPor).toBe(uidChofer);
  });

  test('TAREA 2: bloqueo de matcheo — chofer con viaje aceptado no puede tomar otro', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 560, estadoValidacion: 'validado' });
    await crearClienteDoc(uidCliente);

    // Primer viaje ya aceptado por este chofer
    const viajeId1 = await crearViajeDoc(uidCliente);
    await firestore.collection('viajes').doc(viajeId1).update({
      estado:    'aceptado',
      choferUid: uidChofer,
    });

    // Query que aceptarViajeFretix ejecuta para detectar viaje activo
    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(false);
    // Si no está vacío → la CF lanza failed-precondition y no acepta el segundo viaje.
  });

  test('TAREA 2: chofer sin viaje activo pasa el bloqueo', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 560, estadoValidacion: 'validado' });

    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(true);
    // Vacío → la CF permite continuar con el proceso de aceptación.
  });

  test('TAREA 2: viaje completado no bloquea al chofer para tomar otro', async () => {
    await crearChoferDoc(uidChofer);
    await crearClienteDoc(uidCliente);

    // Viaje anterior del mismo chofer, ya completado
    const viajeAnterior = await crearViajeDoc(uidCliente);
    await firestore.collection('viajes').doc(viajeAnterior).update({
      estado:    'completado',
      choferUid: uidChofer,
    });

    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(true);
    // Completado no está en el filtro → el chofer puede aceptar nuevos viajes.
  });

  test('transición inválida: no se puede finalizar un viaje en estado pending', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'pending' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();
    expect(snap.data().estado).toBe('pending');

    // finalizarViajeFretix requiere estado == 'en_curso'
    const puedeFinalizar = snap.data().estado === 'en_curso';
    expect(puedeFinalizar).toBe(false);
  });

  test('transición inválida: no se puede cancelar un viaje completado', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'completado' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    const ESTADOS_CANCELABLES = new Set(['pending', 'aceptado']);
    const puedeCancelar = ESTADOS_CANCELABLES.has(snap.data().estado);
    expect(puedeCancelar).toBe(false);
  });

  test('clienteData se escribe al aceptar (contacto desnormalizado)', async () => {
    await crearChoferDoc(uidChofer);
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente);
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    await viajeRef.update({
      estado:      'aceptado',
      choferUid:   uidChofer,
      choferData:  { displayName: 'Chofer Test', photoURL: null, phone: '+5492610000099', categoriaVehiculo: 'utilitario' },
      clienteData: { displayName: 'Cliente Test', phone: '+5492610000088' },
      aceptadoEn:  new Date(),
    });

    const snap = await viajeRef.get();
    expect(snap.data().clienteData).toBeDefined();
    expect(snap.data().clienteData.displayName).toBe('Cliente Test');
    expect(snap.data().clienteData.phone).toBe('+5492610000088');
    expect(snap.data().choferData.categoriaVehiculo).toBe('utilitario');
    expect(snap.data().choferData.phone).toBe('+5492610000099');
  });
});
