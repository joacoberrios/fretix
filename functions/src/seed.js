'use strict';

// ─── Detección de emulador ────────────────────────────────────────────────────
// Si FIRESTORE_EMULATOR_HOST está seteada, admin SDK la usa automáticamente.
// Forzamos el valor por defecto para ejecución local si no viene del entorno.
if (!process.env.FIRESTORE_EMULATOR_HOST && !process.env.USE_PROD_FIRESTORE) {
  process.env.FIRESTORE_EMULATOR_HOST = 'localhost:8282';
  console.log('[seed] FIRESTORE_EMULATOR_HOST no estaba seteada → usando localhost:8282');
}

const { initializeApp, cert, getApps } = require('firebase-admin/app');
const { getFirestore, FieldValue }      = require('firebase-admin/firestore');

// Inicializa solo si no hay una instancia previa (re-run seguro)
if (!getApps().length) {
  initializeApp({ projectId: 'fretix-dev-jb' });
}

const db = getFirestore();

// ─── Data de seed ─────────────────────────────────────────────────────────────

const TARIFAS = {
  mini: {
    label:              'Flete Mini',
    ejemplos:           'Partner, Berlingo, Fiorino',
    base:               1800,
    perKm:              350,
    perMin:             90,
    esperaGratisMin:    15,
    esperaExtraPerMin:  30,
  },
  plus: {
    label:              'Flete Plus',
    ejemplos:           'Hilux, Amarok, Ranger',
    base:               2800,
    perKm:              450,
    perMin:             120,
    esperaGratisMin:    15,
    esperaExtraPerMin:  40,
  },
  max: {
    label:              'Flete Max',
    ejemplos:           'Sprinter, Transit',
    base:               6500,
    perKm:              700,
    perMin:             180,
    esperaGratisMin:    15,
    esperaExtraPerMin:  60,
  },
  heavy: {
    label:              'Carga Pesada',
    ejemplos:           'Ford Cargo, Mercedes Accelo',
    base:               15000,
    perKm:              1200,
    perMin:             250,
    esperaGratisMin:    20,
    esperaExtraPerMin:  80,
  },
};

const APP_CONFIG = {
  comisionPlatforma:    0.15,
  helperFee:            5000,
  factorCorreccionMdz:  1.35,
  velocidadContingencia: 30,
  radioMatcheoKm:        5,
  version:              '1.0.0',
  updatedAt:            FieldValue.serverTimestamp(),
};

// ─── Funciones de escritura ───────────────────────────────────────────────────

async function seedTarifas() {
  const ref = db.collection('config').doc('tarifas');
  await ref.set({
    ...TARIFAS,
    updatedAt: FieldValue.serverTimestamp(),
  });
  console.log('✅ /config/tarifas → 4 categorías (mini, plus, max, heavy)');
}

async function seedApp() {
  const ref = db.collection('config').doc('app');
  await ref.set(APP_CONFIG);
  console.log('✅ /config/app     → comision=15% | helperFee=$5.000 | radio=5km');
}

// ─── Runner ───────────────────────────────────────────────────────────────────

async function main() {
  const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
  console.log('');
  console.log('┌─────────────────────────────────────────┐');
  console.log('│         FRETIX — DB Seed Script         │');
  console.log('└─────────────────────────────────────────┘');
  console.log(`[seed] Firestore emulador → ${emulatorHost}`);
  console.log('[seed] Proyecto           → fretix-dev-jb');
  console.log('');

  try {
    await seedTarifas();
    await seedApp();

    console.log('');
    console.log('┌─────────────────────────────────────────┐');
    console.log('│   Seed completado sin errores  🎉        │');
    console.log('└─────────────────────────────────────────┘');
    console.log('');
    console.log('Documentos escritos:');
    console.log('  /config/tarifas   base + perKm + perMin + espera por categoría');
    console.log('  /config/app       comision, helperFee, factor corrección, radio');
    console.log('');
  } catch (err) {
    console.error('[seed] ❌ Error:', err.message);
    console.error('Verificá que el emulador de Firestore esté corriendo en puerto 8080.');
    process.exit(1);
  }
}

main();
