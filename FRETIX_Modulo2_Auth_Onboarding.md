# FRETIX — Módulo 2: Autenticación, Roles y Onboarding
**Versión:** 1.0 | **Fecha:** 2025-06-29  
**Módulo anterior:** [FRETIX_Arquitectura_Firestore.md](./FRETIX_Arquitectura_Firestore.md)  
**Stack:** Flutter (Dart) + Firebase Auth OTP + Cloud Functions (Node.js v2)

---

## 1. OBJETIVO DEL MÓDULO

Implementar el flujo completo por el cual un usuario nuevo se autentica via SMS, elige su tipo de perfil y queda correctamente insertado en las colecciones de Firestore definidas en el Módulo 1.

---

## 2. ARCHIVOS GENERADOS

| Archivo | Tipo | Responsabilidad |
|---|---|---|
| `lib/services/auth_service.dart` | Dart/Flutter | Servicio singleton de Auth + llamada al onboarding |
| `lib/screens/onboarding/role_selection_screen.dart` | Dart/Flutter | UI de selección de rol (3 pasos) |
| `functions/src/onboarding.js` | Node.js | Cloud Function con transacción atómica Firestore |
| `functions/index.js` | Node.js | Entry point de todas las Cloud Functions |

---

## 3. COMPONENTE 1 — `FretixAuthService` (Dart)

### Ubicación
`lib/services/auth_service.dart`

### Patrón
Singleton (`FretixAuthService.instance`) para acceso global sin necesidad de inyección de dependencias en esta fase.

### Enum de roles
```dart
enum FretixUserRole {
  clienteParticular,        // → 'cliente_particular'
  clienteEmpresaMaestro,    // → 'cliente_empresa_maestro'
  choferIndependiente,      // → 'chofer_independiente'
  empresaTransporteMaestro, // → 'empresa_transporte_maestro'
}
```

### Métodos públicos

#### `verifyPhoneNumber(String phone) → Future<OtpSentResult>`
- Dispara el SMS de Firebase Auth al número con código de país (`+54261...`)
- Registra el callback `verificationCompleted` (auto-resolución Android) pero **no actúa sobre él** — el flujo siempre usa código manual para consistencia iOS/web
- Devuelve `OtpSentResult { verificationId }` que el widget guarda en estado local
- Lanza `FirebaseAuthException` si el número es inválido o hay error de red

#### `signInWithCode({ verificationId, smsCode }) → Future<UserCredential>`
- Crea `PhoneAuthCredential` y llama a `signInWithCredential`
- El widget comprueba `result.additionalUserInfo?.isNewUser` para decidir si navegar al onboarding o directo al home

#### `completarOnboarding({ role, displayName, email?, razonSocial?, cuit?, nombreComercial? }) → Future<void>`
- Llama a la Cloud Function `completarOnboardingFretix` via `httpsCallable`
- Solo envía campos de empresa si el rol lo requiere (no contamina el payload)

#### `signOut() → Future<void>`

### Dependencias requeridas (`pubspec.yaml`)
```yaml
firebase_auth: ^4.x.x
cloud_functions: ^4.x.x
firebase_core: ^2.x.x
```

---

## 4. COMPONENTE 2 — Cloud Function `completarOnboardingFretix` (Node.js)

### Ubicación
`functions/src/onboarding.js` — exportada desde `functions/index.js`

### Trigger
`onCall` (Firebase Functions v2) — llamada desde el cliente Flutter autenticado.

### Región
`us-central1`

### Flujo de decisión

```
Request llega con uid autenticado
        │
        ▼
¿Documento /users/{uid} ya existe?
    │ SÍ → return { alreadyOnboarded: true }   ← Idempotente
    │ NO
        ▼
¿Es rol empresa? (cliente_empresa_maestro | empresa_transporte_maestro)
    │ NO → Escritura simple: /users/{uid}
    │ SÍ
        ▼
db.runTransaction():
    ├── SET /users/{uid}           ← Perfil base
    ├── SET /companies/{autoId}    ← Empresa con datos fiscales
    └── SET /company_members/{autoId} ← Membership owner
    Si cualquier SET falla → rollback total (atomicidad garantizada)
```

### Campos creados en `/companies` según tipo

**`customer` (cliente_empresa_maestro):**
```json
{
  "cuentaCorriente": {
    "habilitada": false,
    "limiteCreditoARS": 0,
    "saldoActualARS": 0,
    "diasCredito": 15,
    "proximoVencimiento": null
  },
  "facturacion": {
    "tipoFactura": "A",
    "ciclo": "mensual"
  }
}
```

**`carrier` (empresa_transporte_maestro):**
```json
{
  "comisionConfig": {
    "porcentajePlatforma": 15,
    "pagoCadaDias": 7
  },
  "facturacion": {
    "tipoFactura": "A",
    "ciclo": "quincenal"
  }
}
```

### Membership generado automáticamente (siempre rol `owner`)
```json
{
  "role": "owner",
  "permisos": {
    "pedirFletes": true,
    "verHistorial": true,
    "gestionarSubusuarios": true,
    "verFacturacion": true,
    "aprobarGastos": true
  },
  "limiteGastoMensualARS": null
}
```

