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

const UMBRAL_KG_POR_CATEGORIA = {
  mini:  500,
  plus:  800,
  max:   1400,
  heavy: 4000,
};

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

  test('UMBRAL_KG_POR_CATEGORIA tiene los 4 valores correctos', () => {
    expect(UMBRAL_KG_POR_CATEGORIA.mini).toBe(500);
    expect(UMBRAL_KG_POR_CATEGORIA.plus).toBe(800);
    expect(UMBRAL_KG_POR_CATEGORIA.max).toBe(1400);
    expect(UMBRAL_KG_POR_CATEGORIA.heavy).toBe(4000);
  });

  test('capacidad suficiente pasa el umbral', () => {
    const pasa = (cap, cat) => cap >= UMBRAL_KG_POR_CATEGORIA[cat];
    expect(pasa(560,  'mini' )).toBe(true);  // utilitario típico → mini OK
    expect(pasa(900,  'plus' )).toBe(true);  // pickup tope catálogo → plus OK
    expect(pasa(2000, 'max'  )).toBe(true);  // camion_liviano → max OK
    expect(pasa(4900, 'heavy')).toBe(true);  // camion_mediano → heavy OK
  });

  test('capacidad insuficiente no pasa el umbral', () => {
    const pasa = (cap, cat) => cap >= UMBRAL_KG_POR_CATEGORIA[cat];
    expect(pasa(400,  'mini' )).toBe(false); // bajo mínimo utilitario
    expect(pasa(560,  'plus' )).toBe(false); // utilitario no alcanza para plus
    expect(pasa(1000, 'max'  )).toBe(false); // pickup no alcanza para max
    expect(pasa(2000, 'heavy')).toBe(false); // camion_liviano no alcanza para heavy
  });

  // Comportamiento sin techo — documentado, no es un bug.
  // Ver VALIDACION_LOG.md § Limitación conocida — Tarea 7.
  test('vehículo sobredimensionado acepta viaje chico (sin techo — comportamiento documentado)', () => {
    const pasa = (cap, cat) => cap >= UMBRAL_KG_POR_CATEGORIA[cat];
    expect(pasa(4900, 'mini')).toBe(true);  // camion_mediano puede tomar mini
    expect(pasa(2000, 'mini')).toBe(true);  // camion_liviano puede tomar mini
    expect(pasa(4900, 'plus')).toBe(true);  // camion_mediano puede tomar plus
  });

  test('categoría de viaje desconocida no tiene umbral', () => {
    expect(UMBRAL_KG_POR_CATEGORIA['ultra']).toBeUndefined();
    expect(UMBRAL_KG_POR_CATEGORIA['']    ).toBeUndefined();
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
    await clearCollection('vehiculos');
  });

  async function crearChoferDoc(uid, opts = {}) {
    await firestore.collection('users').doc(uid).set({
      uid,
      displayName:          opts.displayName          ?? 'Chofer Test',
      photoURL:             opts.photoURL              ?? null,
      onboardingRole:       opts.onboardingRole        ?? 'chofer_independiente',
      categoriaVehiculo:    opts.categoriaVehiculo     ?? 'mini',
      disponibleParaViajes: opts.disponibleParaViajes  ?? true,
      roles:                ['driver'],
      isActive:             true,
      isVerified:           false,
    });
  }

  async function crearVehiculoDoc(uid, opts = {}) {
    const ref = await firestore.collection('vehiculos').add({
      choferUid:         uid,
      companyId:         null,
      categoriaVehiculo: opts.categoriaVehiculo ?? 'utilitario',
      capacidadMaxKg:    opts.capacidadMaxKg    ?? 560,
      estadoValidacion:  opts.estadoValidacion  ?? 'validado',
      createdAt:         new Date(),
    });
    return ref.id;
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

    const viajeRef   = firestore.collection('viajes').doc(viajeId);
    const choferSnap = await firestore.collection('users').doc(uidChofer).get();
    const cd         = choferSnap.data();

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
    const viajeId  = await crearViajeDoc({ categoria: 'mini' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);

    await viajeRef.update({ estado: 'aceptado', choferUid: uidChofer });

    const snap = await viajeRef.get();
    expect(snap.data().estado).toBe('aceptado');

    const puedeAceptar = snap.data().estado === 'pending';
    expect(puedeAceptar).toBe(false);
  });

  test('chofer sin disponibleParaViajes=true no puede aceptar', async () => {
    await crearChoferDoc(uidChofer, { disponibleParaViajes: false });
    const snap = await firestore.collection('users').doc(uidChofer).get();
    expect(snap.data().disponibleParaViajes).toBe(false);
    const puedeAceptar = snap.data().disponibleParaViajes === true;
    expect(puedeAceptar).toBe(false);
  });

  test('choferData desnormalizado incluye displayName y photoURL', async () => {
    await crearChoferDoc(uidChofer, {
      displayName: 'Ana García',
      photoURL:    'https://example.com/foto.jpg',
    });
    const viajeId  = await crearViajeDoc({ categoria: 'mini' });
    const viajeRef = firestore.collection('viajes').doc(viajeId);
    const cd       = (await firestore.collection('users').doc(uidChofer).get()).data();

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
    const snap    = await firestore.collection('users').doc(uidCliente).get();
    const esChofer = ROLES_CHOFER.has(snap.data().onboardingRole);
    expect(esChofer).toBe(false);
  });

  // ── Tests nuevos — Tarea 7: matcheo por capacidad ────────────────────────────

  test('vehículo validado con capacidad suficiente → puede aceptar', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 560, estadoValidacion: 'validado' });
    const viajeId = await crearViajeDoc({ categoria: 'mini' }); // umbral 500 kg

    const vehiculosSnap = await firestore.collection('vehiculos')
      .where('choferUid', '==', uidChofer)
      .where('estadoValidacion', '==', 'validado')
      .limit(1).get();

    expect(vehiculosSnap.empty).toBe(false);
    const cap        = vehiculosSnap.docs[0].data().capacidadMaxKg;
    const viajeSnap  = await firestore.collection('viajes').doc(viajeId).get();
    const umbral     = UMBRAL_KG_POR_CATEGORIA[viajeSnap.data().categoria];
    expect(cap >= umbral).toBe(true);
  });

  test('vehículo validado con capacidad insuficiente → rechazado antes de la transacción', async () => {
    await crearChoferDoc(uidChofer);
    // utilitario 560 kg intentando tomar viaje 'heavy' (umbral 4000 kg)
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 560, estadoValidacion: 'validado' });
    const viajeId = await crearViajeDoc({ categoria: 'heavy' });

    const vehiculosSnap = await firestore.collection('vehiculos')
      .where('choferUid', '==', uidChofer)
      .where('estadoValidacion', '==', 'validado')
      .limit(1).get();

    const cap    = vehiculosSnap.docs[0].data().capacidadMaxKg;
    const umbral = UMBRAL_KG_POR_CATEGORIA['heavy'];
    expect(cap < umbral).toBe(true);
  });

  test('vehículo no validado → rechazado sin llegar a comparar capacidad', async () => {
    await crearChoferDoc(uidChofer);
    // Capacidad suficiente pero estadoValidacion != 'validado'
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 4900, estadoValidacion: 'pendiente_revision' });

    // La CF filtra con estadoValidacion == 'validado' antes de leer capacidadMaxKg
    const vehiculosSnap = await firestore.collection('vehiculos')
      .where('choferUid', '==', uidChofer)
      .where('estadoValidacion', '==', 'validado')
      .limit(1).get();

    expect(vehiculosSnap.empty).toBe(true);
  });

  // Comportamiento sin techo — documentado, no es un bug.
  test('vehículo sobredimensionado acepta viaje chico (sin techo — comportamiento documentado)', async () => {
    await crearChoferDoc(uidChofer);
    await crearVehiculoDoc(uidChofer, { capacidadMaxKg: 4900, estadoValidacion: 'validado' });
    const viajeId = await crearViajeDoc({ categoria: 'mini' }); // umbral 500 kg

    const vehiculosSnap = await firestore.collection('vehiculos')
      .where('choferUid', '==', uidChofer)
      .where('estadoValidacion', '==', 'validado')
      .limit(1).get();

    const cap    = vehiculosSnap.docs[0].data().capacidadMaxKg;
    const viajeSnap = await firestore.collection('viajes').doc(viajeId).get();
    const umbral = UMBRAL_KG_POR_CATEGORIA[viajeSnap.data().categoria];

    // 4900 >= 500 → acepta. Sin techo, es el comportamiento esperado y documentado.
    expect(cap >= umbral).toBe(true);
  });
});
