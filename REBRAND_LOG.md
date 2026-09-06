# REBRAND LOG — Azul Acero (2026-09-06)

## Alcance aprobado
Cambio exclusivamente visual de paleta Cobre → Azul Acero + Plateado.
Sin cambios en Firestore, lógica de negocio ni Cloud Functions.
Rama: `feature-rebrand-azul-acero-20260906`

---

## Tarea 0 — Auditoría grep (hex hardcodeado)

Comando: `grep -rn "D4A373\|d4a373" lib/ --include="*.dart"`

Resultado — hex hardcodeado encontrado **fuera** de `fretix_colors.dart`:

| Archivo | Ocurrencias |
|---------|-------------|
| `lib/screens/admin/admin_validaciones_screen.dart` | 7 |
| `lib/screens/chofer/subir_tarjeta_verde_screen.dart` | 5 |
| `lib/router/app_router.dart` | 5 |
| `lib/screens/customer/cotizacion_screen.dart:5` | solo comentario |

Todos corregidos en esta rama usando `FretixColors.accent` (Tarea 3).
Verificación post-cambio: `grep -rn "D4A373" lib/` → **0 resultados**.

---

## Tarea 1 — fretix_colors.dart

### ANTES
```dart
static const background    = Color(0xFF0D0D0D);
static const accent        = Color(0xFFD4A373); // Cobre Fretix Premium
static const accentDark    = Color(0xFFB8885A);
// (sin accentHighlight, sin surfaceElevated)
```

### DESPUÉS
```dart
static const background      = Color(0xFF080F1C);
static const surfaceElevated = Color(0xFF0D1829);
static const accent          = Color(0xFF8FAAC6); // Azul Acero Fretix
static const accentHighlight = Color(0xFFD3DBE3);
static const accentDark      = Color(0xFFB8885A); // DECISIÓN PENDIENTE CPO — ver abajo
```

### Intactos (sin tocar)
| Token | Valor | Verificado |
|-------|-------|-----------|
| `success` | `0xFF22C55E` | ✅ |
| `danger`  | `0xFFEF4444` | ✅ |
| `surface` | `0xFF1A1A1A` | ✅ |
| `surfaceBorder` | `0xFF2A2A2A` | ✅ |
| `countdown` | `0xFFEF4444` | ✅ |

### Decisión pendiente CPO
`accentDark = Color(0xFFB8885A)` era el Cobre oscurecido del sistema anterior.
Con `accent` ahora siendo Azul Acero `0xFF8FAAC6`, este token quedó semánticamente
huérfano (sigue siendo un marrón cobre oscuro). El comunicado del CMO no lo menciona.
Opciones: a) derivar `accentDark` del nuevo azul (e.g. `0xFF6B8AAD`), b) eliminar el token,
c) dejarlo para uso explícito en componentes legacy. Requiere decisión del CPO antes del merge.

---

## Tarea 2 — cotizacion_screen.dart

### Mapa JSON — ANTES
```json
{"elementType":"geometry",                    "color":"#1a1a1a"}
{"elementType":"labels.text.stroke",          "color":"#0d0d0d"}
{"featureType":"landscape:geometry",          "color":"#111111"}
{"featureType":"road:geometry",               "color":"#2a2a2a"}
{"featureType":"road:geometry.stroke",        "color":"#111111"}
{"featureType":"road.highway:geometry",       "color":"#333333"}
{"featureType":"road.highway:geometry.stroke","color":"#1a1a1a"}
{"featureType":"water:geometry",              "color":"#0d0d0d"}
{"featureType":"administrative:geometry.stroke","color":"#2a2a2a"}
```

### Mapa JSON — DESPUÉS
```json
{"elementType":"geometry",                    "color":"#080f1c"}  ← fondo cartográfico
{"elementType":"labels.text.stroke",          "color":"#080f1c"}
{"featureType":"landscape:geometry",          "color":"#080f1c"}
{"featureType":"road:geometry",               "color":"#d3dbe3"}  ← trazado de ruta
{"featureType":"road:geometry.stroke",        "color":"#0d1829"}
{"featureType":"road.highway:geometry",       "color":"#d3dbe3"}
{"featureType":"road.highway:geometry.stroke","color":"#080f1c"}
{"featureType":"water:geometry",              "color":"#080f1c"}
{"featureType":"administrative:geometry.stroke","color":"#0d1829"}
```

### Pines — ANTES / DESPUÉS
| Pin | Antes | Después |
|-----|-------|---------|
| origen  | `hueOrange` / `40.0` (cobre) | `hueAzure` (210.0) |
| destino | `hueOrange` | `hueAzure` (210.0) |

---

## Tarea 3 — Archivos con hex hardcodeado (Tarea 0)

Acción: reemplazado `Color(0xFFD4A373)` → `FretixColors.accent` + import agregado donde faltaba.

| Archivo | Import agregado | Ocurrencias corregidas |
|---------|----------------|----------------------|
| `admin_validaciones_screen.dart` | ✅ | 7 |
| `subir_tarjeta_verde_screen.dart` | ✅ | 5 |
| `app_router.dart` | ✅ | 5 |

---

## Tarea 4 — Verificación

- `flutter analyze`: 51 info (igual que antes del rebrand, 0 errores/warnings nuevos) ✅
- `flutter build web --release`: Built build/web ✅
- Grep final `D4A373` en `lib/`: **0 resultados** ✅

---

## Pendiente antes del merge
1. **Decisión CPO sobre `accentDark`** — ver sección Tarea 1 arriba.
2. **Revisión visual** en emulador o `flutter run -d chrome` antes de aprobar deploy.
