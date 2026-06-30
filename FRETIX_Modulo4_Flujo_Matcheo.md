# FRETIX — Módulo 4: Flujo del Viaje y Matcheo en Tiempo Real
**Versión:** 1.0 | **Fecha:** 2025-06-29
**Módulos anteriores:** [Arquitectura Firestore](./FRETIX_Arquitectura_Firestore.md) · [Auth y Onboarding](./FRETIX_Modulo2_Auth_Onboarding.md) · [Motor de Tarifas y Mapas](./FRETIX_Modulo3_Tarifas_Mapas.md)
**Stack:** Cloud Functions Node.js v2 · Firestore Triggers · Firebase Cloud Messaging (FCM) · Geohash

---

## 1. OBJETIVO DEL MÓDULO

Definir la máquina de estados que gobierna un viaje en Fretix de punta a punta, el algoritmo
de matcheo geográfico con cola de asignación por tiempo, y el sistema de notificaciones push
que mantiene a cliente y chofer sincronizados en tiempo real.

**Principio de diseño:** ningún cambio de estado en `/trips` es válido si no pasa por una
Cloud Function. El cliente Flutter solo escucha (`onSnapshot`) — nunca escribe estados
directamente en Firestore.

---

## 2. MÁQUINA DE ESTADOS — ESPECIFICACIÓN FORMAL

### Diagrama de transiciones

```
                        [Cliente confirma cotización]
                                    │
                              ┌─────▼──────┐
                              │  quoting   │  ← cotizacionId vinculada, sin chofer
                              └─────┬──────┘
                                    │ confirmarViajeFretix()
                              ┌─────▼──────┐
                              │ confirmed  │  ← sistema busca choferes disponibles
                              └─────┬──────┘
                                    │ [Chofer acepta — aceptarViajeFretix()]
                              ┌─────▼──────┐
                              │  assigned  │  ← driverId + vehicleId vinculados
                              └─────┬──────┘
                                    │ iniciarCargaFretix()
                           ┌────────▼──────────┐
                           │   in_progress      │  ← timer de espera activo
                           └────────┬──────────┘
                                    │ finalizarViajeFretix()
                              ┌─────▼──────┐
                              │ completed  │  ← liquidación + calificaciones
                              └────────────┘

        En cualquier estado previo a in_progress:
        cancelarViajeFretix() → cancelled
```

### Reglas de transición (seguridad)

| Transición | Quién puede dispararla | Validación requerida |
|---|---|---|
| `quoting` → `confirmed` | Cliente (vía Cloud Function) | `cotizacionId` vigente (< 10 min) |
| `confirmed` → `assigned` | Sistema (matcheo automático) | Chofer `online` + categoría correcta + < 5km |
| `assigned` → `in_progress` | Chofer (vía Cloud Function) | `driverId` del request == `driverId` del viaje |
| `in_progress` → `completed` | Chofer (vía Cloud Function) | `driverId` coincidente + estado actual `in_progress` |
| Cualquiera → `cancelled` | Cliente o Chofer (reglas distintas) | Ver política de cancelación |

---

## 3. ESTRATEGIA DE GEOLOCALIZACIÓN — GEOHASH

### Problema
Firestore no tiene soporte nativo para consultas geográficas del tipo
*"dame todos los documentos dentro de X km de este punto"*.
Una query `where latitude > X && latitude < Y && longitude > A && longitude < B`
requiere un índice compuesto y no es eficiente para miles de documentos.

### Solución elegida: Geohash + librería `geofire-common`

**Geohash** convierte una coordenada `(lat, lng)` en un string alfanumérico donde
strings con prefijo común representan zonas geográficas cercanas.

```
Ejemplo Mendoza:
  Maipú (-32.994, -68.773)  → geohash: "6f2uc9..."
  Godoy Cruz (-32.914, -68.839) → geohash: "6f2u8f..."
  Prefijo común "6f2u" → misma región general
```

### Implementación en Firestore

**Al escribir/actualizar la ubicación del chofer:**
```javascript
// En la Cloud Function que recibe la ubicación desde la app del chofer:
const geohash = require('ngeohash');

const hash = geohash.encode(lat, lng, 9);  // precisión ~5m

await db.collection('drivers').doc(driverId).update({
  lastLocation: new GeoPoint(lat, lng),
  lastUpdated:  FieldValue.serverTimestamp(),
  geohash:      hash,      // ← campo indexado para queries geo
});
```

**Documento `/drivers` con geohash:**
```json
{
  "driverId":       "drv_rferreyra_001",
  "estadoServicio": "online",
  "vehicleCategory": "max",
  "lastLocation":   { "latitude": -32.9741, "longitude": -68.8120 },
  "lastUpdated":    "2025-06-29T14:37:52Z",
  "geohash":        "6f2ud4xyz"
}
```

### Query de matcheo por geohash

La librería `geofire-common` (npm) genera los prefijos de geohash que cubren
un radio dado. Para 5 km, genera entre 4 y 9 prefijos de búsqueda.

```javascript
const { geohashQueryBounds, distanceBetween } = require('geofire-common');

// Centro = coordenadas del origen del viaje
const center      = [originLat, originLng];
const radiusInM   = 5000;   // 5 km en metros

// Genera los bounds de geohash que cubren el radio
const bounds = geohashQueryBounds(center, radiusInM);

// Una query por cada bound (máx 9, generalmente 4-6)
const queries = bounds.map(b =>
  db.collection('drivers')
    .where('estadoServicio',   '==', 'online')
    .where('vehicleCategory',  '==', category)
    .where('geohash',         '>=', b[0])
    .where('geohash',         '<=', b[1])
    .get()
);

const snapshots = await Promise.all(queries);

// Filtro post-query: Haversine exacto para eliminar falsos positivos del geohash
const candidatos = [];
for (const snap of snapshots) {
  for (const doc of snap.docs) {
    const data = doc.data();
    const distKm = distanceBetween(
      [data.lastLocation.latitude, data.lastLocation.longitude],
      center
    ) / 1000;

    if (distKm <= 5.0) {
      candidatos.push({ ...data, distanciaKm: distKm });
    }
  }
}

// Ordenar por distancia ascendente (más cercano primero)
candidatos.sort((a, b) => a.distanciaKm - b.distanciaKm);
```

