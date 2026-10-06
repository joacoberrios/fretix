# FRETIX — Contexto de proyecto para IA

> Última actualización: 2026-10-06

## Qué es FRETIX

Plataforma de fletes B2C/B2B en Flutter Web + Firebase. Conecta clientes que necesitan transporte de carga con choferes/transportistas. Tiene validación de crédito B2B para empresas, matching por capacidad física de carga y validación documental de vehículos.

Stack: Flutter 3.44.4 / Dart 3.12.2, Firebase (Auth, Firestore, Cloud Functions v2, Hosting), Google Maps Directions API.

Proyecto Firebase: `fretix-dev-jb`. Producción en https://fretix-dev-jb.web.app

---

## Estado actual de la rama

- **Rama activa:** `feature-deuda-menor-20260924` (trackeada a `origin/feature-deuda-menor-20260924`).
- **Historial:** 100 commits en total. Se desprende de `main` (94 commits) con 6 commits propios de deuda menor y optimizaciones.
- **Estado de ramas previas:**
  - `feature-validacion-vehiculo-20260904` **SÍ está mergeada** en `main`.
  - También están mergeadas en `main`: `feature-matcheo-20260806`, `feature-tarea11-subir-tarjeta-verde`, `feature-tracking-gps-20260905`, `feature-viaje-en-curso-20260905`, `feature-estado-en-transito-20260906`, `feature-rebrand-azul-acero-20260906`, `feature-mapstyle-premium-20260906`.
- **Regla de oro:** No hacer merge a `main` ni force-push sin revisión explícita del CPO.

### Commits recientes en HEAD

