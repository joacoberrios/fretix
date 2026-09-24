# DEUDA_TECNICA_LOG — feature-deuda-menor-20260924

**Fecha:** 2026-09-24  
**Branch:** `feature-deuda-menor-20260924`  
**CPO:** joacoberriosb@gmail.com

---

## Tarea 4 — Migraciones mecánicas de deprecations

### 4a. withOpacity → .withValues(alpha:)

| Estado | ✅ Completa |
|--------|------------|
| Ocurrencias migradas | 28 en 7 archivos |
| Ocurrencias residuales | 0 (verificado con grep) |

**Archivos modificados:**
- `lib/screens/onboarding/role_selection_screen.dart` (10 ocurrencias)
- `lib/screens/chofer/viaje_activo_screen.dart` (4)
- `lib/screens/customer/buscando_chofer_screen.dart` (2)
- `lib/screens/customer/cotizacion_screen.dart` (ya migrado en sesión anterior)
- `lib/screens/home/home_chofer_screen.dart` (3)
- `lib/screens/auth/otp_screen.dart` (1)
- `lib/screens/auth/phone_input_screen.dart` (1)

```
grep -rn "withOpacity" lib/  →  (sin resultados)
```

---

### 4b. setMapStyle → GoogleMap.style

| Estado | ✅ Completa |
|--------|------------|
| Callsites eliminados | 4 (en 3 archivos) |
| GoogleMap widgets actualizados | 3 (style: _kMapStyleNocturno agregado) |
| Residuales | 0 (verificado con grep) |

**Cambio por archivo:**

`lib/screens/chofer/viaje_activo_screen.dart`
- `onMapCreated`: eliminado `async` y `await ctrl.setMapStyle(...)` → 1 callsite
- `GoogleMap`: agregado `style: _kMapStyleNocturno`

`lib/screens/customer/buscando_chofer_screen.dart`
- `onMapCreated`: eliminados 2 callsites `async/await setMapStyle`
- `GoogleMap` (_MapaCliente): agregado `style: _kMapStyleNocturno`

`lib/screens/customer/cotizacion_screen.dart`
- `onMapCreated`: eliminado `async`, `await ctrl.setMapStyle(...)` y comentario `Spec C`.
  Se preservó `_autoZoom()` call (no era async, no requería await).
- `GoogleMap` (_MapaCotizacion): agregado `style: _kMapStyleNocturno`

```
grep -rn "setMapStyle" lib/  →  (sin resultados)
```

---

### 4c. dart:html en search_location_screen.dart

| Estado | 📋 DIFERIDA — decisión pendiente del CPO |
|--------|------------------------------------------|

`lib/screens/customer/search_location_screen.dart` usa `dart:html` y `dart:js_util` con comentario pre-existente:
```dart
// TODO(migrate): reemplazar dart:js_util + dart:html por dart:js_interop + package:web
```

**Por qué se difiere:**
- La migración requiere cambios en la integración con Google Maps JS API (web-only)
- El paquete `google_maps_flutter_web` tiene su propio ciclo de release para soportar `dart:js_interop`
- Riesgo de regresión alta / baja urgencia: el código funciona correctamente hoy
- Requiere actualización coordinada de dependencias (`pubspec.yaml`)

**Acción requerida del CPO:** decidir prioridad vs. otras tareas de producto.

---

## Evidencia de calidad

### flutter analyze (post-migración)
```
19 issues found (info only) — todos pre-existentes.
0 errores, 0 warnings nuevos introducidos por esta rama.
```

Issues pre-existentes no abordados en esta rama (fuera de alcance):
- `dart:html` deprecation — ver 4c
- `prefer_const_constructors` — cosmético, sin impacto funcional
- `activeColor` deprecated (Switch) — menor
- `Matrix4.scale` deprecated — en animaciones de onboarding

### flutter build web --release
Ver salida en sección de build abajo.

---

## Tarea 1 — Dashboard stats chofer con datos reales

| Estado | ✅ Completa — incluyendo fix de bug y tests |
|--------|---------------------------------------------|

### Bug encontrado y corregido en sesión de auditoría (2026-09-24)

**Bug:** `confirmarViajeFretix` solo guardaba `{total, distanciaKm, duracionMin}` en `cotizacion`. El campo `comisionApp` nunca se escribía en el doc. `_fetchStats()` leía `comisionApp → null → fallback 0 → ganado = total bruto` (lo que pagó el cliente, no lo que ganó el chofer).

