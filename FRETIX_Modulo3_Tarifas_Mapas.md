# FRETIX — Módulo 3: Motor de Tarifas y Mapas
**Versión:** 1.0 | **Fecha:** 2025-06-29
**Módulos anteriores:** [Arquitectura Firestore](./FRETIX_Arquitectura_Firestore.md) · [Auth y Onboarding](./FRETIX_Modulo2_Auth_Onboarding.md)
**Stack:** Cloud Functions Node.js v2 · Google Maps Distance Matrix API · Flutter (geolocator + google_maps_flutter)

---

## 1. OBJETIVO DEL MÓDULO

Implementar el motor de cotización de viajes de Fretix: una Cloud Function segura que consulta
Google Maps, aplica la fórmula de tarifas leyendo los valores desde Firestore `/config`, y
devuelve un presupuesto cerrado al cliente antes de que confirme el viaje.

**Principio de diseño:** ningún cálculo de precio ocurre en el cliente Flutter. Todo pasa por
la Cloud Function para evitar manipulación de tarifas desde el frontend.

---

## 2. ARQUITECTURA DEL FLUJO DE COTIZACIÓN

```
[Flutter Client]
      │
      │  cotizarViajeFretix({ origin, destination, category, ayudante })
      ▼
[Cloud Function — cotizarViajeFretix]
      │
      ├──► Firestore /config/{category}   → lee tarifas vigentes
      │
      ├──► Google Maps Distance Matrix API
      │         └── devuelve: distanceMeters, durationSeconds, polyline (Directions API)
      │
      ├──► Motor matemático interno
      │         └── aplica fórmula, calcula comisión, excluye helperFee
      │
      └──► Respuesta JSON estructurada → Flutter renderiza cotización + mapa
```

---

## 3. CLOUD FUNCTION — `cotizarViajeFretix`

### Archivo
`functions/src/cotizacion.js`

### Payload de entrada (desde Flutter)

```json
{
  "originLat":      -32.9941,
  "originLng":      -68.7731,
  "destinationLat": -32.9147,
  "destinationLng": -68.8392,
  "category":       "max",
  "ayudante":       true,
  "paradas":  []
}
```

> `paradas` es un array opcional de `{ lat, lng }` para viajes con paradas intermedias.
> Ver sección 6 para el manejo de paradas múltiples.

### Respuesta de salida

```json
{
  "success": true,
  "cotizacion": {
    "categoria":     "max",
    "distanciaKm":   18.4,
    "duracionMin":   32,
    "pricing": {
      "base":                  6500,
      "kmCosto":               12880,
      "minutoCosto":           5760,
      "subtotalTransporte":    25140,
      "helperFee": {
        "monto":           5000,
        "exento_comision": true
      },
      "baseParaComision":      25140,
      "comisionPorcentaje":    15,
      "comisionMonto":         3771,
      "totalCliente":          34911,
      "gananciaEstimadaChofer": 26369
    },
    "ruta": {
      "polyline":       "encodedPolylineString...",
      "distanciaTexto": "18,4 km",
      "duracionTexto":  "32 min"
    },
    "tarifaFuente":  "firestore_config",
    "generadoEn":    "2025-06-29T14:00:00Z"
  }
}
```

---

### Código — `functions/src/cotizacion.js`

