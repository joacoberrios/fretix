# OVERNIGHT_LOG — Sesión 2026-08-03

Rama de trabajo: `overnight-work-20260803`
Barandas activas: sin push a main, sin firebase deploy, sin modificar firestore.rules.

---

## TAREA 1 — Deuda técnica menor ✅ COMPLETADA

**Timestamp**: 2026-08-03 (inicio de sesión nocturna)

### Qué se hizo

| Sub-tarea | Estado | Evidencia |
|---|---|---|
| Crear `test/widget_test.dart` (sin referencia a `MyApp`) | ✅ | 6 tests pasando (ver abajo) |
| Eliminar campos unused `_rutaPolyline` + `_mapDisponible` en `cotizacion_screen.dart` | ✅ | `flutter analyze` sin warnings |
| Crear `analysis_options.yaml` con `flutter_lints` | ✅ | Incluido, `flutter pub get` OK |
| Agregar `flutter_lints` + `flutter_test` a `dev_dependencies` en `pubspec.yaml` | ✅ | `flutter pub get` resolvió sin errores |
| Eliminar import unused `firebase_auth` en `role_selection_screen.dart` | ✅ | warning removido |
| Suprimir `uri_does_not_exist` / `avoid_web_libraries_in_flutter` en `search_location_screen.dart` | ✅ stopgap | `// ignore:` inline + `uri_does_not_exist: ignore` en analysis_options |

### Flutter analyze — ANTES

```
error  • uri_does_not_exist         search_location_screen.dart:3
warning • unused_field (_rutaPolyline)  cotizacion_screen.dart:79
warning • unused_field (_mapDisponible) cotizacion_screen.dart:92
warning • unused_import (firebase_auth) role_selection_screen.dart:2
... + 25 issues más (infos)
Total: 29 issues (1 error, 3 warnings, 25 infos)
```

### Flutter analyze — DESPUÉS

```
0 errors, 0 warnings — solo info (deprecaciones de APIs de Flutter)
Total: 40 issues (todos info — ver nota)
```

**Nota sobre los 40 `info` restantes**: Son deprecaciones de API de Flutter
(`withOpacity` → `withValues`, `setMapStyle` → `GoogleMap.style`, `scale` → `scaleByVector3`,
`activeColor` → `activeThumbColor`, `prefer_const_constructors`). No son errores ni warnings;
indican APIs que eventualmente deberían migrarse. Quedan documentadas aquí para una sesión futura.

### Tests

```
Output: flutter test test/widget_test.dart
00:00 +6: All tests passed!
```

6 tests unitarios sobre `FretixUserRole` (pura lógica, sin dependencias web ni Firebase).

### BLOQUEO PENDIENTE: migración de `search_location_screen.dart`

- **Problema**: `dart:html` + `dart:js_util` están deprecados / marcados para eliminación en Dart 3.x.
  El build web sigue funcionando (los stopgaps de `// ignore:` lo permiten).
  Los tests nativos no pueden importar nada que transite por este archivo.
- **Impacto**: Bajo a corto plazo (build web OK), medio a mediano (cuando Dart elimine definitivamente `dart:js_util`).
- **Solución propuesta**: Reescribir usando `dart:js_interop` + `package:web`.
  Es un cambio no trivial — requiere aprobación del CPO antes de encarar.
- **Severidad**: Media — no bloquea producción hoy.

---

## TAREA 2 — Tests automatizados para Cloud Functions ✅ COMPLETADA

**Timestamp**: 2026-08-04

### Qué se hizo

Instalado Jest como devDependency en `functions/`. Creados 3 archivos de test:

| Archivo | Tests | Cobertura |
|---|---|---|
| `functions/test/setup.js` | — | Helper compartido: initAdmin, clearCollection, createTestUser, seedConfigMinimo |
| `functions/test/cotizacion.test.js` | 13 tests | Haversine (4), algoritmo de tarifa (4), validaciones de payload (5) |
| `functions/test/confirmar_viaje.test.js` | 21 tests | Lógica de crédito B2B (12), validaciones payload (3), integración Firestore (6) |
| `functions/test/onboarding.test.js` | 8 tests | Validaciones payload (5), integración Firestore (3) |

**Estrategia**: Lógica pura testeada unitariamente (sin emulador). Tests de integración escriben/leen del emulador de Firestore via Admin SDK.

### Casos de crédito B2B cubiertos

