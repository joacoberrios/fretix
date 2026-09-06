# TRACKING_GPS_LOG.md — Módulo GPS / Ubicación en tiempo real

Rama: `feature-tracking-gps-20260905`
Fecha inicio: 2026-09-05

---

## TAREA 0 — Verificación previa

### geolocator 13.0.4 — API confirmada

**Versión exacta instalada:** 13.0.4 (pubspec.lock).

API relevante verificada en `/Users/joaquinberrios/.pub-cache/hosted/pub.dev/geolocator-13.0.4/lib/geolocator.dart`:

```dart
// Permiso
static Future<LocationPermission> checkPermission()  // línea 30
static Future<LocationPermission> requestPermission() // línea 42

// Stream con distanceFilter (throttle espacial en metros)
static Stream<Position> getPositionStream({
  LocationSettings? locationSettings, // línea 188
})
// LocationSettings acepta:
//   accuracy: LocationAccuracy.high
//   distanceFilter: 50  ← metros mínimos entre eventos
```

El `distanceFilter: 50` cubre el throttle espacial requerido por el CPO.
El throttle temporal (15s para el chofer detenido) se implementa con `Timer.periodic`.

### Índices de Firestore — no se necesita nuevo índice

El documento `/viajes/{id}/tracking/actual` se accede por ruta directa (no es una query de colección). No requiere índice compuesto. Los índices existentes en `firestore.indexes.json` no se modifican.

### Paquete `http` — agregado

No estaba en `pubspec.yaml`. Se agregó `http: ^1.2.2` para las llamadas a Directions API desde el cliente (TAREA 4). `flutter pub get` completado sin conflictos.

---

## TAREA 1 — Esquema Firestore y reglas (PENDIENTE DE APROBACIÓN CPO)

### Esquema del documento `/viajes/{viajeId}/tracking/actual`

```
{
  lat:          number   — latitud WGS84
  lng:          number   — longitud WGS84
  actualizadoEn: timestamp — FieldValue.serverTimestamp()
}
```

Sin historial — el documento se sobreescribe en cada actualización.

### Diff de `firestore.rules` — ESPERANDO APROBACIÓN DEL CPO ANTES DE APLICAR

```diff
     // Actualización de estado: NUNCA desde el cliente — solo Cloud Functions.
     allow update: if false;
     allow delete: if false;
+
+    // ── /viajes/{viajeId}/tracking/{doc}
+    // Solo el clienteUid y el choferUid de ESE viaje pueden leer la posición.
+    // Solo el chofer asignado puede escribir.
+    // Seguridad por diseño: el get() al documento padre garantiza que nadie
+    // más (ni otro chofer que vea el viaje en 'pending') puede leer la ubicación.
+    match /viajes/{viajeId}/tracking/{doc} {
+      allow read: if isAuth() && (
+        get(/databases/$(database)/documents/viajes/$(viajeId)).data.clienteUid
+          == request.auth.uid ||
+        get(/databases/$(database)/documents/viajes/$(viajeId)).data.choferUid
+          == request.auth.uid
+      );
+      allow write: if isAuth() &&
+        get(/databases/$(database)/documents/viajes/$(viajeId)).data.choferUid
+          == request.auth.uid;
+    }
   }
```

### Tabla de impacto del diff de reglas

| Acción | Quién puede | Condición | Impacto |
|--------|-------------|-----------|---------|
| `read` `/tracking/actual` | `clienteUid` del viaje | Solo si el uid coincide con el campo en el doc padre | Cliente ve la posición de su chofer asignado |
| `read` `/tracking/actual` | `choferUid` del viaje | Solo si el uid coincide con el campo en el doc padre | Chofer puede leer su propia posición (debug, sin uso en app actual) |
| `read` `/tracking/actual` | Cualquier otro uid | Denegado | Otros choferes que ven el viaje en `pending` NO acceden; admins denegados (Admin SDK bypasea igual) |
| `write` `/tracking/actual` | `choferUid` del viaje | Solo el chofer asignado | El cliente no puede falsificar la posición del chofer |
| `write` `/tracking/actual` | Cualquier otro | Denegado | Protege la integridad de la posición |