```
69b2079 feat(cargaKg): Tarea 3 — campo explícito de peso de carga en CotizacionScreen
8f81134 docs: actualiza logs con auditoría T1 + diseño T3 + estado push T2
092badd fix(dashboard): comisionApp faltaba en viaje doc — mostraba bruto en vez de neto
eb97755 docs: DEUDA_TECNICA_LOG + KYC_DESIGN_LOG — cierre sesión 2026-09-24
8efc588 feat(dashboard): stats del día en HomeChoferScreen con datos reales
732c4be refactor(deuda-menor): withOpacity→.withValues(alpha:) + setMapStyle→GoogleMap.style
ed95e1a feat(mapstyle): estilo de mapa premium — jerarquía visual fondo/ruta
b8dd317 refactor(rebrand): elimina accentDark — token muerto sin consumidores
dc82d22 feat(rebrand): paleta Cobre → Azul Acero + Plateado
21e1484 feat(viaje): nuevo estado en_transito — ciclo de vida completo
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

Hay dos sistemas de nombres para los roles que coexisten en el código. Confundirlos rompe la navegación y los guards de ruta.

### Strings reales que escribe `onboarding.js` en Firestore

Estos son los valores en el campo `onboardingRole` de `/users/{uid}`. Son snake_case y son la fuente de verdad del backend:

| Rol | String en Firestore (`onboardingRole`) |
|---|---|
| Cliente particular | `'cliente_particular'` |
| Cliente empresa | `'cliente_empresa_maestro'` |
| Chofer independiente | `'chofer_independiente'` |
| Empresa transportista | `'empresa_transporte_maestro'` |

Definidos en `functions/src/onboarding.js:28-34` (`ROLE_TO_USER_ROLES`). **Siempre verificar ahí antes de hardcodear un string de rol en Dart.**

### Enum Dart (`FretixUserRole`)

El enum Dart usa camelCase para los identificadores. El campo `firestoreId` del enum NO coincide con los strings de `onboarding.js`:

```dart
enum FretixUserRole {
  clienteParticular,       // firestoreId: 'clienteParticular'
  clienteEmpresaMaestro,   // firestoreId: 'clienteEmpresaMaestro'
  chofer,                  // firestoreId: 'chofer'
  empresaTransporteMaestro // firestoreId: 'empresaTransporteMaestro'
}
```

El enum `firestoreId` se usa para tipado interno y lógica UI. La fuente de verdad en Firestore sigue siendo `onboardingRole` (snake_case).

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
    cotizacion_args.dart             # CotizacionArgs para pase de argumentos tipados
  services/
    auth_service.dart                # Singleton: OTP, onboarding, FCM token, emulator switch
  router/
    app_router.dart                  # Rutas nombradas + guards de rol (_AdminGuard, _ChoferGuard)
    role_routing.dart                # Lógica pura de redirección por rol
  screens/
    auth/
      phone_input_screen.dart        # Ingreso de teléfono, OtpArgs
      otp_screen.dart                # 6 campos OTP, countdown 60s, reenvío SMS
    onboarding/
      role_selection_screen.dart     # Carrusel de 4 roles + formulario empresa
    customer/
      cotizacion_screen.dart         # Mapa, categorías, cargaKg, ayudante, cotización, crédito B2B
      buscando_chofer_screen.dart    # StreamBuilder en /viajes/{id} (espera pending / chofer asignado)
      search_location_screen.dart    # Autocomplete de ubicaciones (usa dart:html — stopgap)
    home/
      home_cliente_screen.dart       # Placeholder
      home_chofer_screen.dart        # Toggle disponibilidad, stats del día reales, viajes pending
      dashboard_stats_logic.dart     # Funciones puras de cálculo de métricas chofer
    chofer/
      viaje_activo_screen.dart       # GPS tracking en vivo (15s), polilínea, ETA dinámico, transiciones
      subir_tarjeta_verde_screen.dart# Carga/subsanación de Tarjeta Verde
      vehiculo_payload.dart          # Construcción pura de payloads para /vehiculos
    admin/
      admin_tarifas_screen.dart      # Solo lectura: StreamBuilder de /config/tarifas
      admin_validaciones_screen.dart # Gestión/revisión manual de Tarjetas Verdes (/vehiculos)
  theme/
    fretix_colors.dart               # Tokens de color (paleta Azul Acero + Plateado)
    fretix_theme.dart                # Tema Material 3 corporativo

functions/src/
  cotizacion.js                      # cotizarViajeFretix — Haversine + Google Maps Directions
  confirmar_viaje.js                 # confirmarViajeFretix — crea /viajes/{id} con estado 'pending', valida crédito B2B y cargaKg
  aceptar_viaje.js                   # aceptarViajeFretix — transacción atómica, valida vehículo y capacidadMaxKg vs cargaKg
  iniciar_viaje.js                   # iniciarViajeFretix — pasa de 'aceptado' a 'en_curso'
  confirmar_carga.js                 # confirmarCargaFretix — pasa de 'en_curso' a 'en_transito'
  finalizar_viaje.js                 # finalizarViajeFretix — pasa de 'en_transito' a 'completado'
  cancelar_viaje.js                  # cancelarViajeFretix — cancela desde 'pending' o 'aceptado'
  validar_tarjeta_verde.js           # validarTarjetaVerdeFretix — OCR (Cloud Vision / Mock), PBT, Tara, capacidadMaxKg
  actualizar_fcm_token.js            # actualizarFcmTokenFretix — registra token FCM en /users/{uid}
  onboarding.js                      # completarOnboardingFretix — crea /users/{uid} + /companies
  seed.js                            # Seed de /config/tarifas y /config/app

functions/test/
  setup.js
  cotizacion.test.js                 # 11 tests
  confirmar_viaje.test.js            # 31 tests
  aceptar_viaje.test.js              # 31 tests
  viaje_lifecycle.test.js            # 30 tests
  validar_tarjeta_verde.test.js      # 22 tests
  onboarding.test.js                 # 18 tests

test/
  widget_test.dart                   # 6 tests unitarios sobre FretixUserRole
  role_routing_test.dart             # 12 tests sobre lógica de rutas y roles
  subir_tarjeta_verde_test.dart      # 21 tests sobre payloads y validación de vehículos
  dashboard_stats_test.dart          # 8 tests de cálculo de ganancias netas y métricas
```

### Guards de ruta en `app_router.dart`

| Ruta | Guard | Mecanismo |
|---|---|---|
| `/admin/tarifas` | `_AdminGuard` | `getIdTokenResult()` → custom claim `role == 'admin'` |
| `/home/chofer` | `_ChoferGuard` | Lectura Firestore `/users/{uid}.onboardingRole` (Stream reactivo) |
| `/home/cliente` | Sin guard | Pendiente |

