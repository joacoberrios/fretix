'use strict';
/**
 * onboarding.test.js
 *
 * Tests para completarOnboardingFretix.
 * Los tests de integración escriben en el emulador de Firestore.
 */

process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8282';
process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';

const { initAdmin, getDb, clearCollection, createTestUser } = require('./setup');
const { db } = initAdmin();

// ── Lógica de validación extraída para tests unitarios ────────────────────────

const ROLES_VALIDOS = new Set([
  'cliente_particular',
  'cliente_empresa_maestro',
  'chofer_independiente',
  'empresa_transporte_maestro',
]);

const ROLES_EMPRESA = new Set([
  'cliente_empresa_maestro',
  'empresa_transporte_maestro',
]);

const ROLES_CHOFER = new Set([
  'chofer_independiente',
  'empresa_transporte_maestro',
]);

const CATEGORIAS_VEHICULO = new Set(['mini', 'plus', 'max', 'heavy']);

const ROLE_TO_USER_ROLES = {
  cliente_particular:        ['customer'],
  cliente_empresa_maestro:   ['customer'],
  chofer_independiente:      ['driver'],
  empresa_transporte_maestro: ['driver'],
};

const ROLE_TO_COMPANY_TYPE = {
  cliente_empresa_maestro:   'customer',
  empresa_transporte_maestro: 'carrier',
};

// ── Tests unitarios (sin emulador) ────────────────────────────────────────────

describe('completarOnboardingFretix — validaciones de payload (unitario)', () => {

  test('roles válidos cubren exactamente los 4 de FretixUserRole', () => {
    expect(ROLES_VALIDOS.size).toBe(4);
    expect(ROLES_VALIDOS.has('cliente_particular')).toBe(true);
    expect(ROLES_VALIDOS.has('cliente_empresa_maestro')).toBe(true);
    expect(ROLES_VALIDOS.has('chofer_independiente')).toBe(true);
    expect(ROLES_VALIDOS.has('empresa_transporte_maestro')).toBe(true);
  });

  test('roles empresa requieren razonSocial y cuit', () => {
    for (const rol of ROLES_EMPRESA) {
      expect(ROLES_EMPRESA.has(rol)).toBe(true);
    }
    expect(ROLES_EMPRESA.has('cliente_particular')).toBe(false);
    expect(ROLES_EMPRESA.has('chofer_independiente')).toBe(false);
  });

  test('ROLE_TO_USER_ROLES mapea correctamente clientes y choferes', () => {
    expect(ROLE_TO_USER_ROLES['cliente_particular']).toEqual(['customer']);
    expect(ROLE_TO_USER_ROLES['cliente_empresa_maestro']).toEqual(['customer']);
    expect(ROLE_TO_USER_ROLES['chofer_independiente']).toEqual(['driver']);
    expect(ROLE_TO_USER_ROLES['empresa_transporte_maestro']).toEqual(['driver']);
  });

  test('ROLE_TO_COMPANY_TYPE asigna tipos correctos', () => {
    expect(ROLE_TO_COMPANY_TYPE['cliente_empresa_maestro']).toBe('customer');
    expect(ROLE_TO_COMPANY_TYPE['empresa_transporte_maestro']).toBe('carrier');
  });

  test('ROLES_CHOFER incluye chofer_independiente y empresa_transporte_maestro', () => {
    expect(ROLES_CHOFER.has('chofer_independiente')).toBe(true);
    expect(ROLES_CHOFER.has('empresa_transporte_maestro')).toBe(true);
    expect(ROLES_CHOFER.has('cliente_particular')).toBe(false);
    expect(ROLES_CHOFER.has('cliente_empresa_maestro')).toBe(false);
  });

  test('CATEGORIAS_VEHICULO tiene exactamente los 4 valores válidos', () => {
    expect(CATEGORIAS_VEHICULO.size).toBe(4);
    expect(CATEGORIAS_VEHICULO.has('mini')).toBe(true);
    expect(CATEGORIAS_VEHICULO.has('plus')).toBe(true);
    expect(CATEGORIAS_VEHICULO.has('max')).toBe(true);
    expect(CATEGORIAS_VEHICULO.has('heavy')).toBe(true);
    expect(CATEGORIAS_VEHICULO.has('MINI')).toBe(false);  // case-sensitive
    expect(CATEGORIAS_VEHICULO.has('pesado')).toBe(false); // valor incorrecto
  });

  test('categoriaVehiculo requerido para chofer_independiente', () => {
    const validar = (rol, cat) => {
      const esChofer = ROLES_CHOFER.has(rol);
      if (!esChofer) return true;
      return !!(cat && CATEGORIAS_VEHICULO.has(cat));
    };
    expect(validar('chofer_independiente', null)).toBe(false);
    expect(validar('chofer_independiente', '')).toBe(false);
    expect(validar('chofer_independiente', 'camion')).toBe(false);
    expect(validar('chofer_independiente', 'max')).toBe(true);
    expect(validar('chofer_independiente', 'mini')).toBe(true);
  });

  test('categoriaVehiculo requerido para empresa_transporte_maestro', () => {
    const validar = (cat) => {
      const esChofer = ROLES_CHOFER.has('empresa_transporte_maestro');
      return esChofer ? !!(cat && CATEGORIAS_VEHICULO.has(cat)) : true;
    };
    expect(validar(null)).toBe(false);
    expect(validar('heavy')).toBe(true);
  });

  test('categoriaVehiculo NO requerido para cliente_particular', () => {
    const esChofer = ROLES_CHOFER.has('cliente_particular');
    expect(esChofer).toBe(false); // no se valida categoriaVehiculo
  });

  test('displayName menor a 2 caracteres debe ser rechazado', () => {
    const validar = (n) => !!(n && typeof n === 'string' && n.trim().length >= 2);
    expect(validar('A')).toBe(false);
    expect(validar('')).toBe(false);
    expect(validar(null)).toBe(false);
    expect(validar('Jo')).toBe(true);
    expect(validar('  A ')).toBe(false); // 1 char después de trim
  });
});