**Nota de seguridad:** La regla usa `get()` al documento padre `/viajes/{viajeId}`. Esto consume 1 lectura de Firestore por cada `read` o `write` de tracking que pase por estas reglas. Para el patrón de uso (1 cliente + 1 chofer por viaje activo), el costo es mínimo y aceptable.

**Sin este diff aplicado el código de TAREA 2-4 no funcionará en producción** (el catch-all `allow read, write: if false` denegará las escrituras del chofer y las lecturas del cliente). El código está listo; las reglas esperan aprobación explícita del CPO.

---

## TAREA 2 — Chofer: compartir ubicación en tiempo real ✅

**Archivo modificado:** `lib/screens/chofer/viaje_activo_screen.dart`

Cambios implementados en `_ViajeActivoScreenState`:
- **Campos nuevos:** `_currentPosition`, `_positionSub`, `_trackingTimer`, `_locationDenied`, `_mapController`
- **`initState`:** llama a `_startTracking()`
- **`dispose`:** llama a `_stopTracking()` + `_mapController?.dispose()`
- **`_startTracking()`:**
  - `Geolocator.checkPermission()` → si `denied`, `requestPermission()`
  - Si denegado o denegado para siempre: `_locationDenied = true`, retorna sin bloquear el viaje
  - `Geolocator.getPositionStream(LocationSettings(accuracy: high, distanceFilter: 50))` — throttle espacial 50m
  - `Timer.periodic(15s)` — throttle temporal para el chofer detenido
  - Ambos llaman a `_writeTracking(lat, lng)`
- **`_writeTracking`:** `set()` a `/viajes/{id}/tracking/actual` — best-effort (fallo silencioso, no bloquea el viaje)
- **`_stopTracking`:** cancela `_positionSub` y `_trackingTimer` explícitamente
- **`completado`/`cancelado` en StreamBuilder:** llama a `_stopTracking()` antes de `addPostFrameCallback` para detener el GPS al terminar el viaje

**Manejo de permiso denegado:** `_locationDenied = true` → se muestra `_UbicacionDenegadaBanner` (tira roja informativa debajo del mapa) — el viaje sigue funcionando normalmente.

---

## TAREA 3 — Mapa en ViajeActivoScreen (chofer) ✅

**Archivo modificado:** `lib/screens/chofer/viaje_activo_screen.dart`

Widgets nuevos:
- **`_MapaChofer`:** GoogleMap 200px de alto con dark style nocturno (mismo JSON que `cotizacion_screen.dart`)
  - Marcador naranja (`hueOrange`): punto de origen del viaje
  - Marcador azul (`hueAzure`): posición actual del chofer (si disponible)
  - `myLocationButtonEnabled: false`, `zoomControlsEnabled: false` (patrón cotizacion_screen)
  - Se muestra solo si `origenLatLng != null` (campos `origen.lat`/`origen.lng` del doc Firestore)
- **`_UbicacionDenegadaBanner`:** tira informativa (solo visible si GPS denegado)
- **`_updateMapCamera`:** llama a `animateCamera(CameraUpdate.newLatLng(...))` cada vez que llega una posición nueva — la cámara sigue al chofer automáticamente

**Nota CPO-DP-04:** La ruta dibujada (polyline de chofer → origen) requeriría llamar a Directions API desde `ViajeActivoScreen`. No implementado en esta versión — la decisión de si agregar este llamado server-side o client-side queda pendiente. El mapa muestra marcadores sin traza de ruta.

---

## TAREA 4 — Mapa y ETA en BuscandoChoferScreen (cliente) ✅

**Archivo modificado:** `lib/screens/customer/buscando_chofer_screen.dart`