---

## Modelo de datos Firestore

### `/users/{uid}`

```
onboardingRole: string   ← snake_case ('cliente_particular', 'cliente_empresa_maestro', 'chofer_independiente', 'empresa_transporte_maestro')
displayName:   string
phone:         string
email:         string?
companyId:     string?   ← solo para roles empresa
roles:         string[]  ← array interno (ej: ['driver'], ['customer'])
isActive:      bool
isVerified:    bool
createdAt:     timestamp
disponibleParaViajes: bool  ← solo choferes, conectado al toggle en HomeChoferScreen
fcmToken:      string?   ← token de mensajería push
```

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

### `/vehiculos/{vehiculoId}`

Colección creada por choferes para validación de capacidad de transporte:

```
choferUid:               string (uid)
companyId:               string?
categoriaVehiculo:       'utilitario' | 'pickup' | 'camion_liviano' | 'camion_frio' | 'camion_mediano' | 'camion_mudanza'
capacidadMaxKg:          number | null  ← calculado como (pbt - tara) cuando está validado
estadoValidacion:        'pendiente_ocr' | 'pendiente_revision' | 'validado' | 'pendiente_subsanacion'
tarjetaVerdeStoragePath: string  ← 'tarjetas_verde/{uid}/{timestamp}.jpg'
pbtExtraido:             number | null
taraExtraida:            number | null
validadoEn:              timestamp | null
validadoPor:             string | null  ← null si OCR automático, uid de admin si manual
createdAt:               timestamp
```

### `/viajes/{viajeId}`

```
clienteUid:    string (uid)
clientType:    'particular' | 'empresa'
companyId:     string?
estado:        'pending' | 'aceptado' | 'en_curso' | 'en_transito' | 'completado' | 'cancelado'
pricingMethod: 'haversine_contingencia' | 'google_maps'
categoria:     'mini' | 'plus' | 'max' | 'heavy'
cargaKg:       number (entero positivo en kg)
ayudante:      bool
origen:        { lat: number, lng: number, address: string }
destino:       { lat: number, lng: number, address: string }
cotizacion: {
  total:       number,
  subtotal:    number | null,
  comisionApp: number | null,
  helperFee:   number,
  distanciaKm: number,
  duracionMin: number
}
createdAt:     timestamp

// Campos desnormalizados y timestamps según ciclo de vida:
choferUid:     string? (uid chofer asignado)
choferData:    { displayName, photoURL, phone, categoriaVehiculo }?
clienteData:   { displayName, phone }?
aceptadoEn:    timestamp?
iniciadoEn:    timestamp?
cargadoEn:     timestamp?
completadoEn:  timestamp?
canceladoEn:   timestamp?
canceladoPor:  string? (uid)
canceladoPorRol: 'cliente' | 'chofer'?
```

### `/viajes/{viajeId}/tracking/{doc}` (Subcolección GPS en vivo)

Documento único: `actual`

```
lat:           number (double)
lng:           number (double)
actualizadoEn: timestamp
```

- **Reglas de seguridad:**
  - Escritura: únicamente el `choferUid` asignado a ese viaje.
  - Lectura: únicamente `clienteUid` o `choferUid` del viaje (y admin).

### `/config/tarifas` y `/config/app`

Solo legibles y escribibles por admin con custom claim (`_AdminGuard` y rules). Escritura operativa vía Admin SDK.

---

## Máquina de estados del viaje (`/viajes/{viajeId}`)

> **Regla estricta:** El estado inicial del viaje es `'pending'` (en inglés). NO existe el estado `'pendiente'` ni `'quoting'` en el documento `/viajes`.

