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

## Tareas en esta sesión (resumen)

| Tarea | Estado |
|-------|--------|
| Tarea 1: dashboard stats chofer | 🔄 En progreso |
| Tarea 2: VAPID key push | 🚫 BLOQUEADA — requiere CPO |
| Tarea 3: cargaKg field | 🚫 BLOQUEADA — decisión de producto pendiente CPO |
| Tarea 4: migraciones mecánicas | ✅ Completa (dart:html diferida) |
| Tarea 5: KYC_DESIGN_LOG.md | 📋 Pendiente |
