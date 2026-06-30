# FRETIX — Bitácora de Desarrollo

> Última actualización: 2026-06-30 (Módulo 3 cerrado)  
> Repositorio: https://github.com/joacoberrios/fretix  
> Branch principal: `main`

---

## Stack

| Capa | Tecnología |
|---|---|
| Frontend | Flutter (web + mobile) |
| Auth | Firebase Authentication (OTP celular) |
| Base de datos | Firestore (NoSQL real-time) |
| Backend | Cloud Functions Node.js (v2 onCall) |
| Mapas | Google Maps API (Directions + Distance Matrix) |
| Emuladores | Firebase Local Emulator Suite |
| Hosting dev | GitHub Codespaces |

---

## Arquitectura del negocio

### Roles

| Rol | Descripción |
|---|---|
| `cliente` | Particular — paga efectivo o transferencia |
| `empresa` | Empresa con CUIT, panel maestro, sub-usuarios, Factura A, cuenta corriente |
| `chofer` | Independiente — dueño de su vehículo, cobra directo |
| `empresa_transporte` | Pyme fletera — gestiona flota y choferes empleados |

### Flota

| Categoría | Vehículos ejemplo | Uso |
|---|---|---|
| Flete Mini | Partner, Berlingo, Fiorino | Paquetería pesada, ecommerce |
| Flete Plus | Hilux, Amarok, Ranger | Eventos, catering, mudanzas chicas |
| Flete Max | Sprinter, Transit | Mudanzas enteras, pallets livianos |
| Carga Pesada | Ford Cargo, Mercedes Accelo | Logística industrial, pallets pesados |

### Fórmula de tarifas

```
Tarifa = Precio Base + (Precio/KM × Distancia) + (Precio/Min × Tiempo)
```

| Categoría | Base | $/KM | $/Min |
|---|---|---|---|
| Flete Mini | $1.800 | $350 | $90 |
| Flete Plus | $2.800 | $450 | $120 |
| Flete Max | $6.500 | $700 | $180 |
| Carga Pesada | $15.000 | $1.200 | $250 |

- Espera: 15 min gratis → luego cobra extra por minuto (configurable)
- Add-on Ayudante/Peón: monto fijo (ej. $5.000), 100% para el chofer
- Comisión App: 15% fijo sobre el neto (excluye extra de peón)
- Precio cerrado antes de confirmar (cotizador con Google Maps)

---

## Estado actual del código

### Archivos clave en `main`

```
lib/
├── main.dart                          ✅ Limpio, sin FCM, inicializa emuladores
├── router/
│   └── app_router.dart                ✅ Rutas: /login, /otp, /onboarding/role, /home/cliente, /home/chofer, /cliente/cotizar
├── services/
│   └── auth_service.dart              ✅ Singleton, OTP, onboarding backend, signOut
├── models/
│   └── user_role.dart                 ✅ Enum FretixUserRole con firestoreId, esTransportista, requiereDatosFiscales
├── screens/
│   ├── auth/
│   │   ├── phone_input_screen.dart    ✅ Input con prefijo +54, validación
│   │   └── otp_screen.dart            ✅ 6 campos OTP, maneja usuario nuevo vs existente
│   ├── onboarding/
│   │   └── role_selection_screen.dart ✅ 3 pasos: rol → nombre/email → datos fiscales (si empresa)
│   ├── customer/
│   │   └── cotizacion_screen.dart     ✅ Cotizador con mapa oscuro, auto-zoom, fallback haversine y hook de crédito B2B
│   └── home/
│       ├── home_cliente_screen.dart   ⚠️  Placeholder — grid de flota, sin cotizador real
│       └── home_chofer_screen.dart    ⚠️  Placeholder — toggle disponibilidad, stats estáticos
├── theme/
│   ├── fretix_colors.dart             ✅ Design tokens — accent migrado a Cobre 0xFFD4A373 (2026-06-30)
│   └── fretix_theme.dart              ✅ ThemeData dark
functions/
├── index.js                           ✅ Entry point — exporta onboarding + cotizacion
├── src/
│   ├── onboarding.js                  ✅ completarOnboardingFretix (v2 onCall, escribe /users/{uid})
│   ├── cotizacion.js                  ✅ cotizarViajeFretix — Google Maps + fallback Haversine + motor de tarifas
│   └── seed.js                        ✅ Seed /config/tarifas y /config/app para emulador (npm run db:seed)
└── package.json                       ✅ node 22, firebase-functions, firebase-admin, axios
firebase.json                          ✅ Auth:9099, Functions:5001, Firestore:8080, nodejs22
```

---

## Flujo de auth completo (funcionando en emulador)

```
PhoneInputScreen
  → ingresa número (ej: 2616637057 → se prefija como +5492616637057)
  → Firebase Auth OTP (emulador puerto 9099)
OtpScreen
  → ingresa código (emulador: 123456)
  → isNewUser=true  → RoleSelectionScreen
  → isNewUser=false → lee /users/{uid}.role en Firestore → home correcto
RoleSelectionScreen (3 pasos)
  → Paso 1: selecciona rol (cliente / empresa / chofer / empresa_transporte)
  → Paso 2: nombre + email
  → Paso 3: datos fiscales (solo si empresa/empresa_transporte)
  → "Crear mi cuenta" → llama completarOnboardingFretix Cloud Function
    → en emulador: error de CORS ignorado, navega igual al home
    → en producción: escribe en Firestore y navega
HomeClienteScreen / HomeChoferScreen (placeholders)
```