```javascript
// functions/src/cotizacion.js
// Cloud Function: cotizarViajeFretix
//
// Responsabilidad: calcular el presupuesto cerrado de un viaje consultando
// Google Maps y leyendo las tarifas vigentes desde Firestore /config.
// Nunca expone la API Key de Maps al cliente.

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { getFirestore }       = require('firebase-admin/firestore');
const { defineString }       = require('firebase-functions/params');
const axios                  = require('axios');

const db = getFirestore();

// La API Key se almacena como Firebase Secret (nunca en código fuente).
// Configurar con: firebase functions:secrets:set MAPS_API_KEY
const MAPS_API_KEY = defineString('MAPS_API_KEY');

const CATEGORIAS_VALIDAS = new Set(['mini', 'plus', 'max', 'heavy']);

// ── Constantes de contingencia (usadas si Firestore /config no responde) ─────
// Reflejan los valores del Módulo 1. Solo son fallback de emergencia.
const TARIFAS_FALLBACK = {
  mini:  { base: 1800,  precioPorKm: 350,  precioPorMinuto: 90  },
  plus:  { base: 2800,  precioPorKm: 450,  precioPorMinuto: 120 },
  max:   { base: 6500,  precioPorKm: 700,  precioPorMinuto: 180 },
  heavy: { base: 15000, precioPorKm: 1200, precioPorMinuto: 250 },
};

const HELPER_FEE_FALLBACK        = 5000;
const COMISION_PORCENTAJE_DEFAULT = 15;

// ─────────────────────────────────────────────────────────────────────────────

exports.cotizarViajeFretix = onCall(
  {
    region:          'us-central1',
    enforceAppCheck: false,
    timeoutSeconds:  30,
  },
  async (request) => {

    // ── 1. Autenticación ────────────────────────────────────────────────────
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Autenticación requerida para cotizar.');
    }

    // ── 2. Validación de payload ────────────────────────────────────────────
    const {
      originLat, originLng,
      destinationLat, destinationLng,
      category,
      ayudante = false,
      paradas  = [],
    } = request.data;

    if (!esCoordValida(originLat, originLng)) {
      throw new HttpsError('invalid-argument', 'Coordenadas de origen inválidas.');
    }
    if (!esCoordValida(destinationLat, destinationLng)) {
      throw new HttpsError('invalid-argument', 'Coordenadas de destino inválidas.');
    }
    if (!CATEGORIAS_VALIDAS.has(category)) {
      throw new HttpsError('invalid-argument', `Categoría inválida: "${category}".`);
    }
    if (!Array.isArray(paradas) || paradas.length > 5) {
      throw new HttpsError('invalid-argument', 'Máximo 5 paradas intermedias permitidas.');
    }

    // ── 3. Leer tarifas desde Firestore /config ─────────────────────────────
    // Si falla, se usa el fallback hardcodeado y se registra el origen.
    let tarifas;
    let tarifaFuente;
    let helperFeeConfig;
    let comisionPorcentaje;

    try {
      const [configSnap, globalSnap] = await Promise.all([
        db.collection('config').doc(`tarifas_flete_${category}`).get(),
        db.collection('config').doc('global_plataforma').get(),
      ]);

      if (configSnap.exists && globalSnap.exists) {
        const configData = configSnap.data();
        const globalData = globalSnap.data();

        tarifas = {
          base:           configData.pricing.base,
          precioPorKm:    configData.pricing.precioPorKm,
          precioPorMinuto: configData.pricing.precioPorMinuto,
        };
        helperFeeConfig    = globalData.helperFee;
        comisionPorcentaje = globalData.comisionPorcentaje ?? COMISION_PORCENTAJE_DEFAULT;
        tarifaFuente       = 'firestore_config';
      } else {
        throw new Error('Documentos de config no encontrados en Firestore.');
      }
    } catch (err) {
      console.warn('[cotizarViaje] Firestore config no disponible, usando fallback.', err.message);
      tarifas            = TARIFAS_FALLBACK[category];
      helperFeeConfig    = { monto: HELPER_FEE_FALLBACK, exento_comision: true };
      comisionPorcentaje = COMISION_PORCENTAJE_DEFAULT;
      tarifaFuente       = 'fallback_hardcoded';
    }

    // ── 4. Consulta a Google Maps ───────────────────────────────────────────
    let distanciaKm;
    let duracionMin;
    let polyline;
    let mapsFuente;

    try {
      const resultado = await consultarGoogleMaps({
        originLat, originLng,
        destinationLat, destinationLng,
        paradas,
        apiKey: MAPS_API_KEY.value(),
      });

      distanciaKm = resultado.distanciaKm;
      duracionMin  = resultado.duracionMin;
      polyline     = resultado.polyline;
      mapsFuente   = 'google_maps_api';

    } catch (err) {
      console.error('[cotizarViaje] Google Maps falló. Calculando distancia en línea recta.', err.message);

      // Contingencia: Haversine entre origen y destino.
      // Se aplica un factor de corrección de 1.35 para aproximar distancia vial real.
      const distanciaHaversine = calcularHaversineKm(
        originLat, originLng,
        destinationLat, destinationLng,
      );
      distanciaKm = parseFloat((distanciaHaversine * 1.35).toFixed(2));
      duracionMin  = Math.round(distanciaKm / 0.5);   // ~30 km/h promedio ciudad
      polyline     = null;
      mapsFuente   = 'haversine_contingencia';
    }

    // ── 5. Motor matemático de tarifas ──────────────────────────────────────
    const base           = tarifas.base;
    const kmCosto        = parseFloat((tarifas.precioPorKm * distanciaKm).toFixed(2));
    const minutoCosto    = parseFloat((tarifas.precioPorMinuto * duracionMin).toFixed(2));
    const subtotalTransporte = base + kmCosto + minutoCosto;

    // helperFee: exento de comisión según flag en /config/global_plataforma
    const helperMonto    = ayudante ? helperFeeConfig.monto : 0;
    const exentoComision = helperFeeConfig.exento_comision ?? true;

    // La comisión del 15% se calcula SOLO sobre el transporte puro.
    const baseParaComision = subtotalTransporte;   // helperFee nunca entra aquí
    const comisionMonto    = Math.round(baseParaComision * (comisionPorcentaje / 100));

    const totalCliente           = subtotalTransporte + helperMonto;
    const gananciaEstimadaChofer = subtotalTransporte - comisionMonto + helperMonto;

    // ── 6. Respuesta ────────────────────────────────────────────────────────
    return {
      success: true,
      cotizacion: {
        categoria:    category,
        distanciaKm,
        duracionMin,
        pricing: {
          base,
          kmCosto,
          minutoCosto,
          subtotalTransporte,
          helperFee: ayudante
            ? { monto: helperMonto, exento_comision: exentoComision }
            : null,
          baseParaComision,
          comisionPorcentaje,
          comisionMonto,
          totalCliente,
          gananciaEstimadaChofer,
        },
        ruta: {
          polyline,
          distanciaTexto: `${distanciaKm.toFixed(1).replace('.', ',')} km`,
          duracionTexto:  `${duracionMin} min`,
        },
        tarifaFuente,
        mapsFuente,
        generadoEn: new Date().toISOString(),
      },
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// Helpers internos
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Llama a Google Maps Directions API (no Distance Matrix) porque Directions
 * devuelve también la polyline codificada necesaria para dibujar la ruta en Flutter.
 *
 * Para viajes con paradas, inserta los waypoints en el orden recibido.
 */
async function consultarGoogleMaps({ originLat, originLng, destinationLat, destinationLng, paradas, apiKey }) {
  const origin      = `${originLat},${originLng}`;
  const destination = `${destinationLat},${destinationLng}`;

  let url = `https://maps.googleapis.com/maps/api/directions/json`
          + `?origin=${origin}`
          + `&destination=${destination}`
          + `&mode=driving`
          + `&language=es`
          + `&region=AR`
          + `&key=${apiKey}`;

  if (paradas.length > 0) {
    const waypoints = paradas.map(p => `${p.lat},${p.lng}`).join('|');
    url += `&waypoints=${encodeURIComponent(waypoints)}`;
  }

  const response = await axios.get(url, { timeout: 8000 });

  if (response.data.status !== 'OK') {
    throw new Error(`Google Maps status: ${response.data.status}`);
  }

  // Para viajes con paradas, sumamos distancia y duración de todos los tramos (legs).
  const legs = response.data.routes[0].legs;

  const totalMetros   = legs.reduce((acc, leg) => acc + leg.distance.value, 0);
  const totalSegundos = legs.reduce((acc, leg) => acc + leg.duration.value, 0);

  const distanciaKm = parseFloat((totalMetros / 1000).toFixed(2));
  const duracionMin = Math.ceil(totalSegundos / 60);

  // Polyline general de la ruta completa (primer resultado, overview_polyline).
  const polyline = response.data.routes[0].overview_polyline.points;

  return { distanciaKm, duracionMin, polyline };
}