**Fix aplicado:**
- `functions/src/confirmar_viaje.js`: guarda `subtotal`, `comisionApp`, `helperFee` además de `total`
- `lib/screens/customer/cotizacion_screen.dart`: pasa esos campos a la CF (ya los tenía de `cotizarViajeFretix`)
- Datos legados (viajes creados antes del fix) seguirán mostrando bruto — fallback controlado, documentado en el test

**Limitación conocida:** viajes completados ANTES de este fix no tienen comisionApp guardado y van a mostrar el monto bruto en el dashboard del chofer para esos registros históricos — es un dato legado, no un bug nuevo.

### Implementación

**Query:** `viajes` donde `choferUid == uid` AND `estado == 'completado'`, filtro client-side por `completadoEn >= startOfTodayMendoza()`.

**Cálculo de ganancia:** `cotizacion.total - cotizacion.comisionApp`
- = `subtotal + helperFee` (neto para el chofer, sin comisión de plataforma)
- En la CF real: `subtotal × 1.15 = total` (sin helper), por lo que `total - comisionApp = subtotal`
- Con ayudante: `total = subtotal + comisionApp + helperFee` → `ganado = subtotal + helperFee`

**Zona horaria Mendoza:** `startOfTodayMendoza()` usa `DateTime.now().toUtc()` del dispositivo menos 3 horas (UTC-3 fijo, sin DST). El `completadoEn` es un `FieldValue.serverTimestamp()` confiable. El único riesgo es el reloj del dispositivo, que en la práctica está NTP-sincronizado. Se documenta como limitación conocida — no se puede hacer sin algún reloj del servidor.

**Índice usado:** `(choferUid, estado)` — ya existente. Filtro de fecha es client-side.

> Optimización futura: índice `(choferUid, estado, completadoEn)` cuando el volumen histórico sea alto.

**Calificación:** muestra `—` permanente — no hay modelo de ratings en Firestore (Fase 2).

**Archivos:**
- `lib/screens/home/dashboard_stats_logic.dart` ← lógica pura extraída (testeable sin Firebase)
- `lib/screens/home/home_chofer_screen.dart` ← usa el archivo extraído
- `functions/src/confirmar_viaje.js` ← fix comisionApp
- `lib/screens/customer/cotizacion_screen.dart` ← pasa campos completos a la CF
- `test/dashboard_stats_test.dart` ← tests

### Test output real

```
flutter test test/dashboard_stats_test.dart

00:00 +1: 3 viajes de $10.000 con comisionApp=$1.500 → $25.500 neto (no $30.000 bruto)
00:00 +2: viajes SIN comisionApp en doc → fallback 0, muestra bruto (escenario legado)
00:00 +3: viajes de ayer NO se cuentan
00:00 +4: viaje con completadoEn null se ignora sin lanzar excepción
00:00 +5: viaje con cotizacion null cuenta el viaje pero suma $0
00:00 +6: fórmula CF real: subtotal=$10.000, total=$11.500, comision=$1.500 → neto=$10.000
00:00 +7: ayudante incluido: helperFee va al chofer, no se descuenta
00:00 +8: All tests passed!
```

---

## Tarea 2 — VAPID key + push notifications

| Estado | 🚫 BLOQUEADA — requiere acción del CPO (VAPID key) |
|--------|----------------------------------------------------|

### VAPID placeholder

```
lib/services/auth_service.dart:278
vapidKey: 'BFretixVapidKeyPlaceholder', // reemplazar con VAPID real
```

El CPO debe generar la clave en: Firebase Console → Project Settings → Cloud Messaging → Web Push Certificates → "Generate key pair".

### Estado real de las CFs de push (investigado 2026-09-24)

| Evento | CF que debería disparar push | Estado |
|--------|------------------------------|--------|
| Chofer acepta viaje → notificar cliente | — | ❌ NO EXISTE ningún código |
| Tarjeta Verde → pendiente_revision → notificar admin | `validarTarjetaVerdeFretix` | ⚠️ PARCIAL |
| Viaje finalizado → notificar cliente | — | ❌ NO EXISTE |
| KYC aprobado/rechazado → notificar chofer | — | ❌ NO EXISTE (Fase 2) |

**Detalle del caso "parcial" (tarjeta verde → admin):**

`validar_tarjeta_verde.js` — `notificarOperador()` (líneas 81-105):
- ✅ Busca admins con `fcmToken` registrado
- ✅ Escribe en `/notificaciones_operador` collection con `procesado: false`
- ❌ **NO llama a `getMessaging().send()` en ningún lugar**
- La arquitectura planeada era tener una CF de Firestore trigger que procese esa colección — **esa CF no existe**

**CF de storage de FCM tokens:**

