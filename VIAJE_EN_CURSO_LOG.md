# VIAJE_EN_CURSO_LOG.md
## Módulo: Viaje en Curso — Feature branch `feature-viaje-en-curso-20260905`

---

## TAREA 0 — Verificación previa (evidencia real)

### Hallazgo 1 — ETA en BuscandoChoferScreen: NO es hardcodeado

**Archivo**: `lib/screens/customer/buscando_chofer_screen.dart:106`

```dart
final duracion = (data['cotizacion'] as Map<String, dynamic>?)?['duracionMin'] as num?;
// ...
etaMin: duracion?.round(),
// ...
Text('ETA estimada: $etaMin min')  // línea 193
```

**Conclusión**: El ETA se lee del campo `cotizacion.duracionMin` en el documento `/viajes/{viajeId}`. Este campo fue escrito por `cotizarViajeFretix` (Cloud Function) usando la API de Google Maps al momento de la cotización. **No es hardcodeado**, pero tampoco es un ETA en tiempo real basado en posición GPS actual del chofer. Es la duración estimada del viaje en el momento de la cotización — una aproximación estática.

**Impacto para TAREA 4**: El ETA mostrado no cambia mientras el chofer se acerca. El diseño de GPS en tiempo real (TAREA 5) puede resolver esto en el futuro.

---

### Hallazgo 2 — Datos de contacto en /users/{uid} y restricciones Firestore

**Comando ejecutado**:
```bash
grep -n "phone\|displayName\|email\|photoURL" functions/src/onboarding.js
grep -A8 "match /users/" firestore.rules
```

**Campos escritos por `onboarding.js` en `/users/{uid}`**:
- `uid` (string)
- `phone` (del token Firebase Auth: `request.auth.token.phone_number`)
- `displayName` (del perfil Auth)
- `email` (del perfil Auth)
- `photoURL: null`
- `roles`, `onboardingRole`, `createdAt`, `isActive`, `isVerified`

**Regla de Firestore para `/users/{userId}`**:
```
allow read: if isAuth() && (isOwner(userId) || isAdmin());
```

**Conclusión**: El teléfono SÍ está guardado en `/users/{uid}`, pero la regla bloquea lecturas cruzadas entre usuarios. Un chofer **NO puede** leer `/users/{clienteUid}` desde el cliente Flutter, y un cliente **NO puede** leer `/users/{choferUid}`.

**Solución adoptada (sin cambio de reglas)**: En `aceptarViajeFretix` (Cloud Function — admin SDK, bypasea reglas), al aceptar el viaje se leen ambos documentos de usuario y se desnormalizan en el viaje:
```
viaje.choferData = { displayName, photoURL, phone, categoriaVehiculo }
viaje.clienteData = { displayName, phone }
```
Esto permite que ambas pantallas (`ViajeActivoScreen` y `BuscandoChoferScreen`) muestren datos de contacto leyendo solo el documento del viaje, sin cross-user reads en el cliente.

**Decisión pendiente del CPO**: ¿Mostrar el teléfono completo o una versión mascarada (ej: +549261****001)?

---

### Hallazgo 3 — `geolocator` no tiene uso real en el código

**Comando ejecutado**:
```bash
grep -rn "geolocator\|Geolocator\|getCurrentPosition\|getPositionStream" lib/
# Output: 0 resultados
```

**Conclusión**: `geolocator` está declarado en `pubspec.yaml` pero NO se usa en ningún archivo Dart. Es una dependencia inactiva. El módulo de GPS se diseña en TAREA 5 (solo documento de diseño, sin implementación en esta iteración).

---

## TAREA 1 — Cloud Functions del ciclo de vida

### Funciones creadas

| Función | Archivo | Transición |
|---|---|---|
| `iniciarViajeFretix` | `functions/src/iniciar_viaje.js` | `aceptado → en_curso` |
| `finalizarViajeFretix` | `functions/src/finalizar_viaje.js` | `en_curso → completado` |
| `cancelarViajeFretix` | `functions/src/cancelar_viaje.js` | `pending/aceptado → cancelado` |

### Cambios en `aceptarViajeFretix`

- **TAREA 2**: Antes de la transacción, consulta si el chofer ya tiene un viaje `aceptado` o `en_curso`. Si existe, lanza `failed-precondition`.
- **Datos de contacto**: Lee `/users/{clienteUid}` con admin SDK y desnormaliza `clienteData` en el viaje.
- **Categoría del vehículo**: Agrega `categoriaVehiculo` al `choferData` del viaje.

### Campos nuevos en el documento `/viajes/{viajeId}`