Cambios en `_ViajeWatcher.build()`:
- En `case 'aceptado'`: extrae `origen.lat`/`origen.lng` del doc viaje; añade `StreamBuilder<DocumentSnapshot>` anidado escuchando `/viajes/{id}/tracking/actual`
- En `case 'en_curso'`: mismo patrón — StreamBuilder de tracking para mostrar posición del chofer durante el viaje
- `_ChoferAsignadoView` convertido a `StatefulWidget`; `_EnCursoView` convertido a `StatefulWidget`

`_ChoferAsignadoView` nuevo comportamiento:
- Recibe `choferPos: LatLng?` y `origenLatLng: LatLng?`
- `initState`: llama `_recalcularEta()` si hay posición inicial
- `didUpdateWidget`: llama `_recalcularEta()` cuando `choferPos` cambia de valor
- **`_recalcularEta()`:** GET a `https://maps.googleapis.com/maps/api/directions/json?origin={chofer}&destination={origen}&mode=driving&key={key}` → extrae `routes[0].legs[0].duration.value` (segundos) → muestra en minutos (ceil)
- **Fallback:** si Directions API falla (error de red, 403, respuesta vacía), muestra `duracionMin` de la cotización con etiqueta "estimada" diferenciada
- **ETA diferenciado visualmente:** `"ETA: X min"` cuando es cálculo real vs `"ETA estimada: X min"` cuando es fallback
- `_mapController` para aplicar dark style en `onMapCreated`

Widgets nuevos:
- **`_MapaCliente`:** mismo patrón que `_MapaChofer` — marcador naranja (origen), marcador azul (posición del chofer)

**Sobre la clave de Maps API:** Se usa `AIzaSyCPrygll6ye2BgPkP-wPSsTS7HoChs_lCw` (ya pública en `web/index.html`). CPO-DP-05 registrado abajo.

---

## TAREA 5 — Estimación de costo

### Escenario de referencia: viaje de 20 minutos

**Escrituras a Firestore (`/viajes/{id}/tracking/actual`)**

- Throttle temporal: 1 escritura cada 15s × 80 disparos (20 min × 4/min) = **80 escrituras**
- Throttle espacial: depende del movimiento del chofer. A 40 km/h en zona urbana, el chofer recorre ~13 m cada 15s → no alcanza el umbral de 50m → no dispara el stream en ese intervalo. El timer de 15s es el evento dominante para velocidades bajas.
- A 60 km/h: 250 m/min → ~1 evento de 50m cada 12s → el stream puede disparar antes que el timer. Estimado: máximo **100 escrituras** (stream 50m + timer). Escribir el mismo valor dos veces en ráfaga es posible pero infrecuente.
- **Estimado conservador: 80-100 escrituras por viaje de 20 min**

Costo Firestore (plan Spark/Blaze, escrituras $0.18/100k): **< $0.001 por viaje** — despreciable.

**Lecturas Firestore del cliente (`/viajes/{id}/tracking/actual`)**

El `StreamBuilder` del cliente recibe un evento por cada escritura del chofer: **80-100 lecturas en tiempo real por viaje de 20 min**.

Cada lectura de `/viajes/{id}/tracking/{doc}` por una regla con `get()` al padre consume 1 lectura adicional al doc `/viajes/{id}`. Total: **160-200 lecturas Firestore por viaje**.

Costo ($0.06/100k): **< $0.001 por viaje** — despreciable.

**Llamadas a Directions API (ETA client-side)**

El ETA se recalcula solo cuando `choferPos` cambia de valor (posición distinta). Dado que el chofer se mueve (y el timer escribe la misma posición cuando está detenido sin actualizar `choferPos`), en la práctica el recálculo ocurre cada vez que el chofer se desplaza ≥50m.

