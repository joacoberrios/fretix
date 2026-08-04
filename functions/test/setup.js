'use strict';
/**
 * setup.js — Helper compartido para tests contra el emulador de Firestore.
 *
 * REQUISITO: los emuladores deben estar corriendo antes de ejecutar los tests.
 *   firebase emulators:start --only firestore,functions,auth
 *
 * Las variables de entorno FIRESTORE_EMULATOR_HOST y FIREBASE_AUTH_EMULATOR_HOST
 * las setea el script npm test en package.json.
 */

const { initializeApp, getApps, cert } = require('firebase-admin/app');
const { getFirestore }                  = require('firebase-admin/firestore');
const { getAuth }                       = require('firebase-admin/auth');

let _db;
let _auth;

function initAdmin() {
  if (!getApps().length) {
    initializeApp({ projectId: 'fretix-dev-jb' });
  }
  _db   = getFirestore();
  _auth = getAuth();
  return { db: _db, auth: _auth };
}

function getDb() {
  if (!_db) initAdmin();
  return _db;
}

function getAdminAuth() {
  if (!_auth) initAdmin();
  return _auth;
}

/**
 * Limpia una colección completa en el emulador.
 * NUNCA usar contra producción — solo válido con FIRESTORE_EMULATOR_HOST seteado.
 */
async function clearCollection(collectionName) {
  const db   = getDb();
  const snap = await db.collection(collectionName).get();
  const batch = db.batch();
  snap.docs.forEach((doc) => batch.delete(doc.ref));
  await batch.commit();
}

/**
 * Crea un usuario falso en el emulador de Auth y devuelve su uid.
 */
async function createTestUser(phoneNumber = '+5492610000001') {
  const auth = getAdminAuth();
  try {
    const existing = await auth.getUserByPhoneNumber(phoneNumber);
    return existing.uid;
  } catch {
    const user = await auth.createUser({ phoneNumber });
    return user.uid;
  }
}

/**
 * Seed mínimo de /config/tarifas y /config/app para tests de cotización.
 */
async function seedConfigMinimo() {
  const db = getDb();
  await db.collection('config').doc('tarifas').set({
    mini: { base: 1800, perKm: 350,  perMin: 90,  esperaGratisMin: 15, esperaExtraPerMin: 30 },
    plus: { base: 2800, perKm: 450,  perMin: 120, esperaGratisMin: 15, esperaExtraPerMin: 40 },
    max:  { base: 6500, perKm: 700,  perMin: 180, esperaGratisMin: 15, esperaExtraPerMin: 60 },
    heavy:{ base: 15000,perKm: 1200, perMin: 250, esperaGratisMin: 20, esperaExtraPerMin: 80 },
  });
  await db.collection('config').doc('app').set({
    comisionPlatforma: 0.15,
    helperFee: 5000,
    factorCorreccionMdz: 1.35,
    velocidadContingencia: 30,
    radioMatcheoKm: 5,
  });
}

module.exports = { initAdmin, getDb, getAdminAuth, clearCollection, createTestUser, seedConfigMinimo };
