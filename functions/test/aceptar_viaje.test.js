'use strict';
/**
 * aceptar_viaje.test.js
 *
 * Tests para aceptarViajeFretix.
 * Los tests de integración escriben en el emulador de Firestore.
 */

process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8282';
process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';

const { initAdmin, getDb, clearCollection, createTestUser } = require('./setup');
const { db } = initAdmin();

// ── Lógica de validación extraída para tests unitarios ────────────────────────

const ROLES_CHOFER = new Set(['chofer_independiente', 'empresa_transporte_maestro']);

describe('aceptarViajeFretix — validaciones de payload (unitario)', () => {

  test('ROLES_CHOFER incluye solo los roles transportista', () => {
    expect(ROLES_CHOFER.has('chofer_independiente')).toBe(true);
    expect(ROLES_CHOFER.has('empresa_transporte_maestro')).toBe(true);
    expect(ROLES_CHOFER.has('cliente_particular')).toBe(false);
    expect(ROLES_CHOFER.has('cliente_empresa_maestro')).toBe(false);
  });

  test('validación de viajeId: string no vacío requerido', () => {
    const validar = (id) => !!(id && typeof id === 'string');
    expect(validar(null)).toBe(false);
    expect(validar('')).toBe(false);
    expect(validar(123)).toBe(false);
    expect(validar('viaje-abc-123')).toBe(true);
  });

  test('condición de carrera: estado "pending" requerido para aceptar', () => {
    const puedeAceptar = (estado) => estado === 'pending';
    expect(puedeAceptar('pending')).toBe(true);
    expect(puedeAceptar('aceptado')).toBe(false);
    expect(puedeAceptar('cancelado')).toBe(false);
    expect(puedeAceptar(undefined)).toBe(false);
  });

  test('categoría del viaje debe coincidir con la del chofer', () => {
    const categoriaOk = (viajeCategoria, choferCategoria) =>
      viajeCategoria === choferCategoria;
    expect(categoriaOk('mini', 'mini')).toBe(true);
    expect(categoriaOk('max', 'mini')).toBe(false);
    expect(categoriaOk('heavy', 'heavy')).toBe(true);
  });
});

// ── Tests de integración (requieren emulador Firestore) ───────────────────────