### ¿Por qué no `geoflutterfire`?
`geoflutterfire` es una librería de Flutter (cliente). En Fretix, el matcheo
ocurre en el backend (Cloud Function) por seguridad y atomicidad. `geofire-common`
es la versión framework-agnostic usable en Node.js.

### Índice requerido en Firestore

```json
// firestore.indexes.json
{
  "indexes": [
    {
      "collectionGroup": "drivers",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "estadoServicio",  "order": "ASCENDING" },
        { "fieldPath": "vehicleCategory", "order": "ASCENDING" },
        { "fieldPath": "geohash",         "order": "ASCENDING" }
      ]
    }
  ]
}
```

---

## 4. ALGORITMO DE MATCHEO — COLA DE ASIGNACIÓN

### Archivo
`functions/src/matcheo.js`

### Trigger
`onDocumentUpdated` en `/trips/{tripId}` cuando `estado` cambia a `confirmed`.

### Flujo completo del algoritmo

```
Trip pasa a "confirmed"
        │
        ▼
buscarCandidatos(origin, category, radioKm=5)
        │
        ├── Sin candidatos → estado: "sin_cobertura" + notificar al cliente
        │
        └── Candidatos ordenados por distancia
                │
                ▼
        Cola: [chofer_A (1.2km), chofer_B (2.8km), chofer_C (4.1km)]
                │
                ▼
        Escribir en /trips/{tripId}:
          matcheo.colaChoferes: [ids...]
          matcheo.indexActual: 0
          matcheo.intentos: 0
                │
                ▼
        notificarChofer(chofer_A, tripId)   ← FCM push + escribir oferta activa
                │
                ├── Chofer acepta en < 45s → aceptarViajeFretix()  ✅
                │
                └── Timeout 45s (Cloud Scheduler o Firestore TTL trigger)
                        │
                        ▼
                matcheo.indexActual++
                        │
                        ├── ¿Hay más choferes? → notificarChofer(chofer_B)
                        │
                        └── Cola agotada → estado: "sin_cobertura"
```

### Código — `functions/src/matcheo.js`

