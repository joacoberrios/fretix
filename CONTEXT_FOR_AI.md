# FRETIX — Contexto de proyecto para IA

## Qué es FRETIX

Plataforma de fletes B2C/B2B en Flutter Web + Firebase. Conecta clientes que necesitan transporte de carga con choferes/transportistas. Tiene validación de crédito B2B para empresas.

Stack: Flutter 3.44.4 / Dart 3.12.2, Firebase (Auth, Firestore, Cloud Functions v2, Hosting), Google Maps Directions API.

Proyecto Firebase: `fretix-dev-jb`. Producción en https://fretix-dev-jb.web.app

---

## Estado actual de la rama

Rama activa: `overnight-work-20260803`

La rama `main` local tiene 50 commits y diverge de `origin/main` (23 commits). No hacer merge ni force-push sin revisión explícita.

### Commits recientes (los 9 de la sesión nocturna)

```
6ccb24b docs: agregar README.md, limpiar comentarios stale de Codespaces y cerrar OVERNIGHT_LOG
e22adc8 chore(deps): upgrade google_maps_flutter 2.17→2.18 y google_maps_flutter_web 0.6.2→0.6.3
9ac8b04 fix(a11y): ampliar touch targets a 44dp en toggle ayudante y botón Reenviar SMS
59e538e fix(functions): agregar try/catch en operaciones Firestore de las 3 Cloud Functions
06daeba feat(admin): pantalla de solo lectura /admin/tarifas — Módulo 5 inicial
d4b2e3b test(functions): agregar 42 tests para cotizarViaje, confirmarViaje y completarOnboarding
d654045 fix(deuda-tecnica): limpiar warnings flutter analyze, crear test base, configurar flutter_lints
cdffcc3 docs: cerrar sesion - Modulo 4.1/4.2, fixes de seguridad, primer deploy a produccion
3cc36ab fix(seed): agregar guard USE_PROD_FIRESTORE para prevenir escritura accidental contra emulador
```

---

## Entorno local verificado

| Herramienta | Versión |
|---|---|
| Flutter | 3.44.4 / Dart 3.12.2 |
| Java JDK | OpenJDK 21.0.11 |
| Node.js | v22.23.2 |
| Firebase CLI | 15.22.4 |
| Python | 3.14.6 |

Flutter no está en el PATH global. Ruta completa: `/Users/joaquinberrios/Documents/flutter/bin/flutter`

### Emuladores locales

| Servicio | Host | Puerto |
|---|---|---|
| Firebase Auth | 127.0.0.1 | 9099 |
| Cloud Functions | 127.0.0.1 | 5001 |
| Firestore | 127.0.0.1 | 8282 |
| Emulator Hub UI | 127.0.0.1 | 4400 |

### Switch emulador/producción

```bash
# Emulador
flutter run -d chrome --dart-define=USE_EMULATOR=true

# Producción
flutter run -d chrome
```

La flag `USE_EMULATOR` la consume `FretixAuthService.initializeEmulators()` en `lib/services/auth_service.dart`.

---

## Arquitectura de archivos clave

```
lib/
  main.dart                          # runApp, fretixNavigatorKey (GlobalKey)
  firebase_options.dart              # FlutterFire-generated, apiKey real de producción
  models/
    user_role.dart                   # FretixUserRole enum (4 roles)
  services/
    auth_service.dart                # Singleton: OTP, onboarding, emulator switch
  router/
    app_router.dart                  # Switch de rutas nombradas
  screens/
    auth/
      phone_input_screen.dart        # Ingreso de teléfono, OtpArgs
      otp_screen.dart                # 6 campos OTP, countdown 60s, reenvío SMS
    onboarding/
      role_selection_screen.dart     # Carrusel de 4 roles + formulario empresa
    customer/
      cotizacion_screen.dart         # Mapa, categorías, toggle ayudante, confirmación
      search_location_screen.dart    # Autocomplete de ubicaciones (usa dart:html — stopgap)
    home/
      home_cliente_screen.dart
      home_chofer_screen.dart
    admin/
      admin_tarifas_screen.dart      # Solo lectura: StreamBuilder de /config/tarifas
  theme/
    fretix_colors.dart               # Tokens de color

functions/src/
  cotizacion.js                      # cotizarViajeFretix — Haversine + Google Maps fallback
  confirmar_viaje.js                 # confirmarViajeFretix — crea /viajes, valida crédito B2B
  onboarding.js                      # completarOnboardingFretix — crea /users + /companies
  seed.js                            # Seed de /config/tarifas y /config/app

functions/test/
  setup.js                           # Helpers: initAdmin, clearCollection, seedConfigMinimo
  cotizacion.test.js                 # 13 tests: Haversine, tarifa, payload
  confirmar_viaje.test.js            # 21 tests: crédito B2B, payload, Firestore
  onboarding.test.js                 # 8 tests: payload, Firestore

test/
  widget_test.dart                   # 6 tests unitarios sobre FretixUserRole (sin deps web)

analysis_options.yaml                # flutter_lints, uri_does_not_exist: ignore
```