```
[ Cliente confirma viaje ]
           │
           ▼
        pending ───────────────────────────────┐
           │                                   │
   (aceptarViajeFretix)                        │
           ▼                                   │
        aceptado ──────────────────────────────┤
           │                                   │ (cancelarViajeFretix)
   (iniciarViajeFretix)                        │ (desde pending: solo cliente)
           ▼                                   │ (desde aceptado: cliente o chofer)
        en_curso                               │
           │                                   │
  (confirmarCargaFretix)                       │
           ▼                                   │
      en_transito                              │
           │                                   │
  (finalizarViajeFretix)                       │
           ▼                                   ▼
      completado                           cancelado
```

| Estado | Quién transiciona | Función Cloud / Mecanismo | Validación clave |
|---|---|---|---|
| `pending` | Cliente | `confirmarViajeFretix` | Estado inicial. Valida crédito B2B (si aplica) y `cargaKg`. |
| `aceptado` | Chofer | `aceptarViajeFretix` (transacción) | Chofer disponible, con vehículo `validado`, `capacidadMaxKg >= cargaKg`, sin viajes activos simultáneos. |
| `en_curso` | Chofer | `iniciarViajeFretix` | Chofer en camino al origen. Inicia tracking GPS cada 15s. |
| `en_transito` | Chofer | `confirmarCargaFretix` | Mercadería cargada en origen. En ruta hacia destino con GPS. |
| `completado` | Chofer | `finalizarViajeFretix` | Carga entregada en destino. Detiene tracking GPS. |
| `cancelado` | Cliente o Chofer | `cancelarViajeFretix` | Permitido únicamente desde `pending` (solo cliente) o `aceptado` (cliente o chofer). |

---

## Algoritmo de tarifa

```
subtotal    = base + (perKm × distanciaKm) + (perMin × duracionMin)
helperFee   = ayudante ? monto_fijo : 0       ← 100% al chofer, fuera de comisión
comisionApp = subtotal × 0.15                 ← NO incluye helperFee
total       = subtotal + comisionApp + helperFee
```

Ganancia neta del chofer en dashboard:
```
gananciaNeta = cotizacion.total - cotizacion.comisionApp
```

Ruta: Google Maps Directions API (timeout 8s) → fallback Haversine × 1.35 (factor Mendoza).

---

## Seguridad — `firestore.rules` estado real

- `/users/{userId}`: lectura = owner o admin; update = owner pero sin modificar `roles`, `isVerified`, `isActive`, `companyId`; create/delete = false.
- `/companies/{companyId}`: lectura = miembro o admin; escritura = false (Admin SDK).
- `/company_members/{membershipId}`: lectura = owner o admin; escritura = false.
- `/vehiculos/{vehiculoId}`:
  - create = chofer autenticado (`request.resource.data.choferUid == request.auth.uid`).
  - read = chofer dueño (`choferUid == uid`) o admin.
  - update = chofer dueño (subsanación) o admin (validación manual).
  - delete = false.
- `/viajes/{viajeId}`:
  - create = false (solo Cloud Functions vía Admin SDK).
  - read = choferes autenticados si `estado == 'pending'` (para matcheo), clienteUid, choferUid asignado, o admin.
  - update/delete = false (transiciones de estado exclusivamente por Cloud Functions).
- `/viajes/{viajeId}/tracking/{doc}`:
  - read = clienteUid o choferUid del viaje padre.
  - write = solo choferUid del viaje padre.
- `/config/{configId}`: lectura y escritura = solo admin con custom claim.

---

## Validación de crédito B2B

`_loadUserCreditContext()` en `cotizacion_screen.dart`:
1. Lee `/users/{uid}.onboardingRole`.
2. Si es `'cliente_empresa_maestro'` → query `/company_members` por `userId` → obtiene `companyId`.
3. Lee `/companies/{companyId}.cuentaCorriente`.
4. Default-secure: cualquier null en el camino → `_clientType = null` → botón confirmar bloqueado.

`puedeConfirmarPorCredito()`:
- `habilitada = false` + `macroLimitAudit != null && > 0` → permite.
- `habilitada = true` → `|saldoActualARS| <= limiteCreditoARS` → permite.
- Cualquier null → bloquea.

---

## Estado de features por pantalla