```javascript
// functions/src/matcheo.js
// Trigger: cuando un /trips/{tripId} pasa a estado "confirmed"

const { onDocumentUpdated }         = require('firebase-functions/v2/firestore');
const { getFirestore, FieldValue }  = require('firebase-admin/firestore');
const { geohashQueryBounds, distanceBetween } = require('geofire-common');
const { enviarNotificacionChofer }  = require('./notificaciones');

const db = getFirestore();

const RADIO_MATCHEO_KM    = 5;
const TIMEOUT_ACEPTACION_SEG = 45;

exports.triggerMatcheoEnConfirmacion = onDocumentUpdated(
  { document: 'trips/{tripId}', region: 'us-central1' },
  async (event) => {
    const antes  = event.data.before.data();
    const despues = event.data.after.data();

    // Solo actuar cuando el estado cambia específicamente a "confirmed"
    if (antes.estado === despues.estado) return;
    if (despues.estado !== 'confirmed')  return;

    const tripId   = event.params.tripId;
    const tripData = despues;

    console.log(`[matcheo] Iniciando matcheo para trip ${tripId}`);

    try {
      const candidatos = await buscarCandidatos({
        originLat:  tripData.ruta.origen.geoPoint.latitude,
        originLng:  tripData.ruta.origen.geoPoint.longitude,
        category:   tripData.vehiculoCategoria,
      });

      if (candidatos.length === 0) {
        await event.data.after.ref.update({
          estado:               'sin_cobertura',
          'matcheo.mensaje':    'No hay choferes disponibles en tu zona. Intentá en unos minutos.',
          'matcheo.timestamp':  FieldValue.serverTimestamp(),
        });
        // Notificar al cliente: sin cobertura
        await notificarClienteSinCobertura(tripData.solicitadoPor.userId);
        return;
      }

      // Escribir la cola en el documento del viaje
      await event.data.after.ref.update({
        'matcheo.colaChoferes': candidatos.map(c => c.driverId),
        'matcheo.indexActual':  0,
        'matcheo.intentos':     0,
        'matcheo.timestamp':    FieldValue.serverTimestamp(),
      });

      // Ofrecer al primer candidato (más cercano)
      await ofrecerAChofer(tripId, candidatos[0], tripData);

    } catch (err) {
      console.error(`[matcheo] Error en trip ${tripId}:`, err);
    }
  }
);

// ── Búsqueda geográfica ────────────────────────────────────────────────────

async function buscarCandidatos({ originLat, originLng, category }) {
  const center  = [originLat, originLng];
  const bounds  = geohashQueryBounds(center, RADIO_MATCHEO_KM * 1000);

  const queries = bounds.map(b =>
    db.collection('drivers')
      .where('estadoServicio',   '==', 'online')
      .where('vehicleCategory',  '==', category)
      .where('geohash',         '>=', b[0])
      .where('geohash',         '<=', b[1])
      .get()
  );

  const snapshots  = await Promise.all(queries);
  const candidatos = [];

  for (const snap of snapshots) {
    for (const doc of snap.docs) {
      const data  = doc.data();

      // Filtro de frescura: ignorar choferes cuya ubicación tiene > 3 minutos
      const lastUpdated = data.lastUpdated?.toDate?.() ?? new Date(0);
      const segundosDesde = (Date.now() - lastUpdated.getTime()) / 1000;
      if (segundosDesde > 180) continue;

      const distKm = distanceBetween(
        [data.lastLocation.latitude, data.lastLocation.longitude],
        center
      ) / 1000;

      if (distKm <= RADIO_MATCHEO_KM) {
        candidatos.push({
          driverId:    doc.id,
          userId:      data.userId,
          fcmToken:    data.fcmToken,
          distanciaKm: parseFloat(distKm.toFixed(2)),
          employerCompanyId: data.employerCompanyId ?? null,
        });
      }
    }
  }

  candidatos.sort((a, b) => a.distanciaKm - b.distanciaKm);
  return candidatos;
}

// ── Ofrecer viaje a un chofer específico ──────────────────────────────────

async function ofrecerAChofer(tripId, chofer, tripData) {
  const ofertaRef = db.collection('ofertas_viaje').doc(`${tripId}_${chofer.driverId}`);

  // La oferta tiene TTL de 45 segundos.
  // Una Cloud Function scheduled (ver sección 5) revisa las ofertas vencidas.
  const expiresAt = new Date(Date.now() + TIMEOUT_ACEPTACION_SEG * 1000);

  await ofertaRef.set({
    tripId,
    driverId:   chofer.driverId,
    estado:     'pendiente',
    expiresAt,
    createdAt:  FieldValue.serverTimestamp(),
  });

  // Notificación push al chofer
  await enviarNotificacionChofer({
    fcmToken:    chofer.fcmToken,
    tripId,
    distanciaKm: chofer.distanciaKm,
    categoria:   tripData.vehiculoCategoria,
    origen:      tripData.ruta.origen.direccion,
    destino:     tripData.ruta.destino.direccion,
    totalCliente: tripData.pricing.totalCliente,
    expiresAt,
  });

  console.log(`[matcheo] Oferta enviada a ${chofer.driverId} para trip ${tripId}`);
}

// ── Avanzar al siguiente chofer (llamado por el trigger de timeout) ────────

exports.avanzarColaMatcheo = async (tripId) => {
  const tripRef  = db.collection('trips').doc(tripId);
  const tripSnap = await tripRef.get();

  if (!tripSnap.exists) return;
  const trip = tripSnap.data();

  // Seguridad: solo avanzar si el viaje sigue en "confirmed"
  if (trip.estado !== 'confirmed') return;

  const cola        = trip.matcheo?.colaChoferes ?? [];
  const indexActual = trip.matcheo?.indexActual  ?? 0;
  const siguiente   = indexActual + 1;

  if (siguiente >= cola.length) {
    // Cola agotada
    await tripRef.update({
      estado:               'sin_cobertura',
      'matcheo.mensaje':    'Todos los choferes disponibles rechazaron o no respondieron.',
      'matcheo.timestamp':  FieldValue.serverTimestamp(),
    });
    await notificarClienteSinCobertura(trip.solicitadoPor.userId);
    return;
  }

  // Avanzar al siguiente chofer
  const driverIdSiguiente = cola[siguiente];
  const driverSnap = await db.collection('drivers').doc(driverIdSiguiente).get();

  if (!driverSnap.exists || driverSnap.data().estadoServicio !== 'online') {
    // El chofer ya no está disponible, saltar recursivamente
    await tripRef.update({ 'matcheo.indexActual': siguiente });
    return exports.avanzarColaMatcheo(tripId);
  }

  await tripRef.update({
    'matcheo.indexActual': siguiente,
    'matcheo.intentos':    FieldValue.increment(1),
  });

  const choferData = driverSnap.data();
  await ofrecerAChofer(tripId, {
    driverId:    driverIdSiguiente,
    userId:      choferData.userId,
    fcmToken:    choferData.fcmToken,
    distanciaKm: choferData.distanciaKm ?? 0,
    employerCompanyId: choferData.employerCompanyId ?? null,
  }, trip);
};

async function notificarClienteSinCobertura(userId) {
  // Ver sección 7: notificaciones
  console.log(`[matcheo] Notificando sin cobertura a usuario ${userId}`);
}
```

### Colección auxiliar `/ofertas_viaje/{ofertaId}`

```json
{
  "tripId":    "trp_20250629_001",
  "driverId":  "drv_rferreyra_001",
  "estado":    "pendiente",
  "expiresAt": "2025-06-29T14:01:45Z",
  "createdAt": "2025-06-29T14:01:00Z"
}
```

`estado` puede ser: `pendiente` → `aceptada` | `rechazada` | `expirada`

---

## 5. MANEJO DEL TIMEOUT DE 45 SEGUNDOS

### Problema
Cloud Functions no puede hacer un `setTimeout` confiable de larga duración
entre requests. Se necesita un mecanismo de trigger basado en tiempo.

### Solución elegida: Firestore TTL + Trigger en `/ofertas_viaje`

**Opción A — Firestore TTL Field (recomendada para producción):**

Firestore permite configurar un campo TTL por colección. Cuando `expiresAt`
vence, Firestore elimina el documento automáticamente. Un trigger
`onDocumentDeleted` en `/ofertas_viaje` detecta la eliminación y avanza la cola.

```javascript
// functions/src/matcheo.js (agregado)
const { onDocumentDeleted } = require('firebase-functions/v2/firestore');

exports.onOfertaExpirada = onDocumentDeleted(
  { document: 'ofertas_viaje/{ofertaId}', region: 'us-central1' },
  async (event) => {
    const oferta = event.data.data();

    // Solo reaccionar si la oferta estaba pendiente (no aceptada ni rechazada)
    if (oferta.estado !== 'pendiente') return;

    console.log(`[matcheo] Oferta expirada para trip ${oferta.tripId}, avanzando cola.`);
    await exports.avanzarColaMatcheo(oferta.tripId);
  }
);
```