`actualizarFcmTokenFretix` ✅ EXISTE y funciona — guarda `fcmToken` en `/users/{uid}` cuando el cliente lo llama desde Flutter.

### Qué falta cuando llegue el VAPID real

1. **Para "tarjeta verde → admin":**
   - Agregar CF Firestore trigger: `onDocumentCreated('/notificaciones_operador/{id}')` → `getMessaging().sendEachForMulticast({ tokens, notification })` → marcar `procesado: true`
   - O: cambiar `notificarOperador()` para llamar FCM directamente (sin Firestore como intermediario)

2. **Para "chofer acepta viaje → cliente":** nueva CF desde cero en `aceptar_viaje.js`

3. **Actualizar `auth_service.dart:278`** con el VAPID real

No se toca código hasta que el CPO provea la clave y apruebe el diseño de CFs de push.

---

## Tarea 3 — Campo cargaKg

| Estado | ✅ Completa — implementada, tests unitarios 44/44 pasando |
|--------|----------------------------------------------------------|

**Decisión del CPO (confirmada):** input explícito del cliente (número de kg).

**Documento de diseño:** `CARGAKG_DESIGN_LOG.md`

### Implementación

**Umbral de aviso:** 40.000 kg (máximo técnico legal Argentina para camión pesado).

**Archivos modificados:**
- `lib/screens/customer/cotizacion_screen.dart` — campo `cargaKg` (TextField + validación), `puedeConfirmar` actualizado, payload a CF actualizado
- `functions/src/confirmar_viaje.js` — valida `cargaKg` (entero positivo), guarda `cargaKg` en el doc Firestore, warn si > 40.000 kg
- `functions/src/aceptar_viaje.js` — reemplaza lógica Opción C por Opción A (`viaje.cargaKg > capacidadMaxKg`) + fallback legado DEPRECATED

**Lógica de capacidad post-Tarea 3 (`aceptar_viaje.js`):**
```
if (viaje.cargaKg) {               // viajes nuevos — Opción A
  if (cargaKg > capacidadMaxKg) → rechaza con mensaje concreto (X kg > Y kg)
} else {                            // viajes legados — fallback DEPRECATED
  usar UMBRAL_KG_POR_CATEGORIA[categoria]
}
```

### Test output (unit tests — emulador no requerido)

```
jest --testPathPatterns="confirmar_viaje.test.js|aceptar_viaje.test.js" (unit suites)

Tests: 44 passed, 14 skipped (integración — requieren emulador)
Suites: 2 passed, 2 total
Time: 0.228 s
```

Tests de integración (`14`) se skippean cuando el emulador no está corriendo — comportamiento pre-existente en todo el suite. Se deben correr con `firebase emulators:start --only firestore,auth` antes de `npm test`.

---

## Tarea 5 — KYC_DESIGN_LOG.md

| Estado | ✅ Completa (documento creado, sin código) |
|--------|-------------------------------------------|

Documento creado en `KYC_DESIGN_LOG.md`. Cubre:
- Contexto y motivación del KYC de choferes (Fase 1)
- Propuesta de flujo y estados (`kycPendiente → kycAprobado`)
- Decisiones pendientes del CPO (CPO-KYC-01 a CPO-KYC-05)
- Dependencias con Tarea 2 (push) y OCR

---

## Resumen consolidado (sesiones 2026-09-24)

| Tarea | Estado | Evidencia |
|-------|--------|-----------|
| Tarea 1: dashboard stats | ✅ Completa + bug corregido + 8/8 tests | `dashboard_stats_test.dart` |
| Tarea 2: VAPID push | 🚫 Bloqueada — requiere VAPID key del CPO | Investigación CF detallada en sección T2 |
| Tarea 3: cargaKg | ✅ Completa — 44/44 unit tests | `CARGAKG_DESIGN_LOG.md` |
| Tarea 4: migraciones mecánicas | ✅ Completa (dart:html diferida) | analyze 0 errores, build ✓ |
| Tarea 5: KYC_DESIGN_LOG.md | ✅ Completa | `KYC_DESIGN_LOG.md` |

**Commits en `feature-deuda-menor-20260924`:**
```
092badd fix(dashboard): comisionApp faltaba en viaje doc — mostraba bruto en vez de neto
eb97755 docs: DEUDA_TECNICA_LOG + KYC_DESIGN_LOG — cierre sesión 2026-09-24
8efc588 feat(dashboard): stats del día en HomeChoferScreen con datos reales
732c4be refactor(deuda-menor): withOpacity→.withValues(alpha:) + setMapStyle→GoogleMap.style
```

**BARANDA:** Ninguna de estas ramas se mergea a main sin revisión explícita del CPO, una por una.