/**
 * Fórmula de Haversine: distancia en km entre dos coordenadas geográficas.
 * Usada solo como contingencia cuando Google Maps no responde.
 */
function calcularHaversineKm(lat1, lng1, lat2, lng2) {
  const R    = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a    = Math.sin(dLat / 2) ** 2
             + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function toRad(deg)  { return deg * (Math.PI / 180); }

function esCoordValida(lat, lng) {
  return typeof lat === 'number' && typeof lng === 'number'
      && lat >= -90  && lat <= 90
      && lng >= -180 && lng <= 180;
}
```

---

## 4. FÓRMULA MATEMÁTICA — ESPECIFICACIÓN FORMAL

### Cotización base (sin espera extra)

```
subtotalTransporte = BASE + (PRECIO_KM × distanciaKm) + (PRECIO_MIN × duracionMin)

baseParaComision   = subtotalTransporte          ← helperFee nunca entra aquí
comisionFretix     = ROUND(baseParaComision × 0.15)

totalCliente             = subtotalTransporte + helperFee (si aplica)
gananciaChoferOEmpresa   = subtotalTransporte − comisionFretix + helperFee (si aplica)
```

### Espera extra (se calcula post-viaje, no en la cotización)

```
minutosFacturables = MAX(0, minutosRealesEspera − minutosGratis)
costoEsperaExtra   = minutosFacturables × COSTO_ESPERA_MIN

El costoEsperaExtra se suma al totalCliente final del viaje completado.
No forma parte de la cotización inicial (el cliente lo ve como "posible extra").
```

### Ejemplo numérico — Flete Max, 18.4 km, 32 min, con ayudante

```
BASE              = $  6.500
KM  18.4 × $700  = $ 12.880
MIN 32   × $180  = $  5.760
──────────────────────────────
subtotalTransporte = $ 25.140

baseParaComision   = $ 25.140
comisión 15%       = $  3.771  (ROUND)

helperFee          = $  5.000  (exento_comision: true)

totalCliente             = $25.140 + $5.000 = $ 30.140
gananciaChoferOEmpresa   = $25.140 − $3.771 + $5.000 = $ 26.369
ganaFretix               = $  3.771
```

---

## 5. TABLA DE TARIFAS DE REFERENCIA (Valores Mendoza — Módulo 1)

| Categoría | Base | KM | Minuto | Espera gratis | Costo espera/min |
|---|---|---|---|---|---|
| `mini`  | $1.800  | $350   | $90  | 15 min | $60  |
| `plus`  | $2.800  | $450   | $120 | 15 min | $80  |
| `max`   | $6.500  | $700   | $180 | 15 min | $180 |
| `heavy` | $15.000 | $1.200 | $250 | 20 min | $300 |

**Add-on Ayudante (helperFee):** $5.000 fijo · 100% para el chofer · exento del 15%

> Todos estos valores viven en Firestore `/config/{categoria}` y `/config/global_plataforma`.
> Se leen en runtime — ninguno está hardcodeado en la Cloud Function (los fallbacks son
> solo para contingencia de emergencia).

---

## 6. MANEJO DE PARADAS INTERMEDIAS

### Límite operativo
Máximo **5 paradas intermedias** por viaje (validado en la Cloud Function).

### Impacto en la fórmula
La Directions API devuelve múltiples `legs` (tramos). Se suman todos:

```javascript
const totalMetros   = legs.reduce((acc, leg) => acc + leg.distance.value, 0);
const totalSegundos = legs.reduce((acc, leg) => acc + leg.duration.value, 0);
```

La fórmula de tarifa se aplica una sola vez sobre los totales acumulados — no se
cobra la tarifa base por cada tramo para no encarecer artificialmente el viaje.

### En el frontend Flutter (futuro)
Cada parada agrega un marcador al mapa y actualiza la cotización en tiempo real
llamando nuevamente a `cotizarViajeFretix` con el array `paradas` actualizado.

---

## 7. ESTRATEGIA DE GEOLOCALIZACIÓN EN FLUTTER

### Paquetes

| Paquete | Versión ref. | Uso |
|---|---|---|
| `geolocator` | ^10.x | Captura GPS del dispositivo, permisos, stream de ubicación |
| `google_maps_flutter` | ^2.x | Renderizado del mapa, marcadores y polilínea |
| `flutter_polyline_points` | ^2.x | Decodifica el encoded polyline string de Google Maps |

### Flujo de captura de ubicación del cliente

```
App abre pantalla de cotización
        │
        ▼
GeolocatorService.getCurrentPosition()
        │
        ├── Permiso ya concedido → devuelve Position(lat, lng)
        │
        └── Sin permiso → solicitar con Geolocator.requestPermission()
                │
                ├── Concedido → getCurrentPosition()
                └── Denegado  → mostrar dialog "Fretix necesita tu ubicación
                                para mostrar los choferes cercanos" + botón
                                "Abrir configuración" → Geolocator.openAppSettings()
```

### Estrategia de precisión
```dart
// Alta precisión para el punto de origen del viaje (GPS puro).
final position = await Geolocator.getCurrentPosition(
  desiredAccuracy: LocationAccuracy.high,
  timeLimit: const Duration(seconds: 10),
);
```

### Dibujado de la Polilínea en el mapa

Una vez que `cotizarViajeFretix` devuelve `cotizacion.ruta.polyline` (encoded string):

```dart
// 1. Decodificar el polyline string a lista de coordenadas
final List<PointLatLng> points = PolylinePoints()
    .decodePolyline(cotizacion.ruta.polyline);

// 2. Convertir a LatLng de google_maps_flutter
final List<LatLng> polylineCoords = points
    .map((p) => LatLng(p.latitude, p.longitude))
    .toList();

// 3. Crear el objeto Polyline para el mapa
final polyline = Polyline(
  polylineId: const PolylineId('ruta_viaje'),
  color:      const Color(0xFFF5A623),   // Naranja Fretix
  width:      4,
  points:     polylineCoords,
  patterns:   [],
);

// 4. Pasar el Set<Polyline> al widget GoogleMap
GoogleMap(
  polylines: {polyline},
  markers:   {markerOrigen, markerDestino},
  ...
)
```

### Ajuste automático del viewport
```dart
// Calcular bounds para que el mapa encuadre origen y destino automáticamente.
final bounds = LatLngBounds(
  southwest: LatLng(
    min(origin.latitude,  destination.latitude),
    min(origin.longitude, destination.longitude),
  ),
  northeast: LatLng(
    max(origin.latitude,  destination.latitude),
    max(origin.longitude, destination.longitude),
  ),
);
controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80.0));
```

---

## 8. CASOS DE BORDE Y ESTRATEGIA DE MITIGACIÓN

### 8.1 Google Maps falla o da timeout

| Escenario | Detección | Acción |
|---|---|---|
| Timeout > 8 segundos | `axios` timeout error | Activar modo contingencia Haversine |
| Status != 'OK' de Maps API | `response.data.status` | Activar modo contingencia Haversine |
| Sin conexión en la Function | Network error | Activar modo contingencia Haversine |

**Modo contingencia Haversine:**
- Calcula distancia en línea recta entre origen y destino
- Aplica factor de corrección **1.35** para aproximar la distancia vial real mendocina
- Velocidad promedio asumida: **30 km/h** (tráfico urbano Mendoza)
- La respuesta incluye `"mapsFuente": "haversine_contingencia"` y `"polyline": null`
- El frontend Flutter detecta `polyline === null` y **no dibuja la ruta**, pero sí muestra la cotización con un aviso: *"Cotización estimada. La ruta exacta se confirmará al asignar el chofer."*

**Factor 1.35 — justificación:**
> Análisis empírico para Mendoza Capital: la distancia vial promedio entre dos puntos
> urbanos es 1.3x–1.4x la distancia en línea recta, debido a la cuadrícula regular
> de calles pero con corredor de avenidas principales. 1.35 es el punto medio conservador.

### 8.2 Paradas intermedias

Ver sección 6. Límite de 5 paradas validado en la Cloud Function con `HttpsError('invalid-argument')`.

### 8.3 Distancia extremadamente corta (< 1 km)

```javascript
if (distanciaKm < 1.0) {
  // Cobrar distancia mínima de 1 km para que el viaje sea viable para el chofer.
  distanciaKm = 1.0;
}
```

Este mínimo se puede configurar en `/config/global_plataforma` como `distanciaMinKm`.

### 8.4 Origen y destino idénticos

```javascript
if (distanciaKm < 0.05) {
  throw new HttpsError(
    'invalid-argument',
    'El origen y el destino no pueden ser el mismo punto.'
  );
}
```

### 8.5 Tarifa desactualizada entre cotización y confirmación

La cotización tiene una vigencia de **10 minutos** (`expiresAt` en la respuesta).
Cuando el cliente confirma el viaje, la Cloud Function de confirmación verifica que
el `cotizacionId` no haya expirado antes de crear el documento en `/trips`.

```json
{
  "cotizacionId": "cot_abc123",
  "generadoEn":   "2025-06-29T14:00:00Z",
  "expiresAt":    "2025-06-29T14:10:00Z"
}
```

### 8.6 Cliente sin permiso de ubicación

El frontend ofrece dos alternativas:
1. **Selección manual en el mapa** (drag del marcador al punto deseado)
2. **Búsqueda por dirección** vía Google Places Autocomplete API

Ambas terminan generando un `{ lat, lng }` que se pasa a `cotizarViajeFretix` de la misma forma.

---

## 9. SEGURIDAD DE LA API KEY DE GOOGLE MAPS

### Regla fundamental
> La API Key de Google Maps **nunca** debe estar en el código fuente del cliente Flutter
> ni en variables de entorno de la Cloud Function en texto plano.

### Implementación correcta

**Backend (Cloud Function):**
```bash
# Almacenar como Firebase Secret (encriptado en reposo):
firebase functions:secrets:set MAPS_API_KEY

