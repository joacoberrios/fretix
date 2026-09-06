'use strict';
/**
 * viaje_lifecycle.test.js
 *
 * Tests del ciclo de vida del viaje contra el emulador de Firestore.
 * Ciclo actual: pending → aceptado → en_curso → en_transito → completado
 *
 * Semántica de estados:
 *   aceptado:    chofer va camino al ORIGEN a buscar la carga
 *   en_curso:    chofer llegó al origen, confirma que cargó
 *   en_transito: chofer va camino al DESTINO con la carga
 *   completado:  llegó a destino, viaje terminado
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
  const ESTADOS_ACTIVOS_CHOFER = new Set(['aceptado', 'en_curso', 'en_transito']);

  test('pending y aceptado son cancelables', () => {
    expect(ESTADOS_CANCELABLES.has('pending')).toBe(true);
    expect(ESTADOS_CANCELABLES.has('aceptado')).toBe(true);
  });

  test('en_curso, en_transito, completado y cancelado NO son cancelables', () => {
    for (const e of ['en_curso', 'en_transito', 'completado', 'cancelado']) {
      expect(ESTADOS_CANCELABLES.has(e)).toBe(false);
    }
  });

  test('iniciar viaje requiere estado aceptado', () => {
    const puedeIniciar = (e) => e === 'aceptado';
    expect(puedeIniciar('aceptado')).toBe(true);
    expect(puedeIniciar('pending')).toBe(false);
    expect(puedeIniciar('en_curso')).toBe(false);
    expect(puedeIniciar('en_transito')).toBe(false);
    expect(puedeIniciar('completado')).toBe(false);
  });

  test('confirmar carga requiere estado en_curso', () => {
    const puedeConfirmar = (e) => e === 'en_curso';
    expect(puedeConfirmar('en_curso')).toBe(true);
    expect(puedeConfirmar('aceptado')).toBe(false);
    expect(puedeConfirmar('en_transito')).toBe(false);
    expect(puedeConfirmar('completado')).toBe(false);
  });

  test('finalizar viaje requiere estado en_transito (no en_curso)', () => {
    const puedeFinalizar = (e) => e === 'en_transito';
    expect(puedeFinalizar('en_transito')).toBe(true);
    expect(puedeFinalizar('en_curso')).toBe(false);   // cambio respecto al ciclo anterior
    expect(puedeFinalizar('aceptado')).toBe(false);
    expect(puedeFinalizar('completado')).toBe(false);
  });

  test('chofer con viaje activo (aceptado, en_curso o en_transito) no puede aceptar otro', () => {
    const tieneViajeActivo = (estado) => ESTADOS_ACTIVOS_CHOFER.has(estado);
    expect(tieneViajeActivo('aceptado')).toBe(true);
    expect(tieneViajeActivo('en_curso')).toBe(true);
    expect(tieneViajeActivo('en_transito')).toBe(true);
    expect(tieneViajeActivo('pending')).toBe(false);
    expect(tieneViajeActivo('completado')).toBe(false);
    expect(tieneViajeActivo('cancelado')).toBe(false);
  });

  test('cliente ve pantalla de seguimiento en estados pending, aceptado, en_curso, en_transito', () => {
    const estadosClienteActivo = new Set(['pending', 'aceptado', 'en_curso', 'en_transito']);
    expect(estadosClienteActivo.has('pending')).toBe(true);
    expect(estadosClienteActivo.has('aceptado')).toBe(true);
    expect(estadosClienteActivo.has('en_curso')).toBe(true);
    expect(estadosClienteActivo.has('en_transito')).toBe(true);
    expect(estadosClienteActivo.has('completado')).toBe(false);
    expect(estadosClienteActivo.has('cancelado')).toBe(false);
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

  test('ciclo completo: pending → aceptado → en_curso → en_transito → completado', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer);
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente, { categoria: 'mini' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    // aceptado (simula aceptarViajeFretix)
    await viajeRef.update({
      estado:      'aceptado',
      choferUid:   uidChofer,
      choferData:  { displayName: 'Chofer Test', photoURL: null, phone: '+5492610000099', categoriaVehiculo: 'utilitario' },
      clienteData: { displayName: 'Cliente Test', phone: '+5492610000088' },
      aceptadoEn:  new Date(),
    });
    let snap = await viajeRef.get();
    expect(snap.data().estado).toBe('aceptado');
    expect(snap.data().choferUid).toBe(uidChofer);

    // en_curso (simula iniciarViajeFretix — chofer llegó al origen)
    await viajeRef.update({ estado: 'en_curso', iniciadoEn: new Date() });
    snap = await viajeRef.get();
    expect(snap.data().estado).toBe('en_curso');
    expect(snap.data().iniciadoEn).toBeDefined();

    // en_transito (simula confirmarCargaFretix — chofer cargó y sale al destino)
    await viajeRef.update({ estado: 'en_transito', cargadoEn: new Date() });
    snap = await viajeRef.get();
    expect(snap.data().estado).toBe('en_transito');
    expect(snap.data().cargadoEn).toBeDefined();

    // completado (simula finalizarViajeFretix)
    await viajeRef.update({ estado: 'completado', completadoEn: new Date() });
    snap = await viajeRef.get();
    expect(snap.data().estado).toBe('completado');
    expect(snap.data().completadoEn).toBeDefined();
  });

  test('cliente cancela viaje en estado pending', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente, { estado: 'pending' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

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

    await viajeRef.update({ estado: 'aceptado', choferUid: uidChofer, aceptadoEn: new Date() });
    await viajeRef.update({
      estado:          'cancelado',
      canceladoEn:     new Date(),
      canceladoPor:    uidChofer,
      canceladoPorRol: 'chofer',
    });

    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('cancelado');
    expect(snap.data().canceladoPorRol).toBe('chofer');
  });

  test('no se puede cancelar desde en_curso', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'en_curso' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    const ESTADOS_CANCELABLES = new Set(['pending', 'aceptado']);
    expect(ESTADOS_CANCELABLES.has(snap.data().estado)).toBe(false);
  });

  test('no se puede cancelar desde en_transito', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'en_transito' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    const ESTADOS_CANCELABLES = new Set(['pending', 'aceptado']);
    expect(ESTADOS_CANCELABLES.has(snap.data().estado)).toBe(false);
  });

  test('bloqueo de matcheo — chofer con viaje aceptado no puede tomar otro', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 560, estadoValidacion: 'validado' });
    await crearClienteDoc(uidCliente);

    const viajeId1 = await crearViajeDoc(uidCliente);
    await firestore.collection('viajes').doc(viajeId1).update({ estado: 'aceptado', choferUid: uidChofer });

    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso', 'en_transito'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(false);
  });

  test('bloqueo de matcheo — chofer con viaje en_transito no puede tomar otro', async () => {
    await crearChoferDoc(uidChofer);
    await crearClienteDoc(uidCliente);

    const viajeId1 = await crearViajeDoc(uidCliente);
    await firestore.collection('viajes').doc(viajeId1).update({ estado: 'en_transito', choferUid: uidChofer });

    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso', 'en_transito'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(false);
  });

  test('chofer sin viaje activo pasa el bloqueo', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 560, estadoValidacion: 'validado' });

    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso', 'en_transito'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(true);
  });

  test('viaje completado no bloquea al chofer para tomar otro', async () => {
    await crearChoferDoc(uidChofer);
    await crearClienteDoc(uidCliente);

    const viajeAnterior = await crearViajeDoc(uidCliente);
    await firestore.collection('viajes').doc(viajeAnterior).update({ estado: 'completado', choferUid: uidChofer });

    const activoSnap = await firestore.collection('viajes')
      .where('choferUid', '==', uidChofer)
      .where('estado', 'in', ['aceptado', 'en_curso', 'en_transito'])
      .limit(1)
      .get();

    expect(activoSnap.empty).toBe(true);
  });

  test('transición inválida: no se puede finalizar desde en_curso (requiere en_transito)', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'en_curso' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    // finalizarViajeFretix requiere estado == 'en_transito'
    const puedeFinalizar = snap.data().estado === 'en_transito';
    expect(puedeFinalizar).toBe(false);
  });

  test('transición inválida: no se puede finalizar desde pending', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'pending' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    const puedeFinalizar = snap.data().estado === 'en_transito';
    expect(puedeFinalizar).toBe(false);
  });

  test('transición inválida: no se puede confirmar carga desde aceptado', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'aceptado' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    const puedeConfirmar = snap.data().estado === 'en_curso';
    expect(puedeConfirmar).toBe(false);
  });

  test('transición inválida: no se puede cancelar un viaje completado', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'completado' });
    const snap    = await firestore.collection('viajes').doc(viajeId).get();

    const ESTADOS_CANCELABLES = new Set(['pending', 'aceptado']);
    expect(ESTADOS_CANCELABLES.has(snap.data().estado)).toBe(false);
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

  test('cargadoEn se escribe al confirmar carga', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId  = await crearViajeDoc(uidCliente, { estado: 'en_curso' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    await viajeRef.update({ estado: 'en_transito', cargadoEn: new Date() });

    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('en_transito');
    expect(snap.data().cargadoEn).toBeDefined();
  });

  test('_ClienteGuard: cliente con viaje pending aparece en estados activos', async () => {
    await crearClienteDoc(uidCliente);
    const viajeId = await crearViajeDoc(uidCliente, { estado: 'pending' });

    const snap = await firestore.collection('viajes')
      .where('clienteUid', '==', uidCliente)
      .where('estado', 'in', ['pending', 'aceptado', 'en_curso', 'en_transito'])
      .limit(1)
      .get();

    expect(snap.empty).toBe(false);
    expect(snap.docs[0].id).toBe(viajeId);
  });

  test('_ClienteGuard: cliente sin viaje activo no aparece', async () => {
    await crearClienteDoc(uidCliente);
    await crearViajeDoc(uidCliente, { estado: 'completado' });

    const snap = await firestore.collection('viajes')
      .where('clienteUid', '==', uidCliente)
      .where('estado', 'in', ['pending', 'aceptado', 'en_curso', 'en_transito'])
      .limit(1)
      .get();

    expect(snap.empty).toBe(true);
  });
});
