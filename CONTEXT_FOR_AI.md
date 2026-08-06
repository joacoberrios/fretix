# FRETIX — Contexto de proyecto para IA

> Última actualización: 2026-08-06

## Qué es FRETIX

Plataforma de fletes B2C/B2B en Flutter Web + Firebase. Conecta clientes que necesitan transporte de carga con choferes/transportistas. Tiene validación de crédito B2B para empresas.

Stack: Flutter 3.44.4 / Dart 3.12.2, Firebase (Auth, Firestore, Cloud Functions v2, Hosting), Google Maps Directions API.

Proyecto Firebase: `fretix-dev-jb`. Producción en https://fretix-dev-jb.web.app

---

## Estado actual de la rama

Rama activa: `main` (local).

La rama `main` local tiene 64 commits y diverge de `origin/main` (23 commits). No hacer merge ni force-push sin revisión explícita.

### Commits recientes

```
93e470c docs: agregar contexto de proyecto para sesiones futuras de IA
13ed39a feat(chofer): conectar toggle de disponibilidad a Firestore (disponibleParaViajes)
9f9ff17 fix(onboarding): agregar companyId a userDoc en rama empresa
9101939 fix(security): proteger companyId y restringir /config a admin (Fix 1 y Fix 2)
e0eeadf fix(router): corregir strings de rol en _ChoferGuard
eea3f96 fix(router): agregar guard de rol en ruta /home/chofer
12c7ba8 fix(admin): agregar guard de rol en ruta /admin/tarifas
6ccb24b docs: agregar README.md, limpiar comentarios stale de Codespaces y cerrar OVERNIGHT_LOG
e22adc8 chore(deps): upgrade google_maps_flutter 2.17→2.18
9ac8b04 fix(a11y): ampliar touch targets a 44dp en toggle ayudante y botón Reenviar SMS
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
/Users/joaquinberrios/Documents/flutter/bin/flutter run -d chrome --dart-define=USE_EMULATOR=true

# Producción
/Users/joaquinberrios/Documents/flutter/bin/flutter run -d chrome
```

---

## Roles de usuario — CRÍTICO: dos sistemas de nombres

Hay dos sistemas de nombres para los roles que coexisten en el código. Confundirlos causó el bug del guard (commit e0eeadf).

### Strings reales que escribe `onboarding.js` en Firestore

Estos son los valores en el campo `onboardingRole` de `/users/{uid}`. Son snake_case y son la fuente de verdad:

| Rol | String en Firestore (`onboardingRole`) |
|---|---|
| Cliente particular | `'cliente_particular'` |
| Cliente empresa | `'cliente_empresa_maestro'` |
| Chofer independiente | `'chofer_independiente'` |
| Empresa transportista | `'empresa_transporte_maestro'` |

Definidos en `functions/src/onboarding.js:28-34` (`ROLE_TO_USER_ROLES`). **Siempre verificar ahí antes de hardcodear un string de rol en Dart.**

### Enum Dart (`FretixUserRole`)

El enum Dart usa camelCase para los identificadores. El campo `firestoreId` del enum NO coincide con los strings de `onboarding.js` — son dos sistemas distintos:

```dart
enum FretixUserRole {
  clienteParticular,       // firestoreId: 'clienteParticular'
  clienteEmpresaMaestro,   // firestoreId: 'clienteEmpresaMaestro'
  chofer,                  // firestoreId: 'chofer'
  empresaTransporteMaestro // firestoreId: 'empresaTransporteMaestro'
}
```

El enum `firestoreId` se usa en `otp_screen.dart` para navegación post-login. El campo `onboardingRole` en Firestore contiene los strings snake_case de `onboarding.js`. Son cosas distintas.

### Roles transportista (para guards de ruta)

Guards que verifican si un usuario es transportista deben usar los strings de `onboarding.js`:
```dart
static const _rolesTransportista = {'chofer_independiente', 'empresa_transporte_maestro'};
```

---

## Arquitectura de archivos clave

```
lib/
  main.dart                          # runApp, fretixNavigatorKey (GlobalKey)
  firebase_options.dart              # FlutterFire-generated, apiKey real de producción
  models/
    user_role.dart                   # FretixUserRole enum (4 roles, camelCase)
  services/
    auth_service.dart                # Singleton: OTP, onboarding, emulator switch
  router/
    app_router.dart                  # Rutas nombradas + guards de rol
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
      home_cliente_screen.dart       # Placeholder
      home_chofer_screen.dart        # Toggle disponibilidad conectado a Firestore
    admin/
      admin_tarifas_screen.dart      # Solo lectura: StreamBuilder de /config/tarifas
  theme/
    fretix_colors.dart               # Tokens de color

functions/src/
  cotizacion.js                      # cotizarViajeFretix — Haversine + Google Maps
  confirmar_viaje.js                 # confirmarViajeFretix — crea /viajes, valida crédito B2B
  onboarding.js                      # completarOnboardingFretix — crea /users + /companies
  seed.js                            # Seed de /config/tarifas y /config/app

functions/test/
  setup.js
  cotizacion.test.js                 # 13 tests
  confirmar_viaje.test.js            # 21 tests
  onboarding.test.js                 # 8 tests

test/
  widget_test.dart                   # 6 tests unitarios sobre FretixUserRole
```