# La función accede con:
const MAPS_API_KEY = defineString('MAPS_API_KEY');
```

**Frontend Flutter:**
La app Flutter **nunca** llama directamente a Google Maps Distance Matrix o Directions
con la API Key. Solo usa:
- `google_maps_flutter` para renderizar el mapa (usa la key configurada en `AndroidManifest.xml`
  y `AppDelegate.swift` — esta key debe tener restricción de `Android App` / `iOS App` en
  Google Cloud Console para que no pueda usarse fuera de la app)
- Calls a la Cloud Function para obtener datos de rutas y precios

### Restricciones en Google Cloud Console

| Key | Tipo de restricción | APIs habilitadas |
|---|---|---|
| Key para Cloud Functions | IP del servidor / Sin restricción de app | Directions API, Distance Matrix API |
| Key para Flutter/Android | Android App (SHA-1 fingerprint) | Maps SDK for Android |
| Key para Flutter/iOS | iOS App (Bundle ID) | Maps SDK for iOS |

---

## 10. REGISTRO DE COTIZACIONES (Trazabilidad)

Cada cotización generada se persiste en Firestore para auditoría y para vincularla al viaje confirmado:

### Colección `/quotations/{cotizacionId}`

```json
{
  "cotizacionId":  "cot_abc123",
  "userId":        "usr_sub_empleado_004",
  "companyId":     "cmp_zuccardi_cliente",
  "categoria":     "max",
  "ayudante":      true,
  "distanciaKm":   18.4,
  "duracionMin":   32,
  "pricing":       { "...": "objeto pricing completo" },
  "ruta":          { "polyline": "...", "distanciaTexto": "18,4 km" },
  "tarifaFuente":  "firestore_config",
  "mapsFuente":    "google_maps_api",
  "generadoEn":    "2025-06-29T14:00:00Z",
  "expiresAt":     "2025-06-29T14:10:00Z",
  "estado":        "pendiente",
  "tripId":        null
}
```

`estado` puede ser: `pendiente` → `confirmada` → `expirada` | `cancelada`

Cuando el cliente confirma, el `tripId` se escribe en este documento y el `cotizacionId`
se referencia en `/trips/{tripId}.cotizacionId` para trazabilidad completa.

---

## 11. ARCHIVOS DEL MÓDULO

| Archivo | Tipo | Estado |
|---|---|---|
| `functions/src/cotizacion.js` | Node.js Cloud Function | ✅ Especificado y codificado |
| `functions/index.js` | Entry point Functions | Actualizar con export de `cotizarViajeFretix` |
| `lib/services/maps_service.dart` | Flutter | Pendiente — Módulo 3B |
| `lib/screens/cotizacion/cotizacion_screen.dart` | Flutter UI | Pendiente — Módulo 3B |

### Actualización requerida en `functions/index.js`

```javascript
const { completarOnboardingFretix } = require('./src/onboarding');
const { cotizarViajeFretix }        = require('./src/cotizacion');

