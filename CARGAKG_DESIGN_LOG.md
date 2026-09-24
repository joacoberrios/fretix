# CARGAKG_DESIGN_LOG — Diseño del campo cargaKg explícito

**Fecha:** 2026-09-24  
**Estado:** Documento de diseño — esperando aprobación del CPO antes de implementar  
**Decisión del CPO:** `cargaKg` es input explícito del cliente (número de kg), no inferido de categoría.

---

## Contexto: estado actual

El viaje en Firestore tiene `categoria: 'mini' | 'plus' | 'max' | 'heavy'`.  
`aceptarViajeFretix` usa `UMBRAL_KG_POR_CATEGORIA` para validar que el vehículo del chofer alcanza:

```javascript
// aceptar_viaje.js — líneas 14-19
const UMBRAL_KG_POR_CATEGORIA = {
  mini:  500,
  plus:  800,
  max:   1400,
  heavy: 4000,
};
// ...
const umbral = UMBRAL_KG_POR_CATEGORIA[viaje.categoria];
if (capacidadMaxKg < umbral) { throw ... }
```

**Limitación documentada** (comentario en el código):
> "Sin techo: vehículo grande puede tomar viaje chico (limitación conocida)"  
> "TODO(CPO/DP-1): reemplazar por campo cargaKg explícito en el viaje cuando el cotizador lo capture (Opción A futura)."

---

## 1. Dónde se agrega el input en CotizacionScreen

**Ubicación:** inmediatamente después del selector de categoría, antes del botón "Ver cotización".

El selector de categoría ya existe. El cliente elige `mini/plus/max/heavy` para la tarifa. El campo `cargaKg` se agrega como un campo de texto numérico debajo:

```
┌─────────────────────────────────────────┐
│  Tipo de flete                          │
│  [mini] [plus] [max] [heavy]            │
│                                         │
│  Peso aproximado de la carga (kg)       │
│  ┌──────────────────────────────────┐   │
│  │  0                               │   │
│  └──────────────────────────────────┘   │
│  * Necesario para asignarte el vehículo │
│    adecuado                             │
└─────────────────────────────────────────┘
```

**Validación client-side:**
- `cargaKg <= 0` → error: "El peso debe ser mayor a 0 kg."
- `cargaKg > 40_000` → warning (no bloqueante): "¿Estás seguro? Eso supera los 40.000 kg — confirmá el peso antes de continuar."
- Teclado: `TextInputType.number`
- Tipo Dart: `int` (kg enteros; sin decimales — es una estimación)

**Nota sobre consistencia categoría/peso:**
El cliente puede ingresar `cargaKg = 100` y elegir categoría `heavy`. Eso es válido — la tarifa depende de la categoría (servicio elegido), no del peso declarado. El peso es para matching con el vehículo. No se recomienda bloquear al cliente si el peso no "matchea" la categoría elegida, porque los casos edge son muchos (mudanzas, cargas voluminosas/livianas, etc.).

---

## 2. Categorías vs cargaKg: ¿coexisten o cargaKg las reemplaza?

**Recomendación técnica: coexisten. Las categorías permanecen como dimensión de precio; cargaKg es la restricción de capacidad.**

**Por qué:**

| Dimensión | Categoría | cargaKg |
|-----------|-----------|---------|
| Determina | Tarifa (base/km/min) | Capacidad mínima del vehículo |
| Definida por | Cliente (percepción del servicio) | Cliente (dato físico de la carga) |
| Usada en | `cotizarViajeFretix`, `confirmarViajeFretix` | `aceptarViajeFretix` (matching) |
| ¿Reemplazable? | No — las tarifas están keyed en mini/plus/max/heavy | Sí reemplaza a UMBRAL_KG_POR_CATEGORIA en matching |

Las categorías son el contrato de servicio (tipo de camión esperado, tarifa acordada). `cargaKg` es un dato operativo. Un cliente puede querer un camión `heavy` con 800 kg porque necesita un vehículo grande por volumen, no por peso. Eliminar categorías requeriría rediseñar el modelo tarifario completo — fuera de alcance de esta tarea.

---

## 3. Impacto en confirmarViajeFretix y aceptarViajeFretix (diff conceptual)

### `confirmar_viaje.js` — diff conceptual