### Guards de ruta en `app_router.dart`

| Ruta | Guard | Mecanismo |
|---|---|---|
| `/admin/tarifas` | `_AdminGuard` | `getIdTokenResult()` → custom claim `role == 'admin'` |
| `/home/chofer` | `_ChoferGuard` | Lectura Firestore `/users/{uid}.onboardingRole` |
| `/home/cliente` | Sin guard | Pendiente |

`_ChoferGuard` usa Firestore porque `onboarding.js` no llama `setCustomUserClaims()` para roles regulares — sin custom claim en JWT.

---

## Modelo de datos Firestore

### `/users/{uid}`

```
onboardingRole: string   ← campo real (snake_case, escrito por onboarding.js)
displayName:   string
phone:         string
email:         string?
companyId:     string?   ← solo para roles empresa (cliente_empresa_maestro, empresa_transporte_maestro)
roles:         string[]  ← array interno (ej: ['driver'], ['customer'])
isActive:      bool
isVerified:    bool
createdAt:     timestamp
disponibleParaViajes: bool  ← solo para choferes, conectado al toggle en HomeChoferScreen
```

**Nota:** el campo es `onboardingRole`, no `role`. `cotizacion_screen.dart`, `_ChoferGuard`, y `otp_screen.dart` (verificar) leen `onboardingRole`.

### `/companies/{companyId}`

```
razonSocial:      string
cuit:             string
nombreComercial:  string?
companyType:      'customer' | 'carrier'
ownerUserId:      string (uid)
createdAt:        timestamp
cuentaCorriente:  map?   ← solo empresas tipo 'customer'
  habilitada:        bool
  macroLimitAudit:   number | null
  saldoActualARS:    number | null
  limiteCreditoARS:  number | null
```

### `/company_members/{membershipId}`

```
userId:    string (uid)
companyId: string
role:      'owner' | 'maestro'
joinedAt:  timestamp
```

### `/viajes/{viajeId}`

```
uid, companyId?, categoria, origen{lat,lng,address}, destino{lat,lng,address},
paradas[], ayudante, cotizacion{distanciaKm, duracionMin, subtotal, helperFee,
comisionApp, total}, estado ('pendiente'), createdAt
```

Estado inicial siempre `'pendiente'`. No hay sistema de matcheo — queda pendiente para siempre.

### `/config/tarifas` y `/config/app`

Solo legibles por admin (Firestore rule + `_AdminGuard`). Escritura solo vía Admin SDK.

---

## Algoritmo de tarifa

```
subtotal    = base + (perKm × distanciaKm) + (perMin × duracionMin)
helperFee   = ayudante ? monto_fijo : 0       ← 100% al chofer, fuera de comisión
comisionApp = subtotal × 0.15                 ← NO incluye helperFee
total       = subtotal + comisionApp + helperFee
```

Ruta: Google Maps Directions API (timeout 8s) → fallback Haversine × 1.35 (factor Mendoza).

---

## Seguridad — estado actual (2026-08-06)

### Gaps cerrados

| Fix | Detalle | Commit |
|---|---|---|
| Fix 1 | `companyId` no modificable por cliente en `firestore.rules` | `9101939` |
| Fix 2 | `/config` solo legible por admin (era legible por cualquier auth) | `9101939` |
| Fix 3 | Guard en `/home/chofer` — antes cualquier usuario autenticado accedía | `eea3f96` + `e0eeadf` |
| Fix 4 | Guard en `/admin/tarifas` | `12c7ba8` |

### `firestore.rules` — estado actual

- `/users/{userId}`: lectura = owner o admin; update = owner pero sin modificar `roles`, `isVerified`, `isActive`, `companyId`; create/delete = false
- `/config/{configId}`: lectura y escritura = solo admin
- `/viajes/{viajeId}`: create solo con `estado == 'quoting'`; update/delete = false (solo Admin SDK)
- Resto de colecciones: escritura solo Cloud Functions (Admin SDK bypasea reglas)

---

## Validación de crédito B2B

`_loadUserCreditContext()` en `cotizacion_screen.dart`:
1. Lee `/users/{uid}.onboardingRole`
2. Si es `'cliente_empresa_maestro'` → query `/company_members` por `userId` → obtiene `companyId`
3. Lee `/companies/{companyId}.cuentaCorriente`
4. Default-secure: cualquier null en el camino → `_clientType = null` → botón bloqueado