### Respuesta exitosa
```json
// Rol simple:
{ "success": true, "uid": "...", "role": "chofer_independiente" }

// Rol empresa:
{ "success": true, "uid": "...", "role": "cliente_empresa_maestro", "companyId": "..." }

// Segunda llamada (idempotente):
{ "success": true, "alreadyOnboarded": true }
```

### Errores lanzados (`HttpsError`)
| Código | Causa |
|---|---|
| `unauthenticated` | No hay sesión activa |
| `invalid-argument` | Rol inválido, displayName < 2 chars, razonSocial o CUIT faltantes en rol empresa |

---

## 5. COMPONENTE 3 — `RoleSelectionScreen` (Flutter UI)

### Ubicación
`lib/screens/onboarding/role_selection_screen.dart`

### Diseño Visual
- Fondo: `#0D0D0D`
- Acento: `#F5A623` (naranja Fretix)
- Cards: `#1A1A1A` con borde `#2A2A2A`
- Fuente sistema (adaptable a la fuente del ThemeData del proyecto)

### Flujo de 3 pasos con barra de progreso animada

```
PASO 1: Intención
    ├── "Realizar envíos"           → PASO 2A
    └── "Ofrecer vehículo o flota" → PASO 2B

PASO 2A (Envíos):
    ├── Particular                  → PASO 3 (form simple)
    └── Empresa [badge CORPORATIVO] → PASO 3 (form + datos fiscales)

PASO 2B (Transportista):
    ├── Chofer independiente        → PASO 3 (form simple)
    └── Empresa de transporte [CORPORATIVO] → PASO 3 (form + datos fiscales)

PASO 3: Formulario
    ├── Nombre completo (requerido)
    ├── Email (opcional)
    ├── [Si empresa] Razón Social (requerido)
    ├── [Si empresa] CUIT con validación 11 dígitos (requerido)
    ├── [Si empresa] Nombre comercial (opcional)
    └── Botón "Crear mi cuenta" → llama a FretixAuthService.completarOnboarding()
```

### Widgets internos reutilizables
- `_RoleCard` — card táctil con emoji, título, subtítulo, badge opcional y flecha
- `_FretixField` — TextFormField con estilo dark, borde naranja en foco, validación integrada
- `_SectionLabel` — etiqueta de sección en mayúsculas con tracking

### Animación entre pasos
`AnimationController` + `FadeTransition` con `Curves.easeOut` (320ms) en cada transición de paso.

### Navegación de salida
```dart
Navigator.of(context).pushReplacementNamed('/home');
```
> Conectar esta ruta al router del proyecto (GoRouter o Navigator 2.0).

### Asset requerido
```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/images/logo_fretix_white.png
```

---

## 6. FLUJO COMPLETO END-TO-END

```
[App Launch]
      │
      ▼
FirebaseAuth.authStateChanges()
      │
      ├── Usuario logueado + /users existe → NavBar principal (home)
      │
      └── Usuario no logueado
              │
              ▼
        [PhoneInputScreen]  ← (a implementar en Módulo 2B o sprint siguiente)
        ingresa +54261...
              │
              ▼
        FretixAuthService.verifyPhoneNumber()
              │
              ▼
        [OtpInputScreen]  ← (a implementar)
        ingresa código SMS
              │
              ▼
        FretixAuthService.signInWithCode()
              │
              ├── isNewUser = false → home
              └── isNewUser = true
                      │
                      ▼
              [RoleSelectionScreen]  ← IMPLEMENTADO ✅
                      │
                      ▼
              FretixAuthService.completarOnboarding()
                      │
                      ▼
              Cloud Function completarOnboardingFretix  ← IMPLEMENTADO ✅
              (Firestore: /users + /companies? + /company_members?)
                      │
                      ▼
                    home
```

---

## 7. PENDIENTES DEL MÓDULO 2 (Para próximos sprints)

| Pantalla | Estado | Notas |
|---|---|---|
| `PhoneInputScreen` | Pendiente | Input del número con prefijo +54, validación formato |
| `OtpInputScreen` | Pendiente | 6 campos individuales, countdown de reenvío (60s) |
| Re-envío de SMS | Pendiente | Usar `resendToken` del callback `codeSent` |
| Pantalla de carga de documentación (Chofer) | Pendiente | Upload de fotos licencia, seguro — Módulo 3 o 4 |

---

## 8. DECISIONES DE ARQUITECTURA REGISTRADAS

| Decisión | Razonamiento |
|---|---|
| Singleton para `FretixAuthService` | Simplicidad en esta fase; migrar a Provider/Riverpod cuando crezca el árbol de widgets |
| Auto-resolución Android deshabilitada intencionalmente | Mantener flujo idéntico en iOS, Android y web; evitar race conditions en el estado del widget |
| Cloud Function idempotente | Protege contra dobles llamadas por reconexión de red o retry del cliente |
| `db.runTransaction` para roles empresa | Garantía todo-o-nada: nunca un usuario sin empresa ni una empresa sin owner en Firestore |
| Campos empresa con spread condicional | Evita mezclar campos `cuentaCorriente` (customer) con `comisionConfig` (carrier) en el mismo documento |

---

*Documento de referencia para el equipo de desarrollo de FRETIX.*  
*Adjuntar junto a [FRETIX_Arquitectura_Firestore.md](./FRETIX_Arquitectura_Firestore.md) para contexto completo.*
