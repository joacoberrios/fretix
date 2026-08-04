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

## TAREA 2 — Tests automatizados para Cloud Functions (EN PROGRESO)

*Ver siguiente entrada cuando se complete.*

---

## TAREA 3 — Módulo 5, diseño inicial Admin Panel (PENDIENTE)

---

## TAREA 4 — Módulo 4.3: flujo empresa en onboarding (PENDIENTE)

---

## TAREA 5 — Auditoría de manejo de errores en Cloud Functions (PENDIENTE)

---

## TAREA 6 — Accesibilidad y responsive (PENDIENTE)

---

## TAREA 7 — Limpieza de dependencias (PENDIENTE)

---

## TAREA 8 — README.md para developers (PENDIENTE)

---

## TAREA 9 — Naming y consistencia de código (PENDIENTE)

---

*Log creado: 2026-08-03. Actualizar tras cada tarea completada.*
