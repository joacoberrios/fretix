// functions/index.js
// Punto de entrada de todas las Cloud Functions de Fretix.

const { initializeApp } = require('firebase-admin/app');
initializeApp();

const { completarOnboardingFretix } = require('./src/onboarding');
const { cotizarViajeFretix }        = require('./src/cotizacion');

module.exports = {
  completarOnboardingFretix,
  cotizarViajeFretix,
};