---

## Modelo de datos Firestore

### Colecciones principales

```
/users/{uid}
  displayName, phone, role (string firestoreId), email?, fcmToken?, createdAt

/companies/{companyId}
  razonSocial, cuit, nombreComercial?, createdAt, createdBy (uid)

/company_members/{uid}
  companyId, role, joinedAt

/viajes/{viajeId}
  uid, companyId?, categoria, origen{lat,lng,address}, destino{lat,lng,address},
  paradas[], ayudante, cotizacion{distanciaKm, duracionMin, subtotal, helperFee,
  comisionApp, total}, estado ('pendiente'), createdAt

/config/tarifas
  mini{base, perKm, perMin, espera}
  plus{base, perKm, perMin, espera}
  max{base, perKm, perMin, espera}
  heavy{base, perKm, perMin, espera}

/config/app
  comisionPlatforma (default 0.15)
  helperFee (default 5000)
  factorCorreccion (1.35)
  radioMatcheo (km)
```

### Validación de crédito B2B (`confirmar_viaje.js`)

El documento `/companies/{companyId}/creditoB2B` tiene:
- `habilitada` (bool)
- `macroLimitAudit` (number | null) — si `habilitada=false`, este campo habilita igualmente
- `saldoActualARS` (number | null)
- `limiteCreditoARS` (number | null)

Lógica (default-secure: null = bloquea):
```js
function evaluarCredito(cc) {
  const habilitada       = cc.habilitada       ?? false;
  const macroLimitAudit  = cc.macroLimitAudit  ?? null;
  const saldoActualARS   = cc.saldoActualARS   ?? null;
  const limiteCreditoARS = cc.limiteCreditoARS ?? null;
  if (!habilitada) { return macroLimitAudit !== null; }
  if (saldoActualARS !== null && limiteCreditoARS !== null) {
    return Math.abs(saldoActualARS) <= limiteCreditoARS;
  }
  return false;
}
```

---

## Roles de usuario

```dart
enum FretixUserRole {
  clienteParticular,       // firestoreId: 'clienteParticular'
  clienteEmpresaMaestro,   // firestoreId: 'clienteEmpresaMaestro', requiereDatosFiscales: true
  chofer,                  // firestoreId: 'chofer', esTransportista: true
  empresaTransporteMaestro // firestoreId: 'empresaTransporteMaestro', requiereDatosFiscales: true, esTransportista: true
}
```

`FretixUserRole.fromFirestoreId(String id)` — fallback a `clienteParticular` para IDs desconocidos.

---

## Algoritmo de tarifa

```
subtotal  = base + (perKm × distanciaKm) + (perMin × duracionMin)
helperFee = ayudante ? monto_fijo : 0       ← 100% al chofer, fuera de comisión
comisionApp = subtotal × 0.15               ← NO incluye helperFee
total     = subtotal + comisionApp + helperFee
```

Ruta: Google Maps Directions API (timeout 8s) → fallback Haversine × 1.35 (factor Mendoza).

---

## Estado de tests

### Flutter

```
flutter test test/widget_test.dart
00:00 +6: All tests passed!
```

6 tests sobre `FretixUserRole`: firestoreId round-trip, fromFirestoreId para los 4 roles, fallback para ID desconocido, `requiereDatosFiscales`, `esTransportista`.

### Cloud Functions (Jest)

```
Test Suites: 3 passed, 3 total
Tests:       42 passed, 42 total
Time:        ~1.0 s
```