**Configuración TTL en Firestore Console:**
```
Collection: ofertas_viaje
TTL Field:  expiresAt
```

**Opción B — Cloud Tasks (para control preciso del delay):**

Alternativa más precisa pero más compleja: al crear la oferta, encolar una
Cloud Task con delay de 45s que llama a `avanzarColaMatcheo`. Evaluar en
una fase posterior si el TTL presenta latencia inaceptable en producción.

---

## 6. FUNCIONES DE CAMBIO DE ESTADO

### Archivo
`functions/src/estados_viaje.js`

---

### 6.1 `aceptarViajeFretix`

**Quién la llama:** App del chofer al presionar "Aceptar viaje".

```javascript
// El chofer acepta la oferta activa.
exports.aceptarViajeFretix = onCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'No autenticado.');

    const { tripId } = request.data;
    const uid = request.auth.uid;

    // Resolver driverId desde uid
    const driverSnap = await db.collection('drivers')
      .where('userId', '==', uid).limit(1).get();
    if (driverSnap.empty) throw new HttpsError('not-found', 'Perfil de chofer no encontrado.');

    const driverData = driverSnap.docs[0].data();
    const driverId   = driverSnap.docs[0].id;

    const tripRef  = db.collection('trips').doc(tripId);
    const ofertaId = `${tripId}_${driverId}`;
    const ofertaRef = db.collection('ofertas_viaje').doc(ofertaId);

    await db.runTransaction(async (tx) => {
      const tripSnap   = await tx.get(tripRef);
      const ofertaSnap = await tx.get(ofertaRef);

      if (!tripSnap.exists)   throw new HttpsError('not-found',  'Viaje no encontrado.');
      if (!ofertaSnap.exists) throw new HttpsError('not-found',  'Oferta no encontrada.');

      const trip   = tripSnap.data();
      const oferta = ofertaSnap.data();

      // Validaciones de seguridad
      if (trip.estado !== 'confirmed') {
        throw new HttpsError('failed-precondition', `El viaje no está en estado "confirmed" (estado actual: ${trip.estado}).`);
      }
      if (oferta.estado !== 'pendiente') {
        throw new HttpsError('failed-precondition', 'Esta oferta ya no está disponible.');
      }
      if (new Date() > oferta.expiresAt.toDate()) {
        throw new HttpsError('deadline-exceeded', 'El tiempo para aceptar expiró.');
      }

      // ── Actualizar el viaje ──────────────────────────────────────────────
      tx.update(tripRef, {
        estado: 'assigned',
        'asignacion.driverId':          driverId,
        'asignacion.userId':            uid,
        'asignacion.displayName':       driverData.userId,
        'asignacion.vehicleId':         driverData.vehicleIdActivo,
        'asignacion.employerCompanyId': driverData.employerCompanyId ?? null,
        // Si el chofer es empleado → el pago va a la empresa; si no → al chofer
        'asignacion.pagoDestinatario':  driverData.employerCompanyId ? 'company' : 'driver',
        'historialEstados':             FieldValue.arrayUnion({
          estado:    'assigned',
          timestamp: new Date().toISOString(),
        }),
      });

      // ── Marcar oferta como aceptada ──────────────────────────────────────
      tx.update(ofertaRef, { estado: 'aceptada' });

      // ── Cambiar estado del chofer a "en_viaje" ───────────────────────────
      // Evita que reciba nuevas alertas mientras está ocupado.
      tx.update(db.collection('drivers').doc(driverId), {
        estadoServicio: 'en_viaje',
        tripIdActivo:   tripId,
      });
    });

    // ── Notificar al cliente (fuera de la transacción) ───────────────────
    const tripData = (await tripRef.get()).data();
    await notificarClienteViajeAsignado(tripData.solicitadoPor.userId, {
      driverName: driverData.displayName ?? 'Tu chofer',
      patente:    driverData.vehicleIdActivo,
    });

    return { success: true, tripId, estado: 'assigned' };
  }
);
```

---

### 6.2 `iniciarCargaFretix`

**Quién la llama:** App del chofer al presionar "Llegué al origen — Iniciar carga".

```javascript
exports.iniciarCargaFretix = onCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'No autenticado.');

    const { tripId } = request.data;
    const uid = request.auth.uid;

    const tripRef  = db.collection('trips').doc(tripId);
    const tripSnap = await tripRef.get();

    if (!tripSnap.exists) throw new HttpsError('not-found', 'Viaje no encontrado.');
    const trip = tripSnap.data();

    // Validar que quien llama es el chofer asignado
    if (trip.asignacion?.userId !== uid) {
      throw new HttpsError('permission-denied', 'Solo el chofer asignado puede iniciar la carga.');
    }
    if (trip.estado !== 'assigned') {
      throw new HttpsError('failed-precondition', `Estado inválido para iniciar carga: ${trip.estado}`);
    }

    const ahora = new Date().toISOString();

    await tripRef.update({
      estado:                  'in_progress',
      'tiempos.inicioCarga':   ahora,
      'tiempos.inicioEspera':  ahora,   // El timer de espera arranca aquí
      'historialEstados': FieldValue.arrayUnion({
        estado:    'in_progress',
        timestamp: ahora,
      }),
    });

    // Notificar al cliente que el chofer llegó
    await notificarClienteChoferEnOrigen(trip.solicitadoPor.userId);

    return { success: true, tripId, estado: 'in_progress' };
  }
);
```