| Pantalla | Estado |
|---|---|
| `phone_input_screen.dart` | ✅ Completo |
| `otp_screen.dart` | ✅ Completo |
| `role_selection_screen.dart` | ✅ Completo |
| `cotizacion_screen.dart` | ✅ Completo (cotización + confirmación + crédito B2B + input explícito `cargaKg`) |
| `home_cliente_screen.dart` | ⚠️ Placeholder — grid estático |
| `home_chofer_screen.dart` | ✅ Matcheo real — toggle disponibilidad, StreamBuilder viajes `pending`, banner subsanación Tarjeta Verde, y stats del día reales calculados con ganancias netas |
| `viaje_activo_screen.dart` | ✅ Completo — seguimiento GPS en vivo (15s), polilínea, ETA dinámico, transiciones `iniciar`, `confirmar carga`, `finalizar` |
| `admin_tarifas_screen.dart` | ✅ Solo lectura — StreamBuilder de `/config/tarifas` |
| `admin_validaciones_screen.dart` | ✅ Completo — StreamBuilder de `/vehiculos` `pendiente_revision`, validación/subsanación manual |
| `buscando_chofer_screen.dart` | ✅ StreamBuilder real — estado `pending` (spinner) o `aceptado` (datos de chofer desnormalizados) |
| `subir_tarjeta_verde_screen.dart`| ✅ Completo — subida a Storage + registro de doc en `/vehiculos` |

---

## Sistema de matcheo y capacidad de vehículos

### Taxonomías coexistentes

| Campo | Dónde vive | Valores | Rol |
|---|---|---|---|
| `categoriaVehiculo` en `/users/{uid}` | Legacy (onboarding) | `mini\|plus\|max\|heavy` | Etiqueta visual informativa |
| `categoriaVehiculo` en `/vehiculos/{id}` | Módulo vehículos | `utilitario\|pickup\|camion_liviano\|camion_frio\|camion_mediano\|camion_mudanza` | Tipo de unidad real |
| `capacidadMaxKg` en `/vehiculos/{id}` | Módulo vehículos | número (kg) | **Fuente real de validación de matcheo** |
| `cargaKg` en `/viajes/{id}` | Cotizador cliente | número (kg) | **Peso real declarado por el cliente** |

### Regla de aceptación (`aceptarViajeFretix`)

1. **Opción A (Activa en viajes nuevos):** Compara `viaje.cargaKg <= chofer.capacidadMaxKg`.
2. **Fallback legado:** Si el viaje no tiene `cargaKg` (viajes viejos), usa `UMBRAL_KG_POR_CATEGORIA[viaje.categoria]`.

### Validación de Tarjeta Verde — Prerequisito obligatorio

Un chofer sin vehículo con `estadoValidacion == 'validado'` en `/vehiculos/` es bloqueado tanto en la UI de `HomeChoferScreen` como en el backend en `aceptarViajeFretix`.

Flujo de validación:
`pendiente_ocr` ──► `validado` (Capa 1: OCR automático)  
o `pendiente_ocr` ──► `pendiente_revision` (Capa 2: revisión manual por operador en Admin Panel)  
o `pendiente_revision` ──► `pendiente_subsanacion` ──► re-subida en `SubirTarjetaVerdeScreen`.

---

## Estado de tests

### Flutter

```bash
flutter test
# +47: All tests passed!
```

- `test/widget_test.dart`: 6 tests sobre `FretixUserRole`.
- `test/role_routing_test.dart`: 12 tests sobre lógica de navegación por roles.
- `test/subir_tarjeta_verde_test.dart`: 21 tests sobre payloads de `/vehiculos`.
- `test/dashboard_stats_test.dart`: 8 tests sobre cálculo de ganancias netas y métricas.
**Total: 47 tests unitarios en Flutter, todos pasando.**

### Cloud Functions (Jest)

```bash
cd functions && npm test
# Test Suites: 6 passed, 6 total
# Tests:       143 passed, 143 total
```

143 tests en 6 suites: `aceptar_viaje.test.js` (31), `confirmar_viaje.test.js` (31), `cotizacion.test.js` (11), `onboarding.test.js` (18), `validar_tarjeta_verde.test.js` (22), `viaje_lifecycle.test.js` (30). Requieren emuladores corriendo.

### flutter analyze