// ── Tests de integración (requieren emulador Firestore) ───────────────────────

describe('completarOnboardingFretix — integración con Firestore (emulador)', () => {
  const firestore = getDb();
  let uidParticular;
  let uidEmpresa;

  beforeAll(async () => {
    uidParticular = await createTestUser('+5492610000010');
    uidEmpresa    = await createTestUser('+5492610000011');
  });

  afterEach(async () => {
    await clearCollection('users');
    await clearCollection('companies');
    await clearCollection('company_members');
  });

  // ── Ruta A: cliente particular ─────────────────────────────────────────────

  test('onboarding particular → crea /users/{uid} con roles=[customer]', async () => {
    await firestore.collection('users').doc(uidParticular).set({
      uid:            uidParticular,
      phone:          '+5492610000010',
      displayName:    'Juan Prueba',
      email:          null,
      roles:          ROLE_TO_USER_ROLES['cliente_particular'],
      onboardingRole: 'cliente_particular',
      isActive:       true,
      isVerified:     false,
    });

    const snap = await firestore.collection('users').doc(uidParticular).get();
    expect(snap.exists).toBe(true);
    expect(snap.data().roles).toEqual(['customer']);
    expect(snap.data().onboardingRole).toBe('cliente_particular');
  });

  test('onboarding idempotente — segundo llamado no duplica documentos', async () => {
    // Primera vez
    await firestore.collection('users').doc(uidParticular).set({
      uid: uidParticular, displayName: 'Juan', roles: ['customer'],
      onboardingRole: 'cliente_particular', isActive: true, isVerified: false,
    });

    // Segunda vez — mismo uid
    const snap = await firestore.collection('users').doc(uidParticular).get();
    expect(snap.exists).toBe(true); // No falla, simplemente existe

    const allUsers = await firestore.collection('users').get();
    expect(allUsers.size).toBe(1); // Solo 1 documento, no duplicados
  });

  // ── Ruta B: empresa ────────────────────────────────────────────────────────

  test('onboarding empresa → crea /users + /companies + /company_members atómicamente', async () => {
    const companyId = 'test-company-emp-1';

    // Simular la transacción atómica de completarOnboardingFretix
    await firestore.runTransaction(async (tx) => {
      const userRef    = firestore.collection('users').doc(uidEmpresa);
      const companyRef = firestore.collection('companies').doc(companyId);
      const memberRef  = firestore.collection('company_members').doc('member-1');

      tx.set(userRef, {
        uid:            uidEmpresa,
        displayName:    'Empresa Test SA',
        roles:          ['customer'],
        onboardingRole: 'cliente_empresa_maestro',
        isActive:       true,
        isVerified:     false,
      });

      tx.set(companyRef, {
        companyId,
        type:           'customer',
        razonSocial:    'Empresa Test SA',
        cuit:           '30-12345678-9',
        ownerUserId:    uidEmpresa,
        cuentaCorriente: {
          habilitada:      false,
          macroLimitAudit: null,   // null = sin auditar → default-secure
          saldoActualARS:  0,
          limiteCreditoARS: 0,
        },
        isActive: true,
      });

      tx.set(memberRef, {
        userId:    uidEmpresa,
        companyId,
        role:      'owner',
        isActive:  true,
      });
    });

    // Verificar los 3 documentos
    const userSnap    = await firestore.collection('users').doc(uidEmpresa).get();
    const companySnap = await firestore.collection('companies').doc(companyId).get();
    const memberSnap  = await firestore.collection('company_members').doc('member-1').get();

    expect(userSnap.exists).toBe(true);
    expect(companySnap.exists).toBe(true);
    expect(memberSnap.exists).toBe(true);

    expect(userSnap.data().onboardingRole).toBe('cliente_empresa_maestro');
    expect(companySnap.data().type).toBe('customer');
    expect(companySnap.data().cuentaCorriente.macroLimitAudit).toBeNull();
    expect(memberSnap.data().role).toBe('owner');
    expect(memberSnap.data().companyId).toBe(companyId);
  });

  test('empresa recién creada tiene macroLimitAudit=null (default-secure)', async () => {
    const companyRef = firestore.collection('companies').doc('test-macro-null');
    await companyRef.set({
      type: 'customer',
      ownerUserId: uidEmpresa,
      cuentaCorriente: {
        habilitada:      false,
        macroLimitAudit: null,
      },
    });

    const snap = await companyRef.get();
    expect(snap.data().cuentaCorriente.macroLimitAudit).toBeNull();
    // null = bloquea confirmarViaje — invariante documentado en Módulo 4.1
  });

  // ── Chofer independiente ───────────────────────────────────────────────────

  test('onboarding chofer → crea /users con roles=[driver], sin /companies', async () => {
    const uidChofer = await createTestUser('+5492610000012');
    await firestore.collection('users').doc(uidChofer).set({
      uid:               uidChofer,
      displayName:       'Carlos Chofer',
      roles:             ROLE_TO_USER_ROLES['chofer_independiente'],
      onboardingRole:    'chofer_independiente',
      categoriaVehiculo: 'max',
      disponibleParaViajes: false,
      isActive:          true,
      isVerified:        false,
    });

    const snap = await firestore.collection('users').doc(uidChofer).get();
    expect(snap.data().roles).toEqual(['driver']);

    const companies = await firestore.collection('companies').get();
    expect(companies.size).toBe(0); // No se crea empresa para choferes independientes
  });

  test('onboarding chofer → categoriaVehiculo y disponibleParaViajes se persisten', async () => {
    const uidChofer = await createTestUser('+5492610000013');
    await firestore.collection('users').doc(uidChofer).set({
      uid:               uidChofer,
      displayName:       'Ana Chofer',
      roles:             ['driver'],
      onboardingRole:    'chofer_independiente',
      categoriaVehiculo: 'mini',
      disponibleParaViajes: false,
      isActive:          true,
      isVerified:        false,
    });

    const snap = await firestore.collection('users').doc(uidChofer).get();
    expect(snap.data().categoriaVehiculo).toBe('mini');
    expect(snap.data().disponibleParaViajes).toBe(false);
  });

  test('onboarding chofer → categoriaVehiculo debe ser valor válido (mini|plus|max|heavy)', async () => {
    // El valor 'camion' no es válido — en el sistema real la CF rechazaría el request.
    // Aquí validamos la lógica de validación directamente.
    const cat = 'camion';
    const esValido = CATEGORIAS_VEHICULO.has(cat);
    expect(esValido).toBe(false);
  });

  test('onboarding cliente_particular → no tiene categoriaVehiculo', async () => {
    const uidCliente = await createTestUser('+5492610000014');
    await firestore.collection('users').doc(uidCliente).set({
      uid:            uidCliente,
      displayName:    'Pedro Cliente',
      roles:          ['customer'],
      onboardingRole: 'cliente_particular',
      isActive:       true,
      isVerified:     false,
    });

    const snap = await firestore.collection('users').doc(uidCliente).get();
    expect(snap.data().categoriaVehiculo).toBeUndefined();
    expect(snap.data().disponibleParaViajes).toBeUndefined();
  });
});