---

## Decisiones técnicas tomadas

### USE_EMULATOR compile-time flag
```dart
const useEmulator = bool.fromEnvironment('USE_EMULATOR', defaultValue: false);
```
Build para testing: `flutter build web --dart-define=USE_EMULATOR=true`  
**Por qué:** `kDebugMode` es false en builds de producción/release, no sirve para emulador en Codespaces.

### GlobalKey NavigatorState (fretixNavigatorKey)
Navegación desde `auth_service.dart` sin BuildContext.  
**Por qué:** la Cloud Function puede tardar y el widget puede estar desmontado al resolver.

### CORS/Mixed Content en Codespaces
App servida en HTTPS (`*.app.github.dev`). Firebase Auth emulador (9099) funciona vía SDK interno. Firebase Functions emulador (5001) es HTTP → bloqueado por browser como Mixed Content.  
**Workaround para emulador:** `ejecutarOnboardingBackend()` captura el error y navega igual.  
**Para producción:** deploy real en Firebase Hosting + Functions → sin problema.

### Cloud Function onboarding atómico
`completarOnboardingFretix` en `functions/src/onboarding.js`:
- Valida que el usuario esté autenticado (context.auth)
- Valida campos: displayName, role (enum estricto)
- Escribe `/users/{uid}` en Firestore
- Si role=empresa o empresa_transporte: crea también `/empresas/{uid}` en transacción atómica

---

## Pendiente (próximos módulos)

### Prioridad 1 — Cotizador (corazón del negocio)
- [x] Pantalla selección de tipo de flete (Mini/Plus/Max/Carga)
- [x] Llamada a Google Maps Directions API → distancia en KM + tiempo en min (con fallback Haversine ×1.35)
- [x] Cálculo de tarifa con fórmula (lee `/config/tarifas` en runtime desde Firestore)
- [x] Pantalla de resumen de cotización con desglose (precio animado, carrusel, switch ayudante)
- [ ] Input origen/destino con Google Maps Places Autocomplete — pendiente MapsService (Módulo 4)
- [ ] Botón "Confirmar pedido" funcional → crea documento en Firestore `/viajes/{id}` — pendiente Módulo 4

### Prioridad 2 — Matcheo de choferes
- [ ] Cloud Function `buscarChoferesDisponibles` → query Firestore choferes con `disponible=true` en radio 5km
- [ ] Push notification al chofer (FCM)
- [ ] Pantalla chofer: card de oferta con origen/destino/precio → Aceptar/Rechazar
- [ ] Estado del viaje: pending → accepted → in_progress → completed

### Prioridad 3 — Panel Admin
- [ ] Modificar tarifas base/KM/min por categoría (escribe `/config/tarifas`)
- [ ] Modificar tiempo de espera gratuito
- [ ] Modificar tarifa ayudante/peón

### Prioridad 4 — B2B Empresa
- [ ] Sub-usuarios (empleados de empresa cliente)
- [ ] Panel maestro empresa
- [ ] Facturación consolidada mensual
- [ ] Cuenta corriente / crédito 15 días

---

## Cómo correr el proyecto localmente (Codespace)

### Terminal 1 — Emuladores Firebase
```bash
cd /workspaces/fretix
firebase emulators:start
```
Puertos: Auth 9099 · Functions 5001 · Firestore 8080

### Terminal 2 — Build y servidor Flutter web
```bash
cd /workspaces/fretix
flutter build web --dart-define=USE_EMULATOR=true
python3 -m http.server 3000 --directory build/web
```

### Terminal 3 — Registrar número de prueba (una vez por sesión de emulador)
```bash
curl -X PATCH "http://localhost:9099/emulator/v1/projects/fretix-dev-jb/config" \
  -H "Content-Type: application/json" \
  -d '{"signIn":{"phoneNumber":{"+5492616637057":"123456"}}}'
```

### URL de la app
```
https://redesigned-cod-57x7rq7w9gg37x6g-3000.app.github.dev
```

---

### Módulo 3 — Tarifas y Mapas: CIERRE PARCIAL 2026-06-30
UI operativa en `lib/screens/customer/cotizacion_screen.dart`. Motor de tarifas en `functions/src/cotizacion.js`.  
TODOs bloqueantes para cierre total: MapsService (Places Autocomplete para input origen/destino) y botón "Confirmar" funcional — ambos en alcance de Módulo 4.

---

## Convención de commits

```
feat(modulo): descripción corta
fix(modulo): descripción corta
refactor(modulo): descripción corta
chore: descripción corta
```

Ejemplos usados:
- `feat(auth): phone OTP flow with Firebase emulator`
- `feat(onboarding): 3-step role selection screen`
- `feat(home): placeholder screens for cliente and chofer`
- `fix(auth): use compile-time USE_EMULATOR flag instead of kDebugMode`
- `fix(otp): navigate existing users to correct home based on Firestore role`
- `fix(auth): catch Functions CORS error in emulator mode and navigate anyway`
