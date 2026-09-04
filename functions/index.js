// functions/index.js
// Punto de entrada de todas las Cloud Functions de Fretix.

const { initializeApp } = require('firebase-admin/app');
initializeApp();

const { completarOnboardingFretix }    = require('./src/onboarding');
const { cotizarViajeFretix }           = require('./src/cotizacion');
const { confirmarViajeFretix }         = require('./src/confirmar_viaje');
const { aceptarViajeFretix }           = require('./src/aceptar_viaje');
const { validarTarjetaVerdeFretix }    = require('./src/validar_tarjeta_verde');
const { actualizarFcmTokenFretix }     = require('./src/actualizar_fcm_token');

module.exports = {
  completarOnboardingFretix,
  cotizarViajeFretix,
  confirmarViajeFretix,
  aceptarViajeFretix,
  validarTarjetaVerdeFretix,
  actualizarFcmTokenFretix,
};