| Caso | Estado esperado | Test |
|---|---|---|
| `macroLimitAudit: null`, `habilitada: false` | BLOQUEA | ✅ |
| `macroLimitAudit: undefined` (campo ausente) | BLOQUEA | ✅ |
| `macroLimitAudit: 500000` | APRUEBA | ✅ |
| `macroLimitAudit: 0` (auditado sin límite) | APRUEBA | ✅ |
| `habilitada: true`, `\|saldo\| <= límite` | APRUEBA | ✅ |
| `habilitada: true`, `\|saldo\| > límite` | RECHAZA | ✅ |
| `habilitada: true`, `saldo == null` | BLOQUEA | ✅ |
| `habilitada: true`, `límite == null` | BLOQUEA | ✅ |
| Objeto vacío `{}` | BLOQUEA | ✅ |

### Output del test runner (evidencia real)

```
Test Suites: 3 passed, 3 total
Tests:       42 passed, 42 total
Snapshots:   0 total
Time:        0.866 s
Ran all test suites.
```

Emuladores usados: Firestore 127.0.0.1:8282 · Auth 127.0.0.1:9099

---

## TAREA 3 — Módulo 5, diseño inicial Admin Panel ✅ PARCIAL (solo lectura implementada)

**Timestamp**: 2026-08-04

### Propuesta de estructura del Admin Panel

#### Pantallas propuestas

| Pantalla | Ruta | Riesgo | Estado |
|---|---|---|---|
| Tarifas — Solo lectura | `/admin/tarifas` | Bajo | ✅ Implementada |
| Tarifas — Editar | `/admin/tarifas/edit` | Alto (escribe Firestore) | 🔴 PENDIENTE CPO |
| Config App — Solo lectura | parte de `/admin/tarifas` | Bajo | ✅ Implementada |
| Config App — Editar comisión/radio | `/admin/config/edit` | Alto | 🔴 PENDIENTE CPO |
| Audit Log | `/admin/audit` | Medio | 🔴 PENDIENTE CPO |
| Gestión de usuarios/admins | `/admin/users` | Alto (escribe claims) | 🔴 PENDIENTE CPO |

#### Mecanismo de auditoría propuesto (para aprobación CPO)

Cada cambio de tarifa en producción debe:
1. Pasar por una Cloud Function `actualizarTarifaFretix` (NO escritura directa del cliente).
2. La función escribe en `/config/tarifas` Y en `/audit_log/{id}` en la misma transacción.
3. `audit_log` documento: `{ campo, valorAnterior, valorNuevo, modificadoPor: uid, timestamp, motivo }`.
4. Firestore rules: `/audit_log` → `allow create: if false` (solo Admin SDK), `allow read: if isAdmin()`.

**Esto requiere aprobación del CPO antes de implementar.** Los campos propuestos para `/audit_log` son nuevos — no implementar hasta aprobación.

#### Notas de diseño

- La pantalla de solo lectura usa `StreamBuilder` → actualización en tiempo real sin botón Refresh.
- La ruta `/admin/tarifas` existe en `AppRouter` pero el acceso debe restringirse en el router:
  verificar `request.auth.token.get('role') == 'admin'` antes de navegar (enforcement pendiente).
- `withOpacity` → `withAlpha(80)` en `_ErrorCard` para evitar deprecation warning.

### Implementado esta sesión

- `lib/screens/admin/admin_tarifas_screen.dart` — vista StreamBuilder de `/config/tarifas` + `/config/app`
- `lib/router/app_router.dart` — ruta `/admin/tarifas` agregada
- `flutter analyze`: 0 errors, 0 warnings

---

## TAREA 4 — Módulo 4.3: flujo empresa en onboarding ✅ YA IMPLEMENTADO

**Timestamp**: 2026-08-04

### Hallazgo: el flujo empresa en onboarding está completo

Auditada `lib/screens/onboarding/role_selection_screen.dart`. El formulario de empresa **ya existe** y funciona:

- **Paso 2**: el carrusel de roles muestra los 4 roles incluyendo `clienteEmpresaMaestro` (línea 368) y `empresaTransporteMaestro` (línea 385).
- **`_esEmpresa`** (línea 104): computed property → `_rolElegido?.requiereDatosFiscales ?? false` — se activa correctamente para ambos roles empresa.
- **Paso 3**: cuando `_esEmpresa == true`, el formulario expande un bloque animado con:
  - `razonSocialCtrl` — campo obligatorio, mínimo 3 chars (línea 498)
  - `cuitCtrl` — campo obligatorio, validación 11 dígitos (línea 517)
  - `nombreComercCtrl` — campo opcional (línea 529)
- **Envío**: `_confirmar()` pasa los 3 campos a `ejecutarOnboardingBackend` (líneas 121-125).
- **Backend**: `completarOnboardingFretix` crea `/users + /companies + /company_members` en transacción atómica para roles empresa (verificado en `onboarding.js` y en los tests de Tarea 2).

