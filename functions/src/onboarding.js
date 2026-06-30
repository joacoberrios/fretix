// functions/src/onboarding.js
// Cloud Function: completarOnboardingFretix
//
// Responsabilidad: recibir los datos del perfil del nuevo usuario y persistir
// atómicamente los documentos necesarios en Firestore según el rol elegido.
//
// Roles simples  → solo crea /users/{uid}
// Roles empresa  → crea /users + /companies + /company_members en una sola transacción

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const db = getFirestore();

// Roles que requieren la creación paralela de una empresa.
const ROLES_EMPRESA = new Set([
  'cliente_empresa_maestro',
  'empresa_transporte_maestro',
]);

// Mapea el role id al tipo de empresa para la colección /companies.
const ROLE_TO_COMPANY_TYPE = {
  cliente_empresa_maestro: 'customer',
  empresa_transporte_maestro: 'carrier',
};

// Mapea el role id a los roles de Firestore para /users.roles[]
const ROLE_TO_USER_ROLES = {
  cliente_particular:        ['customer'],
  cliente_empresa_maestro:   ['customer'],
  chofer_independiente:      ['driver'],
  empresa_transporte_maestro: ['driver'],
};

/**
 * Callable Function: completarOnboardingFretix
 *
 * Payload esperado desde Flutter:
 * {
 *   role: string,           // ver FretixUserRole.id en auth_service.dart
 *   displayName: string,
 *   email?: string,
 *   // Solo para roles empresa:
 *   razonSocial?: string,
 *   cuit?: string,
 *   nombreComercial?: string,
 * }
 */
exports.completarOnboardingFretix = onCall(
  { region: 'us-central1', enforceAppCheck: false },
  async (request) => {
    // ── Validación de autenticación ──────────────────────────────────────────
    if (!request.auth) {
      throw new HttpsError(
        'unauthenticated',
        'El usuario debe estar autenticado para completar el onboarding.'
      );
    }

    const uid   = request.auth.uid;
    const phone = request.auth.token.phone_number;
    const data  = request.data;

    // ── Validación de payload ────────────────────────────────────────────────
    const { role, displayName, email, razonSocial, cuit, nombreComercial } = data;

    if (!role || !ROLE_TO_USER_ROLES[role]) {
      throw new HttpsError('invalid-argument', `Rol inválido: "${role}".`);
    }
    if (!displayName || typeof displayName !== 'string' || displayName.trim().length < 2) {
      throw new HttpsError('invalid-argument', 'displayName es requerido (mínimo 2 caracteres).');
    }

    const esEmpresa = ROLES_EMPRESA.has(role);

    if (esEmpresa) {
      if (!razonSocial) throw new HttpsError('invalid-argument', 'razonSocial es requerido para cuentas empresa.');
      if (!cuit)        throw new HttpsError('invalid-argument', 'cuit es requerido para cuentas empresa.');
    }

    // ── Verificar que el usuario no haya completado el onboarding antes ──────
    const userRef = db.collection('users').doc(uid);
    const userSnap = await userRef.get();

    if (userSnap.exists) {
      // Idempotente: si el documento ya existe, no fallamos — devolvemos éxito.
      return { success: true, alreadyOnboarded: true };
    }

    const now = FieldValue.serverTimestamp();

    // ── Documento base /users/{uid} ──────────────────────────────────────────
    const userDoc = {
      uid,
      phone:       phone ?? null,
      displayName: displayName.trim(),
      email:       email ?? null,
      photoURL:    null,
      roles:       ROLE_TO_USER_ROLES[role],
      onboardingRole: role,
      createdAt:   now,
      isActive:    true,
      isVerified:  false,
    };

    // ── Ruta A: Usuario simple (particular o chofer independiente) ────────────
    if (!esEmpresa) {
      await userRef.set(userDoc);
      return { success: true, uid, role };
    }

    // ── Ruta B: Empresa → transacción atómica ────────────────────────────────
    // Si cualquier escritura falla, ninguna persiste.
    const companyRef  = db.collection('companies').doc();   // auto-ID
    const memberRef   = db.collection('company_members').doc(); // auto-ID

    const companyType = ROLE_TO_COMPANY_TYPE[role];

    const companyDoc = {
      companyId:        companyRef.id,
      type:             companyType,
      razonSocial:      razonSocial.trim(),
      nombreComercial:  nombreComercial?.trim() ?? razonSocial.trim(),
      cuit:             cuit.trim(),
      condicionAfip:    'responsable_inscripto',
      direccionFiscal:  null,   // Se completa en el siguiente paso del onboarding.
      contactoPrincipal: {
        nombre: displayName.trim(),
        email:  email ?? null,
        phone:  phone ?? null,
        cargo:  null,
      },
      ownerUserId:  uid,
      // Campos específicos por tipo de empresa:
      ...(companyType === 'customer' && {
        cuentaCorriente: {
          habilitada:          false,
          limiteCreditoARS:    0,
          saldoActualARS:      0,
          diasCredito:         15,
          proximoVencimiento:  null,
        },
        facturacion: {
          tipoFactura:      'A',
          ciclo:            'mensual',
          emailFacturacion: email ?? null,
        },
      }),
      ...(companyType === 'carrier' && {
        comisionConfig: {
          porcentajePlatforma: 15,
          pagoCadaDias:        7,
        },
        facturacion: {
          tipoFactura:      'A',
          ciclo:            'quincenal',
          emailFacturacion: email ?? null,
        },
      }),
      createdAt: now,
      isActive:  true,
    };

    const memberDoc = {
      membershipId: memberRef.id,
      userId:    uid,
      companyId: companyRef.id,
      role:      'owner',
      permisos: {
        pedirFletes:           true,
        verHistorial:          true,
        gestionarSubusuarios:  true,
        verFacturacion:        true,
        aprobarGastos:         true,
      },
      limiteGastoMensualARS: null,
      createdAt: now,
      isActive:  true,
    };

    await db.runTransaction(async (transaction) => {
      transaction.set(userRef,    userDoc);
      transaction.set(companyRef, companyDoc);
      transaction.set(memberRef,  memberDoc);
    });

    return {
      success:   true,
      uid,
      role,
      companyId: companyRef.id,
    };
  }
);