`puedeConfirmarPorCredito()`:
- `habilitada = false` + `macroLimitAudit != null && > 0` → permite
- `habilitada = true` → `|saldoActualARS| <= limiteCreditoARS` → permite
- Cualquier null → bloquea

---

## Estado de features por pantalla

| Pantalla | Estado |
|---|---|
| `phone_input_screen.dart` | ✅ Completo |
| `otp_screen.dart` | ✅ Completo |
| `role_selection_screen.dart` | ✅ Completo |
| `cotizacion_screen.dart` | ✅ Completo (cotización + confirmación + crédito B2B) |
| `home_cliente_screen.dart` | ⚠️ Placeholder — grid estático, sin cotizador accesible |
| `home_chofer_screen.dart` | ⚠️ Parcial — toggle disponibilidad conectado a Firestore; "Resumen del día" e "Historial de viajes" son estáticos/falsos |
| `admin_tarifas_screen.dart` | ✅ Solo lectura — StreamBuilder de /config/tarifas |
| `buscando_chofer_screen.dart` | ⚠️ Placeholder — muestra spinner, no hay matcheo real |

---

## Pendiente crítico — sistema de matcheo inexistente

Un viaje confirmado (`confirmarViajeFretix`) crea `/viajes/{id}` con `estado: 'pendiente'` y queda ahí para siempre. No existe ninguna Cloud Function que:
- Busque choferes disponibles en un radio dado
- Envíe notificaciones a choferes (FCM no configurado)
- Actualice el estado del viaje

`HomeChoferScreen` tampoco escucha viajes disponibles. El toggle `disponibleParaViajes` escribe a Firestore pero nadie lo consulta todavía.

Este es el siguiente módulo a implementar (Módulo matcheo).

---

## Estado de tests

### Flutter

```
flutter test test/widget_test.dart
00:00 +6: All tests passed!
```

6 tests sobre `FretixUserRole`.

### Cloud Functions (Jest)

```
Test Suites: 3 passed, 3 total
Tests:       42 passed, 42 total
```

Requiere emuladores corriendo (`firebase emulators:start`).

### flutter analyze

```
40 issues found — todos info, 0 errors, 0 warnings
```

Los 40 son deprecaciones de API pre-existentes en otros archivos. Ninguno en `app_router.dart`.

---

## Deuda técnica documentada

| Issue | Archivo | Prioridad |
|---|---|---|
| `dart:html` stopgap | `search_location_screen.dart` | Media — no bloquea |
| `withOpacity` deprecated | varios | Baja |
| `textMuted` falla WCAG AA | `fretix_colors.dart` | Media (intencional como decorativo) |
| Major version bumps Firebase | `pubspec.yaml` | Alta — requiere sesión dedicada |
| `/home/cliente` sin guard de rol | `app_router.dart` | Media |

---

## Decisiones pendientes (CPO)

1. **Migración `dart:js_interop`** — `search_location_screen.dart`. Stopgap activo, no bloquea.
2. **Pantallas de edición Admin Panel** — `/admin/tarifas/edit`. Requieren Cloud Function `actualizarTarifaFretix` + `audit_log`. No implementar sin aprobación.
3. **`textMuted` WCAG AA** — ¿intencional como decorativo o debe cambiarse?
4. **Major version bumps Firebase** — firebase_core 3→4, firebase_auth 5→6, cloud_firestore 5→6. Sesión dedicada con prueba end-to-end.
5. **Sistema de matcheo** — diseño del flujo completo antes de implementar: ¿polling? ¿Firestore realtime listener? ¿FCM? ¿timeout si ningún chofer acepta?

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

# Deploy hosting
firebase deploy --only hosting --project fretix-dev-jb

# Deploy reglas
firebase deploy --only firestore:rules --project fretix-dev-jb

# Git log compacto
git log --oneline -10
```

---

## Archivos de documentación en el repo

| Archivo | Contenido |
|---|---|
| `README.md` | Setup local completo |
| `OVERNIGHT_LOG.md` | Log detallado de la sesión nocturna 2026-08-03/04 |
| `BITACORA.md` | Historial de decisiones de arquitectura (nota: tiene información desactualizada sobre roles y branch) |
| `FRETIX_Arquitectura_Firestore.md` | Esquema de colecciones y reglas |
| `FRETIX_Modulo2_Auth_Onboarding.md` | Flujo OTP + onboarding |
| `FRETIX_Modulo3_Tarifas_Mapas.md` | Algoritmo de tarifa y cotización |
| `FRETIX_Modulo4_Flujo_Matcheo.md` | Matching chofer-viaje |
| `FRETIX_Modulo5_UI_Flutter.md` | Pantallas y navegación |
| `FRETIX_Modulo6_Web_Cierre.md` | Deploy web |
