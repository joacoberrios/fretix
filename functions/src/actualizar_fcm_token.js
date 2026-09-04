'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore }       = require('firebase-admin/firestore');

exports.actualizarFcmTokenFretix = onCall(
  {
    region: 'us-central1',
    cors: [
      'https://fretix-dev-jb.web.app',
      'https://fretix-dev-jb.firebaseapp.com',
      'http://127.0.0.1:3000',
    ],
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Se requiere autenticación.');

    const { fcmToken } = request.data;
    if (!fcmToken || typeof fcmToken !== 'string') {
      throw new HttpsError('invalid-argument', 'fcmToken requerido.');
    }

    const db = getFirestore();
    await db.collection('users').doc(uid).update({ fcmToken });

    return { success: true };
  }
);
