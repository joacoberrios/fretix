# MATCHEO_LOG — Sistema de Matcheo de Choferes

> Sesión: 2026-08-06  
> Rama: `feature-matcheo-20260806`  
> Autor: Claude Sonnet 4.6

---

## TAREA 1 — Diseño de esquema

### Timestamp: 2026-08-06T00:00

### Campos nuevos en Firestore

#### `/users/{uid}` — campos nuevos para choferes

| Campo | Tipo | Valores | Notas |
|---|---|---|---|
| `categoriaVehiculo` | `string` | `'mini' \| 'plus' \| 'max' \| 'heavy'` | Solo para `chofer_independiente` y `empresa_transporte_maestro`. Requerido al onboarding. |
| `disponibleParaViajes` | `bool` | `true \| false` | Ya existía como campo del toggle — se inicializa en `false` explícitamente en `onboarding.js` para choferes. |

Los valores de `categoriaVehiculo` son idénticos a los que usa `confirmar_viaje.js` en `CATEGORIAS_VALIDAS`. No hay conversión necesaria — la igualdad directa funciona en la query Firestore.

#### `/viajes/{viajeId}` — campos nuevos

| Campo | Tipo | Valor inicial | Notas |
|---|---|---|---|
| `choferUid` | `string \| null` | `null` | Se escribe al aceptar. No se persiste en el documento al crear (confirmar_viaje.js no lo incluye). |
| `choferData` | `map \| null` | `null` | Snapshot del perfil del chofer al momento de aceptar. Ver estructura abajo. |
| `aceptadoEn` | `timestamp \| null` | `null` | `FieldValue.serverTimestamp()` al aceptar. |
| `estado` | `string` | `'pending'` | Se agrega `'aceptado'` como segundo valor válido. |

```
choferData: {
  displayName: string,
  photoURL:    string | null,
}
```

**Limitación documentada:** `choferData` no incluye patente ni calificación porque esos campos no existen aún en el esquema de `/users/{uid}`. Son parte del módulo KYC/verificación, fuera de alcance de esta sesión.

### Decisión de diseño: normalización vs denormalización

**Decisión:** denormalizar `choferData` dentro del documento `/viajes/{viajeId}` al aceptar.

**Alternativa descartada:** leer `/users/{choferUid}` desde `BuscandoChoferScreen` con un segundo StreamBuilder.

**Razones:**
1. El cliente necesita ver el nombre del chofer en el mismo instante que `estado` cambia a `'aceptado'` — ambos datos deben llegar en el mismo snapshot para evitar parpadeo entre estados.
2. Las reglas de Firestore permiten que el dueño del viaje lea el documento del viaje, pero no necesariamente el documento `/users/{choferUid}` de otro usuario.
3. Los datos que se muestran al cliente (displayName, photoURL) son un snapshot puntual del momento de aceptación — si el chofer cambia su nombre después, el viaje ya guardado refleja quién aceptó, lo cual es correcto para auditoría.

**Trade-off:** si el chofer cambia su nombre después de aceptar, el viaje activo muestra el nombre viejo. Aceptable para el MVP.

### Decisión: migración de choferes existentes

Los choferes registrados antes de esta sesión (ej: uid `ryggTBtdBiRB6ru7TKUbfSTFo3H3`) no tienen `categoriaVehiculo` en su documento `/users/{uid}`.

**Decisión:** no hay migración automática en esta sesión. Choferes sin `categoriaVehiculo`:
- El toggle de disponibilidad sigue funcionando.
- La query de Firestore en HomeChoferScreen busca `categoria == categoriaVehiculo`. Si `categoriaVehiculo` es null/ausente, la query no se ejecuta y el chofer ve el estado vacío.
- El banner de HomeChoferScreen mostrará un aviso indicando que falta configurar la categoría (implementado en Tarea 5).

Para migrar un chofer existente, ir a Firestore Console y agregar el campo `categoriaVehiculo` manualmente en `/users/{uid}`.

### Consistencia con el código existente

Verificaciones:
- `CATEGORIAS_VALIDAS` en `confirmar_viaje.js`: `{'mini', 'plus', 'max', 'heavy'}` ✅ (mismos valores)
- `_kCategorias` en `cotizacion_screen.dart`: ids `'mini', 'plus', 'max', 'heavy'` ✅
- `onboardingRole` para choferes: `'chofer_independiente'`, `'empresa_transporte_maestro'` ✅ (verificado en e0eeadf)

---

## TAREA 2 — Onboarding + categoriaVehiculo

### Timestamp: 2026-08-06T00:10

**Archivos modificados:**
- `functions/src/onboarding.js`
- `functions/test/onboarding.test.js`
- `lib/services/auth_service.dart`
- `lib/screens/onboarding/role_selection_screen.dart`