---

### 6.3 `finalizarViajeFretix`

**Quién la llama:** App del chofer al confirmar entrega en destino.

```javascript
exports.finalizarViajeFretix = onCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'No autenticado.');

    const { tripId } = request.data;
    const uid = request.auth.uid;

    const tripRef  = db.collection('trips').doc(tripId);
    const tripSnap = await tripRef.get();

    if (!tripSnap.exists) throw new HttpsError('not-found', 'Viaje no encontrado.');
    const trip = tripSnap.data();

    if (trip.asignacion?.userId !== uid) {
      throw new HttpsError('permission-denied', 'Solo el chofer asignado puede finalizar el viaje.');
    }
    if (trip.estado !== 'in_progress') {
      throw new HttpsError('failed-precondition', `Estado inválido para finalizar: ${trip.estado}`);
    }

    const ahora        = new Date();
    const inicioEspera = trip.tiempos?.inicioEspera
      ? new Date(trip.tiempos.inicioEspera)
      : ahora;

    // ── Calcular tiempo de espera extra ─────────────────────────────────────
    // Leer minutosGratis desde /config
    const configSnap = await db.collection('config')
      .doc(`tarifas_flete_${trip.vehiculoCategoria}`).get();

    const minutosGratis = configSnap.exists
      ? (configSnap.data().esperaGratisMinutos ?? 15)
      : 15;

    const costoEsperaMinuto = configSnap.exists
      ? (configSnap.data().costoEsperaPorMinutoARS ?? 0)
      : 0;

    const minutosTranscurridos = Math.floor(
      (ahora.getTime() - inicioEspera.getTime()) / 60000
    );
    const minutosFacturables = Math.max(0, minutosTranscurridos - minutosGratis);
    const costoEsperaExtra   = minutosFacturables * costoEsperaMinuto;

    // ── Precio final con espera extra ────────────────────────────────────────
    const pricingOriginal    = trip.pricing;
    const totalFinal         = pricingOriginal.totalCliente + costoEsperaExtra;
    const gananciaFinal      = pricingOriginal.gananciaChoferOEmpresa + costoEsperaExtra;

    await db.runTransaction(async (tx) => {
      // Actualizar el viaje a completed
      tx.update(tripRef, {
        estado:              'completed',
        completedAt:         ahora.toISOString(),
        'tiempos.finViaje':  ahora.toISOString(),
        'pricing.esperaExtra': {
          minutosGratis,
          minutosTranscurridos,
          minutosFacturables,
          costoExtraEspera: costoEsperaExtra,
        },
        'pricing.totalFinal':    totalFinal,
        'pricing.gananciaFinal': gananciaFinal,
        'historialEstados': FieldValue.arrayUnion({
          estado:    'completed',
          timestamp: ahora.toISOString(),
        }),
      });

      // Liberar al chofer
      tx.update(db.collection('drivers').doc(trip.asignacion.driverId), {
        estadoServicio: 'online',
        tripIdActivo:   null,
      });

      // ── Liquidación según tipo de destinatario ───────────────────────────
      if (trip.asignacion.pagoDestinatario === 'driver') {
        // Chofer independiente: sumar a su balance pendiente
        tx.update(db.collection('drivers').doc(trip.asignacion.driverId), {
          'ganancias.balancePendienteARS':  FieldValue.increment(gananciaFinal),
          'ganancias.totalHistoricoARS':    FieldValue.increment(gananciaFinal),
          'stats.totalViajes':              FieldValue.increment(1),
        });
      } else {
        // Empresa de transporte: sumar al balance de la empresa
        tx.update(db.collection('companies').doc(trip.asignacion.employerCompanyId), {
          'balancePendienteARS': FieldValue.increment(gananciaFinal),
          'totalViajesARS':      FieldValue.increment(gananciaFinal),
        });
        // Stats del chofer empleado (sin dinero)
        tx.update(db.collection('drivers').doc(trip.asignacion.driverId), {
          'stats.totalViajes': FieldValue.increment(1),
        });
      }

      // ── Si el cliente es empresa: mover a cuenta corriente ───────────────
      if (trip.solicitadoPor.companyId) {
        tx.update(db.collection('companies').doc(trip.solicitadoPor.companyId), {
          'cuentaCorriente.saldoActualARS': FieldValue.increment(-totalFinal),
        });
      }

      // ── Vincular cotización al viaje completado ──────────────────────────
      if (trip.cotizacionId) {
        tx.update(db.collection('quotations').doc(trip.cotizacionId), {
          estado: 'confirmada',
          tripId,
        });
      }
    });

    // Notificar a ambas partes fuera de la transacción
    await Promise.all([
      notificarClienteViajeCompletado(trip.solicitadoPor.userId, totalFinal),
      notificarChoferViajeCompletado(uid, gananciaFinal, trip.asignacion.pagoDestinatario),
    ]);

    return { success: true, tripId, estado: 'completed', totalFinal, costoEsperaExtra };
  }
);
```

---

### 6.4 `cancelarViajeFretix`

**Quién la llama:** Cliente o Chofer.

| Actor | Estado permitido | Política |
|---|---|---|
| Cliente | `quoting`, `confirmed` | Sin penalidad |
| Cliente | `assigned` | Penalidad: monto fijo configurable (ej. $1.000) |
| Cliente | `in_progress` | No permitido desde la app — requiere soporte |
| Chofer | `assigned` | Sin penalidad (chofer pierde el viaje, vuelve a `online`) |