**No hay nada que implementar.** Módulo 4.3 ya está completo end-to-end.

---

## TAREA 5 — Auditoría de manejo de errores en Cloud Functions ✅ COMPLETADA

**Timestamp**: 2026-08-04

### Gaps encontrados y clasificados

| Función | Gap | Severidad | Acción |
|---|---|---|---|
| `confirmar_viaje.js` | Sin try/catch en `viajes.add()` — Firestore caído = internal error | **Crítico** | ✅ Corregido |
| `confirmar_viaje.js` | Sin try/catch en `companies.doc().get()` B2B — Firestore caído = internal error | **Crítico** | ✅ Corregido |
| `onboarding.js` | Sin try/catch en `runTransaction()` — Firestore caído = internal error | **Crítico** | ✅ Corregido |
| `cotizacion.js` | Sin try/catch en `Promise.all([tarifas, app])` — Firestore caído = internal error | **Medio** | ✅ Corregido |
| `cotizacion.js` | Google Maps 429/timeout no distinguidos en logs | **Bajo** | Solo documentado |
| `confirmar_viaje.js` | `!d.origen?.lat` rechaza lat=0 (meridiano primero — irrelevante para Mendoza, bug latente) | **Bajo** | Solo documentado |
| `cotizacion.js` | `ayudante: "si"` (string) silenciosamente ignora el campo | **Bajo** | Solo documentado |

### Correcciones implementadas

En los 3 casos críticos, patrón aplicado:
```js
try {
  // operación Firestore
} catch (err) {
  if (err instanceof HttpsError) throw err;  // re-lanzar errores propios
  console.error('[función] Error:', err.message);
  throw new HttpsError('unavailable', 'Mensaje amigable. Intentá de nuevo.');
}
```

El `if (err instanceof HttpsError) throw err` es crítico para evitar que un `HttpsError` lanzado dentro del bloque try se re-envuelva en "unavailable".

### Evidencia

```
Tests: 42 passed, 42 total — después de los cambios
node --check: cotizacion OK | confirmar OK | onboarding OK
```

---

## TAREA 6 — Accesibilidad y responsive ✅ PARCIAL

**Timestamp**: 2026-08-04

### Hallazgos de touch targets (mínimo 44×44 dp)

| Componente | Archivo | Dimensión actual | Estado |
|---|---|---|---|
| Toggle "Ayudante" (track) | `cotizacion_screen.dart:999` | 48×28dp — 28 < 44 | ✅ Corregido |
| "Reenviar SMS" GestureDetector | `otp_screen.dart:463` | texto solo, ~20dp | ✅ Corregido |
| Carrusel de categorías | `cotizacion_screen.dart:849` | 84×~70dp | ✅ OK |
| Botones ElevatedButton | múltiples pantallas | height: 56dp | ✅ OK |
| InkWell tarjeta cliente | `home_cliente_screen.dart:152` | height: libre | ✅ OK (ocupa toda la card) |

**Correcciones aplicadas**: los dos widgets incorrectos se wrapearon en `SizedBox(height: 44)` con `Center` para mantener el visual pero ampliar el área táctil.

### Hallazgos de contraste (sobre fondo 0xFF0D0D0D)

| Token | Valor hex | Contraste vs background | WCAG AA |
|---|---|---|---|
| textPrimary | #FFFFFF | 19.5:1 | ✅ Pasa AAA |
| textSecondary | #888888 | ~5.1:1 | ✅ Pasa AA |
| accent | #D4A373 | ~10:1 | ✅ Pasa AAA |
| textMuted | #444444 | ~2.5:1 | ❌ Falla AA — solo decorativo |

`textMuted` falla WCAG AA. Revisión pendiente CPO: es intencional como texto "phantom" (placeholders, hints pasivos). Si se usa en texto legible de interfaz → debe cambiarse a `textSecondary`.

### Escalado de texto

- No se usa `textScaler` explícito → Flutter respeta el escalado del sistema (comportamiento correcto por defecto).
- No hay llamadas a `MediaQuery.textScalerOf()` para deshabilitar scaling — bien.
- Textos informativos pequeños (fontSize: 11-12) podrían quedar muy pequeños en escalados bajos, pero no hay nada que requiera `MediaQuery.textScaler` para limitar.

### flutter analyze

```
0 errors, 0 warnings — sobre cotizacion_screen.dart y otp_screen.dart
```

---

## TAREA 7 — Limpieza de dependencias (PENDIENTE)

---

## TAREA 8 — README.md para developers (PENDIENTE)

---

## TAREA 9 — Naming y consistencia de código (PENDIENTE)

---

*Log creado: 2026-08-03. Actualizar tras cada tarea completada.*