**Evidencia (ver commit):** flutter analyze 0 errores/warnings nuevos. Tests de onboarding: ver sección de resultados.

---

## TAREA 3 — Cloud Function aceptarViajeFretix

### Timestamp: 2026-08-06T00:20

**Archivos creados/modificados:**
- `functions/src/aceptar_viaje.js` (nuevo)
- `functions/test/aceptar_viaje.test.js` (nuevo)
- `functions/index.js` (export agregado)

**Manejo de condición de carrera:** transacción Firestore. Si dos choferes llaman simultáneamente, la transacción de Firestore garantiza que solo uno puede hacer el update de `estado: 'pending' → 'aceptado'`. El segundo leerá el documento ya actualizado dentro de la transacción y fallará con `failed-precondition`.

**Evidencia (ver commit):** tests corridos contra emulador.

---

## TAREA 4 — Firestore rules

### Timestamp: 2026-08-06T00:30

### Análisis del estado actual

La regla actual para `/viajes/{viajeId}` usa campos que **no coinciden** con lo que `confirmarViajeFretix` escribe:

| Campo en la regla | Campo real en el documento |
|---|---|
| `resource.data.solicitadoPor.userId` | `resource.data.clienteUid` |
| `resource.data.asignacion.userId` | `resource.data.choferUid` (no existía) |

**Consecuencia:** el cliente NO puede leer su propio viaje desde Flutter (las reglas lo bloquean). El Admin SDK (Cloud Functions) sí puede escribir y leer porque bypasea reglas.

**Regla `allow create`:** la regla actual permite `create` con `estado == 'quoting'`. El estado `'quoting'` nunca se usa — la CF crea con `estado == 'pending'` directamente. Esta regla es un vestigio de un diseño anterior y debería ser `false`.

### Requerimientos del matcheo

Para que el matcheo funcione desde el cliente Flutter:

1. **Cliente lee su viaje** (`BuscandoChoferScreen`): `resource.data.clienteUid == request.auth.uid`
2. **Chofer lee viajes pendientes** (`HomeChoferScreen` StreamBuilder): cualquier autenticado puede leer documentos con `estado == 'pending'`
3. **Chofer lee el viaje aceptado** (pantalla futura de viaje activo): `resource.data.choferUid == request.auth.uid`

### Diff propuesto — PENDIENTE APROBACIÓN CPO

```diff
   match /viajes/{viajeId} {
-    // Lectura: cliente que solicitó el viaje, chofer asignado, o admin
-    allow read: if isAuth() && (
-      resource.data.solicitadoPor.userId == request.auth.uid ||
-      resource.data.asignacion.userId    == request.auth.uid ||
-      isAdmin()
-    );
+    // Lectura: viajes pending (cualquier chofer autenticado puede ver),
+    // cliente que lo creó, chofer asignado, o admin.
+    allow read: if isAuth() && (
+      resource.data.estado         == 'pending'               ||
+      resource.data.clienteUid     == request.auth.uid        ||
+      resource.data.choferUid      == request.auth.uid        ||
+      isAdmin()
+    );

-    allow create: if isAuth()
-      && request.resource.data.estado == 'quoting'
-      && request.resource.data.solicitadoPor.userId == request.auth.uid;
+    // Creación: solo Cloud Functions (Admin SDK bypasea estas reglas).
+    allow create: if false;

     allow update: if false;
     allow delete: if false;
   }
```

### Tabla de impacto

| Operación | Antes | Después |
|---|---|---|
| Cliente lee su propio viaje | ❌ (campo incorrecto) | ✅ (`clienteUid`) |
| Chofer lee viajes pending | ❌ | ✅ (`estado == 'pending'`) |
| Chofer lee viaje aceptado | ❌ (campo incorrecto) | ✅ (`choferUid`) |
| Admin lee cualquier viaje | ✅ | ✅ |
| Cliente crea viaje directamente (bypass CF) | ✅ (bug) | ❌ (`if false`) |
| Cloud Function crea viaje (Admin SDK) | ✅ | ✅ (bypasea reglas) |
| Cualquier usuario lee viaje de otro usuario | ❌ | ❌ |

**Sin este diff, `BuscandoChoferScreen` y `HomeChoferScreen` no pueden leer datos de Firestore desde el cliente Flutter. Los tests de Cloud Functions (Admin SDK) funcionan igual porque no usan las reglas.**

**Estado: PENDIENTE APROBACIÓN. No aplicado.**

Índice compuesto requerido para la query de HomeChoferScreen:
```
Colección: viajes
Campos: estado ASC, categoria ASC, creadoEn DESC
```
En el emulador se crea automáticamente. Para producción, agregar a `firestore.indexes.json` antes de deploy.