```javascript
exports.cancelarViajeFretix = onCall(
  { region: 'us-central1' },
  async (request) => {
    const { tripId, motivo } = request.data;
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'No autenticado.');

    const tripRef  = db.collection('trips').doc(tripId);
    const tripSnap = await tripRef.get();
    if (!tripSnap.exists) throw new HttpsError('not-found', 'Viaje no encontrado.');

    const trip         = tripSnap.data();
    const esCliente    = trip.solicitadoPor.userId === uid;
    const esChofer     = trip.asignacion?.userId   === uid;
    const estadoActual = trip.estado;

    if (!esCliente && !esChofer) {
      throw new HttpsError('permission-denied', 'No tenés permiso para cancelar este viaje.');
    }
    if (['completed', 'cancelled', 'sin_cobertura'].includes(estadoActual)) {
      throw new HttpsError('failed-precondition', `El viaje no puede cancelarse en estado "${estadoActual}".`);
    }
    if (esCliente && estadoActual === 'in_progress') {
      throw new HttpsError('failed-precondition', 'No podés cancelar un viaje en curso. Contactá soporte.');
    }

    const updates = {
      estado:      'cancelled',
      canceladoAt: new Date().toISOString(),
      'cancelacion.motivo':    motivo ?? null,
      'cancelacion.canceladoPor': esCliente ? 'cliente' : 'chofer',
      'historialEstados': FieldValue.arrayUnion({
        estado:    'cancelled',
        timestamp: new Date().toISOString(),
      }),
    };

    // Si el chofer cancela, liberarlo
    if (esChofer && trip.asignacion?.driverId) {
      await db.collection('drivers').doc(trip.asignacion.driverId).update({
        estadoServicio: 'online',
        tripIdActivo:   null,
      });
    }

    await tripRef.update(updates);
    return { success: true, tripId, estado: 'cancelled' };
  }
);
```

---

## 7. NOTIFICACIONES — ESTRATEGIA FCM

### Archivo
`functions/src/notificaciones.js`

### Almacenamiento del token FCM

El token FCM del dispositivo se guarda en `/drivers/{driverId}.fcmToken` y
en `/users/{uid}.fcmToken`. Se actualiza cada vez que la app inicia sesión
(los tokens rotan con actualizaciones del SO).

```dart
// Flutter — actualizar token al inicio de la app
final token = await FirebaseMessaging.instance.getToken();
await FretixAuthService.instance.actualizarFcmToken(token);
// → Cloud Function escribe token en /users/{uid} y /drivers/{driverId}
```

---

### Catálogo de notificaciones del sistema

| Evento | Destinatario | Título | Cuerpo | Data payload |
|---|---|---|---|---|
| Viaje confirmado, buscando chofer | Cliente | "Buscando tu chofer" | "Estamos encontrando el mejor transportista disponible." | `{ tripId, screen: "trip_tracking" }` |
| Nueva carga disponible | Chofer | "🚛 Nueva carga a {X} km" | "{categoria} · {origen} → {destino} · ${totalCliente}" | `{ tripId, screen: "oferta_viaje", expiresAt }` |
| Viaje asignado | Cliente | "¡Chofer en camino!" | "{driverName} está yendo a buscarte." | `{ tripId, screen: "trip_tracking" }` |
| Chofer llegó al origen | Cliente | "Tu chofer llegó" | "Ya está en el punto de carga." | `{ tripId, screen: "trip_tracking" }` |
| Viaje en curso | Cliente | "En camino a destino" | "Tu carga está en tránsito." | `{ tripId, screen: "trip_tracking" }` |
| Viaje completado | Cliente | "¡Entrega completada!" | "Total: ${totalFinal}. Calificá a tu chofer." | `{ tripId, screen: "rating" }` |
| Viaje completado | Chofer | "Viaje finalizado" | "Ganaste ${ganancia}. ¡Buen trabajo!" (solo independiente) | `{ tripId, screen: "rating" }` |
| Sin cobertura | Cliente | "Sin choferes disponibles" | "No encontramos choferes en tu zona. Intentá en unos minutos." | `{ tripId }` |
| Viaje cancelado | Chofer | "Viaje cancelado" | "El cliente canceló el viaje." | `{ tripId }` |
| Oferta expirada | Sistema | — | (silenciosa, solo data) | `{ tripId, action: "oferta_expirada" }` |

---

### Código — `functions/src/notificaciones.js`