```diff
  const d = request.data;

  if (!d.categoria || !CATEGORIAS_VALIDAS.has(d.categoria)) {
    throw new HttpsError('invalid-argument', 'Categoría inválida.');
  }
+ // Nuevo: validar cargaKg
+ if (!d.cargaKg || typeof d.cargaKg !== 'number' || d.cargaKg <= 0) {
+   throw new HttpsError('invalid-argument', 'cargaKg requerido y debe ser > 0.');
+ }
+ if (d.cargaKg > 40_000) {
+   // Warning logueado pero no bloqueante (validación UX ya hizo confirmación)
+   console.warn(`[confirmar] cargaKg alto: ${d.cargaKg} kg`);
+ }

  // ... en el objeto guardado en Firestore:
  docRef = await db.collection('viajes').add({
    clienteUid:    uid,
    categoria:     d.categoria,
+   cargaKg:       d.cargaKg,        // ← nuevo campo
    // ... resto sin cambios
  });
```

### `aceptar_viaje.js` — diff conceptual

```diff
- // Opción C: umbral mínimo por categoría; sin techo documentado.
- const umbral = UMBRAL_KG_POR_CATEGORIA[viaje.categoria];
- if (!umbral) {
-   throw new HttpsError('failed-precondition', `Categoría de viaje desconocida: '${viaje.categoria}'.`);
- }
- if (capacidadMaxKg < umbral) {
-   throw new HttpsError('failed-precondition', `Tu vehículo (${capacidadMaxKg} kg) no alcanza...`);
- }

+ // Opción A: usar cargaKg explícito cuando está disponible.
+ // Fallback a UMBRAL_KG_POR_CATEGORIA para viajes legados (sin cargaKg).
+ if (viaje.cargaKg) {
+   if (viaje.cargaKg > capacidadMaxKg) {
+     throw new HttpsError(
+       'failed-precondition',
+       `Tu vehículo (${capacidadMaxKg} kg máx) no puede transportar esta carga (${viaje.cargaKg} kg).`
+     );
+   }
+ } else {
+   // Legado: viajes sin cargaKg usan el umbral por categoría
+   const umbral = UMBRAL_KG_POR_CATEGORIA[viaje.categoria];
+   if (!umbral) {
+     throw new HttpsError('failed-precondition', `Categoría de viaje desconocida: '${viaje.categoria}'.`);
+   }
+   if (capacidadMaxKg < umbral) {
+     throw new HttpsError('failed-precondition', `Tu vehículo (${capacidadMaxKg} kg) no alcanza...`);
+   }
+ }
```

**Impacto adicional:** El mensaje de error al chofer mejora: antes decía "mínimo 500 kg" (categoría), ahora dice "esta carga pesa X kg" (dato real). Más útil en producción.

---

## 4. Qué pasa con UMBRAL_KG_POR_CATEGORIA

**Recomendación: mantener durante transición, deprecar en la siguiente release.**

`UMBRAL_KG_POR_CATEGORIA` es el puente temporal (Opción C) para viajes sin `cargaKg`. Después de implementar Opción A:

| Período | Estado |
|---------|--------|
| Inmediato | `UMBRAL_KG_POR_CATEGORIA` se mantiene como fallback en `aceptarViajeFretix` |
| Post-release (todos los viajes nuevos tendrán `cargaKg`) | El fallback puede eliminarse en la siguiente iteración |
| Viajes legados en prod | Si tienen `estado: 'pending'` y no tienen `cargaKg` → usan el fallback |

No se elimina en esta tarea. Se agrega el comentario `// DEPRECATED: remover cuando todos los viajes en prod tengan cargaKg` para señalizarlo.

---

## Impacto en Firestore

**Nuevo campo en `/viajes/{id}`:** `cargaKg: number` (entero positivo, en kg)

No modifica `firestore.rules`. El campo es escrito por `confirmarViajeFretix` (CF con admin SDK) y leído por `aceptarViajeFretix` (CF con admin SDK). Las rules del cliente para `/viajes` no cambian.

> Si en el futuro el cliente necesita leer `cargaKg` directamente (ej: mostrar en la UI del viaje activo), sí habría que revisar las rules. Eso no está en alcance de esta tarea.

---

## Resumen de archivos a modificar (cuando el CPO apruebe)

| Archivo | Cambio |
|---------|--------|
| `lib/screens/customer/cotizacion_screen.dart` | Agregar campo `cargaKg` (TextField + validación) y pasarlo a la CF |
| `functions/src/confirmar_viaje.js` | Validar y guardar `cargaKg` en el doc |
| `functions/src/aceptar_viaje.js` | Reemplazar lógica por Opción A + fallback legado |

**STOP — no implementar hasta aprobación explícita del CPO.**