```
estado: 'pending' | 'aceptado' | 'en_curso' | 'completado' | 'cancelado'
iniciadoEn:    Timestamp  (setea iniciarViajeFretix)
completadoEn:  Timestamp  (setea finalizarViajeFretix)
canceladoEn:   Timestamp  (setea cancelarViajeFretix)
canceladoPor:  string uid (setea cancelarViajeFretix)
canceladoPorRol: 'cliente' | 'chofer'

choferData: {
  displayName: string | null
  photoURL:    string | null
  phone:       string | null   ← nuevo
  categoriaVehiculo: string | null  ← nuevo
}

clienteData: {           ← nuevo (completo)
  displayName: string | null
  phone:       string | null
}
```

### Reglas Firestore — sin cambios

El documento `/viajes/{viajeId}` ya tiene la regla correcta:
```
allow read: if isAuth() && (
  resource.data.estado     == 'pending'        ||
  resource.data.clienteUid == request.auth.uid ||
  resource.data.choferUid  == request.auth.uid ||
  isAdmin()
);
```
- Chofer asignado puede leer el viaje en cualquier estado ✓
- Cliente puede leer el viaje en cualquier estado ✓
- `allow update: if false` — todas las transiciones pasan por CFs ✓

**No se requiere aprobación del CPO para esta tarea** (sin cambios a `firestore.rules`).

---

## TAREA 2 — Bloqueo de matcheo durante viaje activo

### CF: `aceptarViajeFretix`

Se agrega query antes de la transacción:
```js
const activoSnap = await db.collection('viajes')
  .where('choferUid', '==', uid)
  .where('estado', 'in', ['aceptado', 'en_curso'])
  .limit(1)
  .get();

if (!activoSnap.empty) {
  throw new HttpsError('failed-precondition', 'Ya tenés un viaje en curso.');
}
```

### Flutter: `_ChoferGuard` en `app_router.dart`

Al navegar a `/home/chofer`, el guard carga en paralelo: perfil de usuario, vehículo, y viaje activo. Si hay viaje activo, navega a `ViajeActivoScreen` en lugar de `HomeChoferScreen`.

---

## TAREA 3 — Pantalla ViajeActivoScreen (chofer)

**Archivo**: `lib/screens/chofer/viaje_activo_screen.dart`
**Ruta**: `AppRouter.viajeActivo = '/chofer/viaje_activo'` (argumento: `String viajeId`)

**Estados y botones**:

| Estado del viaje | Botón primario | Botón secundario |
|---|---|---|
| `aceptado` | Iniciar viaje → `iniciarViajeFretix` | Cancelar viaje → `cancelarViajeFretix` |
| `en_curso` | Finalizar viaje → `finalizarViajeFretix` | (ninguno) |
| `completado` | Auto-navega a homeChofer después de 2s | — |
| `cancelado` | Auto-navega a homeChofer después de 2s | — |

**Datos mostrados** (del documento viaje):
- Origen y destino (con addresses)
- Nombre del cliente (`clienteData.displayName`)
- Teléfono del cliente (`clienteData.phone`) — sujeto a decisión CPO sobre mascarado
- Badge de estado

---

## TAREA 4 — BuscandoChoferScreen actualizada

**Archivo**: `lib/screens/customer/buscando_chofer_screen.dart`

**Estados ahora manejados**:

| Estado | Comportamiento |
|---|---|
| `pending` | Spinner "buscando chofer..." + botón cancelar |
| `aceptado` | Muestra info del chofer (nombre, foto, ETA, categoría vehículo) |
| `en_curso` | Muestra "Viaje en curso" con datos del chofer |
| `completado` | Muestra pantalla de finalización, botón volver a home |
| `cancelado` | Muestra mensaje de cancelación, botón volver a home |

**Botón cancelar** (cliente): disponible en estados `pending` y `aceptado`. Llama `cancelarViajeFretix`.

**Categoría del vehículo**: se muestra desde `choferData.categoriaVehiculo` (disponible desde `aceptado`).

---

## TAREA 5 — DISEÑO: Tracking GPS en tiempo real (no implementado)

### Objetivo
Actualizar la posición del chofer durante el viaje para mostrar ETA real al cliente y mapa de seguimiento.

### Frecuencia de actualización propuesta
- **Durante `aceptado`** (chofer en camino al origen): cada 15 segundos
- **Durante `en_curso`** (viaje en progreso): cada 10 segundos
- **Batería/ancho de banda**: usar `getPositionStream` de `geolocator` con `distanceFilter: 50` (metros) como condición mínima de cambio antes de escribir.

### Ubicación de almacenamiento en Firestore
```
/viajes/{viajeId}/tracking/{timestamp}  ← subcolección (descartado: caro en lecturas)

# Alternativa adoptada en diseño:
/viajes/{viajeId}.ubicacionChofer = { lat, lng, actualizadoEn }  ← campo en el doc principal
```