```javascript
// functions/src/notificaciones.js

const { getMessaging } = require('firebase-admin/messaging');

const messaging = getMessaging();

/**
 * Envía una notificación push al chofer con la oferta de viaje.
 * Incluye data payload para que la app navegue a la pantalla correcta.
 */
async function enviarNotificacionChofer({
  fcmToken, tripId, distanciaKm, categoria,
  origen, destino, totalCliente, expiresAt,
}) {
  if (!fcmToken) {
    console.warn(`[fcm] Chofer sin fcmToken para trip ${tripId}`);
    return;
  }

  const categoriaLabel = {
    mini: 'Flete Mini', plus: 'Flete Plus',
    max:  'Flete Max',  heavy: 'Carga Pesada',
  }[categoria] ?? categoria;

  const message = {
    token: fcmToken,
    notification: {
      title: `🚛 Nueva carga a ${distanciaKm} km`,
      body:  `${categoriaLabel} · ${origen} → ${destino} · $${totalCliente.toLocaleString('es-AR')}`,
    },
    data: {
      tripId,
      screen:    'oferta_viaje',
      expiresAt: expiresAt.toISOString(),
    },
    android: {
      priority: 'high',
      notification: { channelId: 'fretix_ofertas', sound: 'oferta_viaje' },
    },
    apns: {
      payload: { aps: { sound: 'oferta_viaje.caf', badge: 1 } },
    },
  };

  try {
    await messaging.send(message);
  } catch (err) {
    console.error(`[fcm] Error enviando notificación a chofer:`, err.message);
    // No lanzar error: una notificación fallida no debe abortar el flujo de matcheo
  }
}

/**
 * Helper genérico para notificaciones al cliente.
 * Busca el fcmToken del usuario en /users/{uid}.
 */
async function notificarUsuario(userId, { title, body, data = {} }) {
  const { getFirestore } = require('firebase-admin/firestore');
  const db = getFirestore();

  const userSnap = await db.collection('users').doc(userId).get();
  if (!userSnap.exists) return;

  const fcmToken = userSnap.data().fcmToken;
  if (!fcmToken) return;

  const message = {
    token: fcmToken,
    notification: { title, body },
    data: { ...data },
    android: { priority: 'high' },
  };

  try {
    await messaging.send(message);
  } catch (err) {
    console.error(`[fcm] Error notificando usuario ${userId}:`, err.message);
  }
}

async function notificarClienteViajeAsignado(userId, { driverName }) {
  await notificarUsuario(userId, {
    title: '¡Chofer en camino!',
    body:  `${driverName} está yendo a buscarte.`,
    data:  { screen: 'trip_tracking' },
  });
}

async function notificarClienteChoferEnOrigen(userId) {
  await notificarUsuario(userId, {
    title: 'Tu chofer llegó',
    body:  'Ya está en el punto de carga.',
    data:  { screen: 'trip_tracking' },
  });
}

async function notificarClienteViajeCompletado(userId, totalFinal) {
  await notificarUsuario(userId, {
    title: '¡Entrega completada!',
    body:  `Total: $${totalFinal.toLocaleString('es-AR')}. Calificá a tu chofer.`,
    data:  { screen: 'rating' },
  });
}

async function notificarChoferViajeCompletado(userId, ganancia, pagoDestinatario) {
  const body = pagoDestinatario === 'driver'
    ? `Ganaste $${ganancia.toLocaleString('es-AR')}. ¡Buen trabajo!`
    : 'Viaje registrado correctamente.';

  await notificarUsuario(userId, {
    title: 'Viaje finalizado',
    body,
    data:  { screen: 'rating' },
  });
}

module.exports = {
  enviarNotificacionChofer,
  notificarClienteViajeAsignado,
  notificarClienteChoferEnOrigen,
  notificarClienteViajeCompletado,
  notificarChoferViajeCompletado,
};
```

---

## 8. ACTUALIZACIÓN DE UBICACIÓN DEL CHOFER EN TIEMPO REAL

### Estrategia
El chofer en estado `online` o `en_viaje` envía su posición GPS cada **5 segundos**
desde la app Flutter a una Cloud Function liviana que actualiza su documento en `/drivers`.

```
App Chofer (Flutter)
  Geolocator.getPositionStream(interval: 5s)
        │
        ▼
  actualizarUbicacionChofer({ lat, lng })   ← Cloud Function onCall
        │
        ▼
  /drivers/{driverId}:
    lastLocation: GeoPoint(lat, lng)
    lastUpdated:  serverTimestamp()
    geohash:      encode(lat, lng, 9)
```

### Cloud Function liviana de ubicación

```javascript
// functions/src/ubicacion.js
exports.actualizarUbicacionChofer = onCall(
  { region: 'us-central1', minInstances: 1 },  // minInstances evita cold start en función crítica
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'No autenticado.');

    const { lat, lng } = request.data;
    const uid = request.auth.uid;

    const geohash = require('ngeohash');

    // Resolver driverId (idealmente cacheado en el token custom claim en el futuro)
    const driverSnap = await db.collection('drivers')
      .where('userId', '==', uid).limit(1).get();
    if (driverSnap.empty) return { success: false };

    await driverSnap.docs[0].ref.update({
      lastLocation: new GeoPoint(lat, lng),
      lastUpdated:  FieldValue.serverTimestamp(),
      geohash:      geohash.encode(lat, lng, 9),
    });

    return { success: true };
  }
);
```

### Tracking del cliente (en tiempo real)

El cliente ve la posición del chofer en tiempo real mediante un listener
de Firestore directamente en Flutter — sin pasar por Cloud Function:

```dart
// Flutter: escuchar posición del chofer asignado
StreamSubscription? _driverLocationSub;

void escucharUbicacionChofer(String driverId) {
  _driverLocationSub = FirebaseFirestore.instance
      .collection('drivers')
      .doc(driverId)
      .snapshots()
      .listen((snap) {
        if (!snap.exists) return;
        final data = snap.data()!;
        final geoPoint = data['lastLocation'] as GeoPoint;
        // Mover marcador del chofer en el mapa
        setState(() {
          _choferPosition = LatLng(geoPoint.latitude, geoPoint.longitude);
        });
      });
}
```

---

## 9. REGLAS DE SEGURIDAD DE FIRESTORE (Firestore Rules — extracto)

```javascript
// firestore.rules (extracto relevante al Módulo 4)
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // /trips: el cliente puede crear, nadie puede escribir directamente estados
    match /trips/{tripId} {
      allow read:   if request.auth != null
                    && (resource.data.solicitadoPor.userId == request.auth.uid
                        || resource.data.asignacion.userId == request.auth.uid);
      allow create: if request.auth != null;
      // Las actualizaciones de estado SOLO vienen de Cloud Functions (admin SDK)
      allow update: if false;
      allow delete: if false;
    }

    // /drivers: solo el propio chofer puede leer su doc completo
    match /drivers/{driverId} {
      allow read:   if request.auth != null
                    && resource.data.userId == request.auth.uid;
      allow write:  if false;   // Solo Cloud Functions
    }

    // /ofertas_viaje: solo lectura para el chofer destinatario
    match /ofertas_viaje/{ofertaId} {
      allow read:   if request.auth != null;
      allow write:  if false;   // Solo Cloud Functions
    }
  }
}
```