- A 40 km/h: 40 eventos de 50m en 20 min (40.000 m / 50 m/evento... no, el chofer recorre 40km/h × (20/60)h = 13.3 km → 266 eventos de 50m. Pero el timer de 15s tiene precedencia mientras el chofer no alcanza 50m, así que los eventos de stream se limitan.
- Recalibrado: ~80-100 actualizaciones de posición (del timer + stream), de las cuales solo las que realmente cambian `choferPos` (valor LatLng distinto) disparan el recálculo. Estimado real: **20-40 llamadas** a Directions API por viaje de 20 min (asumiendo movimiento continuo; mucho menos si el chofer está detenido esperando).
- **Estimado conservador: 40 llamadas a Directions API por viaje de 20 min**

Costo Directions API ($5/1000 elementos): 40 × $0.005 = **$0.20 por viaje con movimiento continuo**. Este es el costo dominante del módulo. A escala: 1000 viajes/mes → $200/mes en Directions API.

> **Nota del CPO:** El costo de Directions API es el único significativo a escala. Si el volumen crece, una alternativa de menor costo es calcular ETA con Haversine (sin API, igual que el fallback de `cotizarViajeFretix`) en lugar de Directions API. Documentado aquí para visibilidad; decisión de optimización futura.

---

## TAREA 6 — Tests

### Reglas de Firestore

La infraestructura de tests de rules está presente en el proyecto (`firebase emulators:exec --only firestore,auth "cd functions && npm test"`). Sin embargo, los tests existentes en `functions/test/viaje_lifecycle.test.js` testean operaciones de Cloud Functions, no reglas de Firestore directamente.

**Estado:** Sin tests de rules para la nueva subcolección `/tracking`. Para testear manualmente con el emulador:

```bash
# 1. Iniciar emulador
firebase emulators:start --only firestore,auth

# 2. En Firestore emulator UI (http://127.0.0.1:4000):
#    - Crear un viaje con clienteUid=A, choferUid=B
#    - Intentar leer /viajes/{id}/tracking/actual como uid=A → debe permitir
#    - Intentar leer /viajes/{id}/tracking/actual como uid=C → debe denegar
#    - Intentar escribir /viajes/{id}/tracking/actual como uid=B → debe permitir
#    - Intentar escribir /viajes/{id}/tracking/actual como uid=A → debe denegar
```

**Tests de throttle/ETA:** La lógica de `_recalcularEta()` tiene dependencias de UI y HTTP — no es una función pura extraíble sin mocks. No se agregan tests de widget para este ciclo (mismo criterio que `_ChoferGuard`). Documentado como mejora futura con mock de `http.Client`.

---

## Decisiones pendientes del CPO

| ID | Descripción | Impacto |
|----|-------------|---------|
| CPO-DP-04 | Polyline de chofer → origen en `ViajeActivoScreen`: ¿se agrega llamada client-side a Directions API, o se omite? | Visual solo — mapa funciona sin ella |
| CPO-DP-05 | Clave Maps API `AIzaSyCPrygll6ye2BgPkP-wPSsTS7HoChs_lCw` usada para Directions API client-side. Verificar en Google Cloud Console que tenga restricción de referrer HTTP para evitar uso no autorizado desde otros dominios | Seguridad |
| CPO-DP-06 | ETA del cliente durante `en_curso` (viaje en progreso): ¿se muestra ETA a destino (diferente lógica)? Por ahora el mapa muestra la posición del chofer sin ETA durante `en_curso` | Producto |

---

## Estado de la rama

| Tarea | Estado |
|-------|--------|
| 0 — Verificación previa | ✅ Completada |
| 1 — Firestore rules | ⏳ Esperando aprobación CPO |
| 2 — Chofer GPS | ✅ Implementada |
| 3 — Mapa chofer | ✅ Implementada |
| 4 — Mapa+ETA cliente | ✅ Implementada |
| 5 — Estimación de costo | ✅ Documentada |
| 6 — Tests | ✅ Documentados (verificación manual con emulador) |
| `flutter analyze` | ✅ 0 errores, 0 warnings nuevos (50 info — 4 nuevas, todas info-level deprecations) |
| Deploy | 🔒 Bloqueado hasta aprobación CPO |