```
20 issues found — todos info (deprecaciones menores de Material / const / estilo), 0 errors, 0 warnings.
```

---

## Deuda técnica documentada

| Issue | Archivo | Prioridad | Estado |
|---|---|---|---|
| `dart:html` stopgap | `search_location_screen.dart` | Media | Pendiente migración a `package:web` |
| `withOpacity` deprecated | Varios archivos | Resuelto | ✅ Migrado a `.withValues(alpha:)` |
| `setMapStyle` deprecated | Mapas en Flutter | Resuelto | ✅ Migrado a `GoogleMap.style` |
| `textMuted` falla WCAG AA | `fretix_colors.dart` | Media | Intencional como decorativo |
| Major version bumps Firebase | `pubspec.yaml` | Alta | Requiere sesión dedicada con pruebas e2e |
| `/home/cliente` sin guard de rol | `app_router.dart` | Media | Pendiente |
| Dispatcher FCM en segundo plano | Cloud Functions | Media | Notificaciones pendientes se graban en Firestore pero falta worker FCM |

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

| Archivo | Estado | Contenido |
|---|---|---|
| `CONTEXT_FOR_AI.md` | **ACTUALIZADO (Vigente)** | Fuente de verdad y contexto maestro para IA |
| `DEUDA_TECNICA_LOG.md` | **ACTUALIZADO (Vigente)** | Log activo de deuda técnica, mitigaciones y auditorías |
| `CARGAKG_DESIGN_LOG.md` | **ACTUALIZADO (Vigente)** | Diseño e implementación de `cargaKg` explícito |
| `KYC_DESIGN_LOG.md` | **ACTUALIZADO (Vigente)** | Diseño de verificación de identidad chofer |
| `TRACKING_GPS_LOG.md` | **ACTUALIZADO (Vigente)** | Diseño e implementación de tracking GPS en vivo |
| `VIAJE_EN_CURSO_LOG.md`| **ACTUALIZADO (Vigente)** | Ciclo de vida y pantalla de viaje activo |
| `VALIDACION_LOG.md` | **ACTUALIZADO (Vigente)** | Módulo de validación de Tarjeta Verde y `/vehiculos` |
| `MATCHEO_LOG.md` | **ACTUALIZADO (Vigente)** | Lógica y auditoría del sistema de matcheo |
| `REBRAND_LOG.md` | **ACTUALIZADO (Vigente)** | Transición visual a Azul Acero y Plateado |
| `REPORTE_CEO_CTO_04092026.md` | **ACTUALIZADO (Vigente)** | Reporte de arquitectura técnica 2026-09-04 |
| `README.md` | **ACTUALIZADO (Vigente)** | Setup local y guía de inicio rápido |
| `OVERNIGHT_LOG.md` | **HISTÓRICO** | Log de sesión nocturna 2026-08-03/04 |
| `BITACORA.md` | **HISTÓRICO (Parcialmente desactualizado)** | Decisiones de arquitectura tempranas |
| `FRETIX_Modulo2_Auth_Onboarding.md` | ⚠️ **DESACTUALIZADO** | Reemplazado por código real y `CONTEXT_FOR_AI.md` |
| `FRETIX_Modulo3_Tarifas_Mapas.md` | ⚠️ **DESACTUALIZADO** | Reemplazado por código real y `CONTEXT_FOR_AI.md` |
| `FRETIX_Modulo4_Flujo_Matcheo.md` | ⚠️ **DESACTUALIZADO** | Reemplazado por `MATCHEO_LOG.md` y `CONTEXT_FOR_AI.md` |
| `FRETIX_Modulo5_UI_Flutter.md` | ⚠️ **DESACTUALIZADO** | Reemplazado por código real y `CONTEXT_FOR_AI.md` |
| `FRETIX_Modulo6_Web_Cierre.md` | ⚠️ **DESACTUALIZADO** | Reemplazado por código real y `CONTEXT_FOR_AI.md` |
| `FRETIX_Arquitectura_Firestore.md` | ⚠️ **DESACTUALIZADO** | Esquema legacy desfasado; ver `firestore.rules` y `CONTEXT_FOR_AI.md` |