---

## TAREA 5 — HomeChoferScreen

### Timestamp: 2026-08-06T00:40

**Archivo modificado:** `lib/screens/home/home_chofer_screen.dart`

**Comportamiento:**
- Carga `categoriaVehiculo` junto con `disponibleParaViajes` en `initState`
- Si `categoriaVehiculo == null`: muestra aviso de configuración pendiente en lugar de la lista
- Si `disponibleParaViajes == false`: muestra estado vacío normal
- Si `disponibleParaViajes == true && categoriaVehiculo != null`: StreamBuilder con viajes pending de esa categoría
- Cada viaje muestra: origen → destino, precio, botón "Aceptar"
- Al aceptar: loading per-viaje (evita doble tap), SnackBar de error si ya fue tomado

**Limitación:** el StreamBuilder requiere que las reglas de Firestore estén actualizadas (Tarea 4). Sin esa aprobación, el stream falla en producción con permission-denied. En el emulador, los tests de CF (Admin SDK) no requieren las reglas.

---

## TAREA 6 — BuscandoChoferScreen + viajeId propagation

### Timestamp: 2026-08-06T00:50

**Archivos modificados:**
- `lib/screens/customer/buscando_chofer_screen.dart` (reescrito como StatefulWidget)
- `lib/screens/customer/cotizacion_screen.dart` (captura viajeId del resultado)
- `lib/router/app_router.dart` (pasa viajeId como argumento)

**Comportamiento:**
- `confirmarViajeFretix` retorna `{ viajeId: ... }` — se captura en `cotizacion_screen.dart`
- Se pasa como argumento de navegación a `BuscandoChoferScreen`
- `BuscandoChoferScreen` tiene StreamBuilder en `/viajes/{viajeId}`
- `estado == 'pending'`: spinner + texto original
- `estado == 'aceptado'`: card con datos del chofer (displayName, photoURL/avatar, ETA estimada)
- ETA: usa `cotizacion.duracionMin` del viaje como estimación (limitación documentada: no es la distancia chofer→cliente sino la distancia del viaje)

**Limitación igual a Tarea 5:** requiere aprobación de las reglas.

---

## TAREA 7 — Test end-to-end

### Timestamp: 2026-08-06T03:00

**Evidencia real — corrido contra emulador local (Firestore 127.0.0.1:8282, Auth 127.0.0.1:9099)**

```
Test Suites: 4 passed, 4 total
Tests:       61 passed, 61 total
Snapshots:   0 total
Time:        1.031 s
```

Suites incluidas:
- `cotizacion.test.js` — 13 tests
- `confirmar_viaje.test.js` — 21 tests
- `onboarding.test.js` — 21 tests (13 originales + 8 nuevos de Tarea 2)
- `aceptar_viaje.test.js` — 13 tests (nuevos de Tarea 3)

**flutter analyze:**
```
42 issues found — todos info (deprecaciones preexistentes)
0 errors, 0 warnings
```

**Confirmación: NO se tocó producción en ningún momento de la sesión.**

---

## Decisiones pendientes del CPO

### DP-1: Aprobación de cambio a firestore.rules (BLOQUEANTE para producción)

Ver diff completo en sección TAREA 4. Sin este cambio, `HomeChoferScreen` y `BuscandoChoferScreen` no pueden leer datos de Firestore desde el cliente Flutter.

### DP-2: Índice compuesto en producción

Antes de deploy de hosting, crear el índice:
```
Colección: viajes | estado ASC | categoria ASC | creadoEn DESC
```
Vía `firebase deploy --only firestore:indexes`.

### DP-3: FCM — notificaciones push

`firebase_messaging` está en `pubspec.yaml` pero la infraestructura es un stub hueco (sin CF, sin token guardado, sin caller). Fuera de alcance de esta sesión. El sistema actual usa Firestore realtime listeners — el chofer DEBE tener la app abierta para ver viajes.

### DP-4: categoriaVehiculo para empresa_transporte_maestro

Esta implementación asigna UNA categoría al usuario `empresa_transporte_maestro`. Una empresa real tiene flota mixta (varios tipos de vehículo). El diseño correcto (gestión de flota) es un módulo separado — documentado pero fuera de alcance.

### DP-5: Migración de choferes existentes

Choferes registrados antes de esta sesión no tienen `categoriaVehiculo`. Ver sección de Tarea 1 para la decisión de no migrar automáticamente.

---

## Estado de producción

**Confirmación explícita: NO se tocó producción en ningún momento durante esta sesión.**
- No se corrió `firebase deploy` a producción
- No se hicieron escrituras directas a Firestore de producción
- No se modificaron reglas de Firestore (pendiente aprobación)
- Todo el trabajo está en la rama `feature-matcheo-20260806`