**Razonamiento**: campo en el doc principal → el cliente ya tiene un `StreamBuilder` sobre el doc → cero lecturas adicionales para recibir actualizaciones de ubicación. La subcolección requeriría un segundo stream.

**Límite de escrituras**: 1 write/15s × 3600s = 240 writes/viaje en el peor caso. A $0.06/100K escrituras ≈ $0.000144/viaje. Aceptable.

### Permisos Firestore necesarios (requieren aprobación del CPO antes de implementar)

**Cambio propuesto** a `firestore.rules`, solo bajo `/viajes/{viajeId}`:
```
// PROPUESTA — pendiente aprobación CPO
// Permite al chofer asignado actualizar SOLO el campo ubicacionChofer
allow update: if isAuth()
  && resource.data.choferUid == request.auth.uid
  && request.resource.data.diff(resource.data).affectedKeys()
       .hasOnly(['ubicacionChofer']);
```

**Tabla de impacto**:
| Colección | Lectura | Escritura | Cambio |
|---|---|---|---|
| `/viajes/{viajeId}` | Sin cambio | Chofer puede actualizar `ubicacionChofer` únicamente | Nuevo `allow update` condicional |
| `/users/*` | Sin cambio | Sin cambio | Ninguno |
| `/vehiculos/*` | Sin cambio | Sin cambio | Ninguno |
| Resto | Sin cambio | Sin cambio | Ninguno |

**Decisión pendiente del CPO**: Aprobar o rechazar el cambio propuesto a `firestore.rules`.

### Permisos de plataforma
- **Web**: `navigator.geolocation` (API nativa) — requiere `https://` en producción (ya cumplido)
- **Móvil futuro**: `geolocator` pide `ACCESS_FINE_LOCATION` (Android) / `NSLocationWhenInUseUsageDescription` (iOS)

### Cálculo de ETA en tiempo real
- **Opción A (simple)**: distancia Haversine entre `ubicacionChofer` y `destino.lat/lng`, dividida por velocidad promedio promovida (30 km/h urbano).
- **Opción B**: re-llamar `cotizarViajeFretix` con la posición actual como nuevo origen. Más preciso pero $0.005/llamada Maps.
- **Decisión pendiente del CPO**: Opción A (gratuita) vs Opción B (costo real).

### Ciclo de vida del tracking
```
ViajeActivoScreen.initState() → iniciar stream de posición
  → onPositionUpdate → escribir viaje.ubicacionChofer (rate-limited)
ViajeActivoScreen.dispose() → cancelar stream (previene writes fantasma)
completadoEn / canceladoEn → dispose automático por navegación
```

---

## TAREA 6 — Tests end-to-end

**Archivo**: `functions/test/viaje_lifecycle.test.js`

**Cobertura**:
1. Ciclo completo: `pending → aceptado → en_curso → completado`
2. Ciclo con cancelación por cliente (desde pending)
3. Ciclo con cancelación por chofer (desde aceptado)
4. Bloqueo de matcheo: chofer con viaje activo no puede aceptar segundo viaje
5. Transiciones inválidas: iniciar viaje no aceptado, finalizar viaje pending, cancelar viaje completado

**Requisito de ejecución**:
```bash
cd functions
firebase emulators:start --only firestore,auth &
npm test -- --testPathPattern=viaje_lifecycle
```

---

## Decisiones pendientes del CPO

| ID | Descripción | Bloquea |
|---|---|---|
| CPO-DP-01 | Teléfono completo vs mascarado en pantalla de contacto | TAREA 3/4 (UI) |
| CPO-DP-02 | Aprobar regla Firestore para tracking GPS (TAREA 5) | TAREA 5 implementación |
| CPO-DP-03 | ETA tiempo real: Haversine (gratis) vs re-cotización Maps ($) | TAREA 5 implementación |

---

## Historial de cambios

| Fecha | Tarea | Descripción |
|---|---|---|
| 2026-09-05 | TAREA 0 | Verificación ETA, /users rules, geolocator — 3 hallazgos con evidencia |
| 2026-09-05 | TAREA 1 | CFs iniciar/finalizar/cancelar + update aceptar |
| 2026-09-05 | TAREA 2 | Bloqueo chofer en CF + _ChoferGuard redirect |
| 2026-09-05 | TAREA 3 | ViajeActivoScreen + ruta /chofer/viaje_activo |
| 2026-09-05 | TAREA 4 | BuscandoChoferScreen: 5 estados + botón cancelar |
| 2026-09-05 | TAREA 5 | Diseño GPS (no implementado — awaiting CPO-DP-02/03) |
| 2026-09-05 | TAREA 6 | Tests ciclo de vida en emulador |