---

## 10. ARCHIVOS DEL MÓDULO

| Archivo | Tipo | Estado |
|---|---|---|
| `functions/src/matcheo.js` | Node.js | ✅ Especificado y codificado |
| `functions/src/estados_viaje.js` | Node.js | ✅ Especificado y codificado |
| `functions/src/notificaciones.js` | Node.js | ✅ Especificado y codificado |
| `functions/src/ubicacion.js` | Node.js | ✅ Especificado y codificado |
| `firestore.indexes.json` | Config | ✅ Índice geohash definido |
| `firestore.rules` | Config | ✅ Reglas de seguridad definidas |
| `lib/services/trip_service.dart` | Flutter | Pendiente — Módulo 5 |
| `lib/screens/trip/trip_tracking_screen.dart` | Flutter | Pendiente — Módulo 5 |

### Actualización de `functions/index.js`

```javascript
const { completarOnboardingFretix }      = require('./src/onboarding');
const { cotizarViajeFretix }             = require('./src/cotizacion');
const { triggerMatcheoEnConfirmacion,
        onOfertaExpirada,
        avanzarColaMatcheo }             = require('./src/matcheo');
const { aceptarViajeFretix,
        iniciarCargaFretix,
        finalizarViajeFretix,
        cancelarViajeFretix }            = require('./src/estados_viaje');
const { actualizarUbicacionChofer }      = require('./src/ubicacion');

module.exports = {
  completarOnboardingFretix,
  cotizarViajeFretix,
  triggerMatcheoEnConfirmacion,
  onOfertaExpirada,
  aceptarViajeFretix,
  iniciarCargaFretix,
  finalizarViajeFretix,
  cancelarViajeFretix,
  actualizarUbicacionChofer,
};
```

### Nueva dependencia NPM

```json
{
  "dependencies": {
    "geofire-common": "^6.x",
    "ngeohash":       "^0.6.x"
  }
}
```

---

## 11. COLECCIONES NUEVAS EN ESTE MÓDULO

### `/ofertas_viaje/{tripId}_{driverId}`
Tabla de intermediación entre un viaje confirmado y los choferes candidatos.
TTL de 45 segundos gestionado por Firestore TTL Field.

### Campos adicionales en `/drivers` (Módulo 4)

```json
{
  "geohash":        "6f2ud4xyz",
  "vehicleCategory": "max",
  "fcmToken":       "eXAiOiJ...",
  "tripIdActivo":   "trp_20250629_001"
}
```

### Campos adicionales en `/trips` (Módulo 4)

```json
{
  "cotizacionId": "cot_abc123",
  "matcheo": {
    "colaChoferes": ["drv_001", "drv_002", "drv_003"],
    "indexActual":  0,
    "intentos":     0,
    "timestamp":    "2025-06-29T14:00:00Z"
  },
  "tiempos": {
    "inicioCarga":  "2025-06-29T13:18:00Z",
    "inicioEspera": "2025-06-29T13:18:00Z",
    "finViaje":     "2025-06-29T14:35:22Z"
  }
}
```

---

## 12. DECISIONES DE ARQUITECTURA REGISTRADAS

| Decisión | Razonamiento |
|---|---|
| Geohash + `geofire-common` en backend | Las queries geo ocurren en la Cloud Function, no en el cliente. Más seguro, más eficiente, permite mantener la API Key fuera del frontend |
| Filtro de frescura de 3 minutos en choferes | Un chofer con ubicación > 3 min puede haber apagado la app. Mejor excluirlo del matcheo y evitar timeouts de aceptación |
| Firestore TTL para expiración de oferta | Más simple y confiable que Cloud Tasks para este caso. Latencia de TTL aceptable (~90s en el peor caso) — evaluar Cloud Tasks si la latencia impacta UX |
| Transacción en `aceptarViajeFretix` | Evita race condition donde dos choferes aceptan simultáneamente el mismo viaje |
| `minInstances: 1` en `actualizarUbicacion` | Función invocada cada 5 segundos por cada chofer activo — el cold start de 1-2s sería inaceptable en este contexto |
| FCM errors no bloquean el flujo | Una notificación fallida (token inválido, dispositivo offline) no debe abortar el matcheo ni la transacción de aceptación |
| Liquidación en `finalizarViaje` según `pagoDestinatario` | El campo `asignacion.pagoDestinatario` (definido al aceptar el viaje) determina si el saldo va al chofer o a la empresa transportista. Decisión única, inmutable en ese momento |
| Regla de Firestore `allow update: if false` en trips | Los cambios de estado son tan críticos que se bloquean 100% desde el cliente. Solo el Admin SDK (Cloud Functions) puede actualizar |

---

## 13. PENDIENTES PARA MÓDULO 5 (UI del Viaje — Flutter)

| Componente | Descripción |
|---|---|
| `TripService` | Stream wrapper de `/trips/{tripId}` + llamadas a las Cloud Functions de estado |
| `OfertaViajeScreen` | Pantalla del chofer con countdown de 45s, mapa del origen, y botones Aceptar/Rechazar |
| `TripTrackingScreen` | Mapa en tiempo real para el cliente con marcador del chofer, estado del viaje y ETA |
| `TripControlScreen` | Panel del chofer con botones "Llegué", "Iniciar carga", "Finalizar entrega" |
| `RatingScreen` | Calificación bidireccional post-viaje (cliente califica chofer y viceversa) |
| FCM Handler Flutter | Manejo de notificaciones en foreground/background → navegación automática a la pantalla correcta |

---

*Documento de referencia técnica — Módulo 4 aprobado.*
*Adjuntar junto a los módulos anteriores para contexto completo de Fretix.*
