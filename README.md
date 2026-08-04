# FRETIX — Guía de desarrollo local

Plataforma de fletes B2C/B2B en Flutter Web + Firebase (Cloud Functions, Firestore, Auth).

---

## Requisitos verificados

| Herramienta | Versión | Instalación |
|---|---|---|
| Java (JDK) | OpenJDK 21.0.11 | `brew install openjdk@21` |
| Node.js | v22.23.2 | `nvm install 22` o `brew install node` |
| Firebase CLI | 15.22.4 | `npm install -g firebase-tools` |
| Python | 3.14.6 | (solo para `cors-proxy.js`/`dev-server.js`) |
| Flutter | 3.44.4 / Dart 3.12.2 | Ver sección Flutter más abajo |

> **Java es requerido** por el emulador de Firestore (proceso Java). Sin JDK 21 el emulador no arranca.

---

## Flutter

Flutter **no está en el PATH global** de esta máquina. Usar la ruta completa:

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter <comando>
```

O agregar al shell (`.zshrc`):

```bash
export PATH="$PATH:/Users/joaquinberrios/Documents/flutter/bin"
```

Versión actual: **Flutter 3.44.4 • Dart 3.12.2 • channel stable**

---

## Levantar el entorno local

### 1. Instalar dependencias Node (Cloud Functions)

```bash
cd functions
npm install
```

### 2. Instalar dependencias Flutter

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter pub get
```

### 3. Iniciar los emuladores de Firebase

```bash
firebase emulators:start
```

Puertos que levanta:

| Emulador | Host | Puerto |
|---|---|---|
| Firebase Auth | 127.0.0.1 | 9099 |
| Cloud Functions | 127.0.0.1 | 5001 |
| Firestore | 127.0.0.1 | 8282 |
| Emulator Hub (UI) | 127.0.0.1 | 4400 |

La UI del emulador está en **http://127.0.0.1:4400**.

### 4. Levantar el servidor web de desarrollo

```bash
node dev-server.js
```

Sirve el build en **http://127.0.0.1:3000**.

> `dev-server.js` también corre `cors-proxy.js` para rutas del emulador. Python no se usa para servir el frontend.

### 5. Correr Flutter Web apuntando al emulador

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter run -d chrome \
  --dart-define=USE_EMULATOR=true
```

Para producción (sin emulador):

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter run -d chrome
```

---

## Build web de producción

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter build web --release
```

Output en `build/web/`. Deploy a Firebase Hosting:

```bash
firebase deploy --only hosting
```

> Proyecto de producción: **fretix-dev-jb** — `https://fretix-dev-jb.web.app`

---

## Tests

### Flutter (unit tests)

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter test test/widget_test.dart
```

Corre 6 tests unitarios sobre `FretixUserRole` (lógica pura, sin deps web ni Firebase).

### Cloud Functions (Jest)

Requiere emuladores corriendo (`firebase emulators:start`).

```bash
cd functions
npm test
```

Corre 42 tests en 3 suites: `cotizacion.test.js`, `confirmar_viaje.test.js`, `onboarding.test.js`.

---

## Análisis estático Flutter

```bash
/Users/joaquinberrios/Documents/flutter/bin/flutter analyze
```

Estado limpio: **0 errors, 0 warnings** (solo infos de APIs deprecadas — ver OVERNIGHT_LOG.md).

---

## Variables de entorno

### Cloud Functions (`functions/.env`)

```
MAPS_API_KEY=<tu_clave_de_Google_Maps>
```

Este archivo **nunca se commitea** (está en `.gitignore`).

En producción, la clave se provee via Firebase Secret Manager:

```bash
firebase functions:secrets:set MAPS_API_KEY
```

### Flutter

La flag `USE_EMULATOR` se pasa en tiempo de compilación con `--dart-define`:

```bash
--dart-define=USE_EMULATOR=true   # apunta a emuladores locales
--dart-define=USE_EMULATOR=false  # apunta a producción (default)
```

---

## Arquitectura

```
Flutter Web (browser)
  │
  ├── Firebase Auth (emulador :9099 o producción)
  ├── Firestore (emulador :8282 o producción)
  └── Cloud Functions (emulador :5001 o producción)
         │
         ├── cotizarViajeFretix    ← cotizacion.js
         ├── confirmarViajeFretix  ← confirmar_viaje.js
         └── completarOnboardingFretix ← onboarding.js
```

El switch emulador/producción lo maneja `FretixAuthService.initializeEmulators()` en `lib/services/auth_service.dart`, chequeando la flag `USE_EMULATOR` en runtime.

---

## Rama de trabajo

La rama activa de desarrollo es `overnight-work-20260803`. La rama `main` local tiene divergencia respecto de `origin/main` — **no hacer merge ni force-push sin revisión explícita**.

Backup de la sesión 2026-08-03: rama `session-2026-08-03-deploy-produccion` en origin.

---

## Comandos frecuentes

```bash
# Ver ramas locales vs remote
git branch -vv

# Ver log compacto
git log --oneline -10

# Estado del análisis Flutter
/Users/joaquinberrios/Documents/flutter/bin/flutter analyze 2>&1 | tail -5

# Ver UI de emuladores
open http://127.0.0.1:4400

# Correr solo los tests de Functions
cd functions && npm test

# Correr solo los tests Flutter
/Users/joaquinberrios/Documents/flutter/bin/flutter test
```

---

## Documentación de módulos

| Archivo | Contenido |
|---|---|
| `FRETIX_Arquitectura_Firestore.md` | Esquema de colecciones y reglas Firestore |
| `FRETIX_Modulo2_Auth_Onboarding.md` | Flujo OTP + onboarding por rol |
| `FRETIX_Modulo3_Tarifas_Mapas.md` | Algoritmo de tarifa y cotización |
| `FRETIX_Modulo4_Flujo_Matcheo.md` | Matching chofer-viaje |
| `FRETIX_Modulo5_UI_Flutter.md` | Pantallas y navegación Flutter |
| `FRETIX_Modulo6_Web_Cierre.md` | Deploy web y cierre de sesión |
| `OVERNIGHT_LOG.md` | Log de trabajo nocturno 2026-08-03: tareas, bloqueos, pendientes CPO |
| `BITACORA.md` | Historial de decisiones de arquitectura |