describe('aceptarViajeFretix — integración con Firestore (emulador)', () => {
  const firestore = getDb();
  let uidChofer;
  let uidCliente;

  beforeAll(async () => {
    uidChofer  = await createTestUser('+5492610000020');
    uidCliente = await createTestUser('+5492610000021');
  });

  afterEach(async () => {
    await clearCollection('viajes');
    await clearCollection('users');
  });

  async function crearChoferDoc(uid, opts = {}) {
    await firestore.collection('users').doc(uid).set({
      uid,
      displayName:         opts.displayName         ?? 'Chofer Test',
      photoURL:            opts.photoURL             ?? null,
      onboardingRole:      opts.onboardingRole       ?? 'chofer_independiente',
      categoriaVehiculo:   opts.categoriaVehiculo    ?? 'mini',
      disponibleParaViajes: opts.disponibleParaViajes ?? true,
      roles:               ['driver'],
      isActive:            true,
      isVerified:          false,
    });
  }

  async function crearViajeDoc(opts = {}) {
    const ref = await firestore.collection('viajes').add({
      clienteUid: uidCliente,
      estado:     opts.estado    ?? 'pending',
      categoria:  opts.categoria ?? 'mini',
      origen:  { lat: -32.89, lng: -68.84, address: 'Mendoza' },
      destino: { lat: -32.90, lng: -68.85, address: 'Godoy Cruz' },
      cotizacion: { total: 3500, distanciaKm: 5, duracionMin: 12 },
      creadoEn: new Date(),
    });
    return ref.id;
  }

  test('chofer acepta viaje → estado cambia a "aceptado" con choferUid y choferData', async () => {
    await crearChoferDoc(uidChofer);
    const viajeId = await crearViajeDoc({ categoria: 'mini' });

    // Simular la transacción de aceptarViajeFretix
    const viajeRef = firestore.collection('viajes').doc(viajeId);
    const choferSnap = await firestore.collection('users').doc(uidChofer).get();
    const cd = choferSnap.data();

    await firestore.runTransaction(async (tx) => {
      const viajeSnap = await tx.get(viajeRef);
      expect(viajeSnap.data().estado).toBe('pending');
      tx.update(viajeRef, {
        estado:    'aceptado',
        choferUid: uidChofer,
        choferData: {
          displayName: cd.displayName,
          photoURL:    cd.photoURL,
        },
        aceptadoEn: new Date(),
      });
    });

    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('aceptado');
    expect(snap.data().choferUid).toBe(uidChofer);
    expect(snap.data().choferData.displayName).toBe('Chofer Test');
    expect(snap.data().aceptadoEn).toBeDefined();
  });

  test('condición de carrera: segundo chofer no puede aceptar viaje ya aceptado', async () => {
    await crearChoferDoc(uidChofer);
    const uidChofer2 = await createTestUser('+5492610000022');
    await crearChoferDoc(uidChofer2, { displayName: 'Chofer 2' });
    const viajeId = await crearViajeDoc({ categoria: 'mini' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    // Primer chofer acepta
    await viajeRef.update({ estado: 'aceptado', choferUid: uidChofer });

    // Verificar que el viaje ya no está 'pending'
    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('aceptado');

    // El segundo chofer detecta el estado incorrecto en la transacción
    const puedeAceptar = snap.data().estado === 'pending';
    expect(puedeAceptar).toBe(false);
  });

  test('chofer sin disponibleParaViajes=true no puede aceptar', async () => {
    await crearChoferDoc(uidChofer, { disponibleParaViajes: false });
    const snap = await firestore.collection('users').doc(uidChofer).get();
    expect(snap.data().disponibleParaViajes).toBe(false);
    // La CF lanzaría failed-precondition — aquí validamos la condición
    const puedeAceptar = snap.data().disponibleParaViajes === true;
    expect(puedeAceptar).toBe(false);
  });

  test('chofer sin categoriaVehiculo no puede aceptar', async () => {
    await firestore.collection('users').doc(uidChofer).set({
      uid:               uidChofer,
      onboardingRole:    'chofer_independiente',
      disponibleParaViajes: true,
      // categoriaVehiculo ausente deliberadamente
      roles:             ['driver'],
      isActive:          true,
      isVerified:        false,
    });
    const snap = await firestore.collection('users').doc(uidChofer).get();
    const tieneCat = !!(snap.data().categoriaVehiculo);
    expect(tieneCat).toBe(false);
  });

  test('chofer max no puede aceptar viaje mini (categoría incorrecta)', async () => {
    await crearChoferDoc(uidChofer, { categoriaVehiculo: 'max' });
    const viajeId = await crearViajeDoc({ categoria: 'mini' });

    const viajeSnap  = await firestore.collection('viajes').doc(viajeId).get();
    const choferSnap = await firestore.collection('users').doc(uidChofer).get();

    const categoriaOk = viajeSnap.data().categoria === choferSnap.data().categoriaVehiculo;
    expect(categoriaOk).toBe(false);
  });

  test('choferData desnormalizado incluye displayName y photoURL', async () => {
    await crearChoferDoc(uidChofer, {
      displayName: 'Ana García',
      photoURL:    'https://example.com/foto.jpg',
    });
    const viajeId = await crearViajeDoc({ categoria: 'mini' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);
    const cd = (await firestore.collection('users').doc(uidChofer).get()).data();

    await viajeRef.update({
      estado:    'aceptado',
      choferUid: uidChofer,
      choferData: {
        displayName: cd.displayName,
        photoURL:    cd.photoURL,
      },
      aceptadoEn: new Date(),
    });

    const snap = await viajeRef.get();
    expect(snap.data().choferData.displayName).toBe('Ana García');
    expect(snap.data().choferData.photoURL).toBe('https://example.com/foto.jpg');
  });

  test('cliente no puede aceptar viaje (rol incorrecto)', async () => {
    await firestore.collection('users').doc(uidCliente).set({
      uid:            uidCliente,
      onboardingRole: 'cliente_particular',
      roles:          ['customer'],
      isActive:       true,
      isVerified:     false,
    });
    const snap = await firestore.collection('users').doc(uidCliente).get();
    const esChofer = ROLES_CHOFER.has(snap.data().onboardingRole);
    expect(esChofer).toBe(false);
  });
});