module.exports = {
  completarOnboardingFretix,
  cotizarViajeFretix,
};
```

---

## 12. DEPENDENCIAS NPM NUEVAS (functions/package.json)

```json
{
  "dependencies": {
    "firebase-admin":    "^12.x",
    "firebase-functions": "^5.x",
    "axios":             "^1.x"
  }
}
```

---

## 13. DECISIONES DE ARQUITECTURA REGISTRADAS

| Decisión | Razonamiento |
|---|---|
| Directions API en lugar de Distance Matrix | Directions devuelve `overview_polyline` necesaria para dibujar la ruta en Flutter; Distance Matrix solo devuelve texto |
| Tarifas leídas desde Firestore en runtime | Permite modificarlas desde el panel admin sin redesplegar la Cloud Function |
| Fallback hardcodeado como contingencia | Si Firestore /config falla (outage), el sistema sigue operando con los valores del Módulo 1 |
| Haversine × 1.35 como contingencia de Maps | Mejor dar una cotización aproximada que bloquear al usuario con un error |
| `polyline: null` cuando Maps falla | El frontend degrada gracefully: muestra la cotización sin dibujar la ruta |
| Vigencia de 10 minutos por cotización | Protege contra cambios de tarifa entre el presupuesto y la confirmación |
| Registro en `/quotations` | Trazabilidad auditora: saber cuántos presupuestos se generaron vs. cuántos se confirmaron (métrica de conversión) |
| Distancia mínima de 1 km | Protege la viabilidad económica del chofer en viajes muy cortos |
| API Keys separadas por entorno | Principle of least privilege: la key de Flutter no puede llamar a Directions API |

---

## 14. PENDIENTES PARA MÓDULO 3B (UI de Cotización Flutter)

| Componente | Descripción |
|---|---|
| `MapsService` | Wrapper de `geolocator` + llamada a `cotizarViajeFretix` + estado de la cotización |
| `CotizacionScreen` | Mapa con polilínea + card de presupuesto expandible + botón "Confirmar viaje" |
| `AddressSearchBar` | Búsqueda por texto con Places Autocomplete para selección sin GPS |
| `ParadasManager` | Widget para agregar/reordenar paradas intermedias (drag & drop) |
| `CotizacionCard` | Desglose visual del precio: base, km, minutos, ayudante, comisión (solo visible para chofer independiente) |

---

*Documento de referencia técnica — Módulo 3 aprobado.*
*Adjuntar junto a los módulos anteriores para contexto completo de Fretix.*