Requiere emuladores corriendo (`firebase emulators:start`).

```bash
cd functions && npm test
```

### flutter analyze

```
40 issues found — todos info, 0 errors, 0 warnings
```

Los 40 son deprecaciones de API (withOpacity, setMapStyle, scale, activeColor, prefer_const_constructors). No bloquean compilación ni runtime.

---

## Deuda técnica documentada

### Stopgap activo: `search_location_screen.dart`

Usa `dart:html` + `dart:js_util` (deprecados en Dart 3.x). Suprimido con `// ignore:` inline y `uri_does_not_exist: ignore` en `analysis_options.yaml`. El build web funciona. Migración a `dart:js_interop` + `package:web` requiere aprobación CPO.

### Tokens de color

`textMuted` (#444444) tiene contraste 2.5:1 contra fondo #0D0D0D — falla WCAG AA. Es intencional como texto "phantom" (placeholders pasivos). Si se usa en texto legible, debe cambiarse a `textSecondary` (#888888, ~5.1:1).

---

## Decisiones pendientes para el CPO

1. **Migración `dart:js_interop`** — `search_location_screen.dart`. Stopgap activo, no bloquea producción hoy.
2. **Pantallas de edición Admin Panel** — `/admin/tarifas/edit`, `/admin/config/edit`. Requieren Cloud Function `actualizarTarifaFretix` + colección nueva `audit_log` (propuesta documentada en OVERNIGHT_LOG.md Tarea 3). No implementar sin aprobación.
3. **`textMuted` WCAG AA** — ¿intencional como decorativo o debe cambiarse?
4. **Major version bumps Firebase** — todos los paquetes Firebase tienen major upgrade disponible (firebase_core 3→4, firebase_auth 5→6, cloud_firestore 5→6, etc.). Requieren sesión dedicada con prueba end-to-end en emulador.
5. **Enforcement de rol admin en router** — la ruta `/admin/tarifas` existe pero cualquier usuario autenticado puede acceder. Falta verificar `role == 'admin'` en `AppRouter` antes de navegar.

---

## Reglas de trabajo (no negociables)

Estas reglas estuvieron activas durante toda la sesión nocturna y deben mantenerse:

1. **Nunca** `git push` a `origin/main` ni a `main`.
2. **Nunca** modificar `firestore.rules`.
3. **Nunca** correr `firebase deploy` (todo el trabajo es contra emulador local).
4. **Nunca** inventar campos nuevos en Firestore sin documentarlos como propuesta en OVERNIGHT_LOG.md.
5. Si bloqueado con decisión de arquitectura poco clara: documentar en OVERNIGHT_LOG.md y pasar a la siguiente tarea.

---

## Comandos de referencia rápida

```bash
# Emuladores
firebase emulators:start

# Flutter web con emulador
/Users/joaquinberrios/Documents/flutter/bin/flutter run -d chrome --dart-define=USE_EMULATOR=true

# Analyze
/Users/joaquinberrios/Documents/flutter/bin/flutter analyze

# Tests Flutter
/Users/joaquinberrios/Documents/flutter/bin/flutter test

# Tests Functions (requiere emuladores corriendo)
cd functions && npm test

# Build producción
/Users/joaquinberrios/Documents/flutter/bin/flutter build web --release

# Git log compacto
git log --oneline -10

# Ver UI emuladores
open http://127.0.0.1:4400
```

---

## Archivos de documentación en el repo

| Archivo | Contenido |
|---|---|
| `README.md` | Setup local completo (este proyecto) |
| `OVERNIGHT_LOG.md` | Log detallado de la sesión nocturna 2026-08-03/04 con evidencia real de cada tarea |
| `BITACORA.md` | Historial de decisiones de arquitectura |
| `FRETIX_Arquitectura_Firestore.md` | Esquema de colecciones y reglas |
| `FRETIX_Modulo2_Auth_Onboarding.md` | Flujo OTP + onboarding |
| `FRETIX_Modulo3_Tarifas_Mapas.md` | Algoritmo de tarifa y cotización |
| `FRETIX_Modulo4_Flujo_Matcheo.md` | Matching chofer-viaje |
| `FRETIX_Modulo5_UI_Flutter.md` | Pantallas y navegación |
| `FRETIX_Modulo6_Web_Cierre.md` | Deploy web |
