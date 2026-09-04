# VALIDACION_LOG — Módulo Validación de Tarjeta Verde

> Sesión: 2026-09-04
> Rama: `feature-validacion-vehiculo-20260904`
> Fuente de verdad del diseño: `REPORTE_CEO_CTO_04092026.md`
> Autor: Claude Sonnet 4.6

---

## TAREA 1 — Diseño de esquema

### Timestamp: 2026-09-04T00:00

### Colección nueva: `/vehiculos/{vehiculoId}`

```
vehiculoId:              string (auto-ID Firestore)
choferUid:               string  ← uid del propietario del vehículo
companyId:               string | null  ← null para chofer_independiente
categoriaVehiculo:       string  ← etiqueta visual ('utilitario','pickup',
                                   'camion_liviano','camion_frio',
                                   'camion_mediano','camion_mudanza')
capacidadMaxKg:          number | null  ← null hasta validar (default seguro)
estadoValidacion:        'pendiente_ocr' | 'pendiente_revision' |
                          'pendiente_subsanacion' | 'validado'
tarjetaVerdeStoragePath: string  ← path en Firebase Storage
pbtExtraido:             number | null  ← Peso Bruto Total extraído por OCR
taraExtraida:            number | null  ← Tara extraída por OCR
validadoEn:              timestamp | null
validadoPor:             string | null  ← uid del operador (Capa 2), null si fue OCR
createdAt:               timestamp
```

### Por qué colección propia y no campo en `/users/{uid}`

Un usuario con rol `empresa_transporte_maestro` puede tener flota con múltiples
vehículos (camión mediano + utilitario + pickup). Si el esquema fuera un campo
plano en `/users/{uid}`, solo podría registrar un vehículo por cuenta.
La colección `/vehiculos/` permite N vehículos por choferUid y N vehículos por
companyId. El matcheo consulta `/vehiculos/` buscando el vehículo del chofer en
estado `validado` con mayor (o suficiente) `capacidadMaxKg` para el viaje.

### Catálogo de referencia (rangos de razonabilidad OCR)

Definido en `functions/src/validar_tarjeta_verde.js` como `CATALOGO_REFERENCIA`:

```javascript
const CATALOGO_REFERENCIA = {
  utilitario:     { minKg: 500,   maxKg: 900   },
  pickup:         { minKg: 800,   maxKg: 1200  },
  camion_liviano: { minKg: 1400,  maxKg: 2600  },
  camion_frio:    { minKg: 1400,  maxKg: 4100  },
  camion_mediano: { minKg: 4000,  maxKg: 6000  },
  camion_mudanza: { minKg: 2400,  maxKg: 5000  },
};
```

Si `capacidadMaxKg` calculado por OCR cae fuera del rango de su categoría,
el documento pasa a `pendiente_revision` aunque los campos se hayan leído
correctamente — señal de que la foto es de otro vehículo o el texto fue
mal interpretado.

### Nuevo campo en `/viajes/{viajeId}`: `cargaKg`

El cotizador deberá incluir el peso estimado de la carga al crear el viaje,
para que el matcheo pueda comparar contra `capacidadMaxKg` del vehículo.
**Decisión pendiente del CPO (DP-1):** ¿El cliente ingresa `cargaKg` explícitamente,
o se infiere de la categoría seleccionada? Documentado abajo.

### Compatibilidad con `categoriaVehiculo` existente

El campo `categoriaVehiculo` en `/users/{uid}` (valores `mini|plus|max|heavy`)
pasa a ser **legado**. El matcheo del módulo anterior lo usaba; el nuevo módulo
usa `/vehiculos/{vehiculoId}.capacidadMaxKg`. Durante la transición ambos
coexisten. Se documenta en TAREA 9 (CONTEXT_FOR_AI.md).

---

## TAREA 2 — Storage rules

### Timestamp: 2026-09-04T00:10

### Diff propuesto — PENDIENTE APROBACIÓN CPO

El proyecto usa Firebase Storage. Las reglas actuales están en `storage.rules`.

```diff
+  // /tarjetas_verde/{choferUid}/{fileName}
+  // Acceso: solo el chofer dueño o un admin.
+  // No negociable — dato de documento privado (Tarjeta Verde).
+  match /tarjetas_verde/{choferUid}/{fileName} {
+    allow read:  if request.auth != null
+                 && (request.auth.uid == choferUid
+                     || request.auth.token.get('role','') == 'admin');
+    allow write: if request.auth != null
+                 && request.auth.uid == choferUid;
+    allow delete: if false;
+  }
```

### Tabla de impacto

| Operación | Resultado |
|---|---|
| Chofer lee su propia Tarjeta Verde | ✅ permitido |
| Admin lee cualquier Tarjeta Verde | ✅ permitido |
| Otro usuario (cliente, otro chofer) lee la imagen | ❌ denegado |
| Chofer sube su propia imagen | ✅ permitido |
| Chofer borra su imagen | ❌ denegado (inmutabilidad del documento) |
| Cloud Function (Admin SDK) lee/escribe | ✅ bypasea reglas |

**Estado: PENDIENTE APROBACIÓN. No aplicado.**

---

## TAREA 3 — Cloud Function de OCR (Capa 1)

### Timestamp: 2026-09-04T00:20

**Archivos creados:**
- `functions/src/validar_tarjeta_verde.js`
- `functions/test/validar_tarjeta_verde.test.js`
- `functions/index.js` (export agregado)

**Flag de control:** `USE_REAL_OCR` en `.env` de functions (default `false`).
Con `false`: retorna datos mock para testear el flujo sin costo.
Con `true`: llama a Google Cloud Vision API TEXT_DETECTION.

**Regex de extracción:**
- PBT: `/PBT[:\s]+(\d[\d.,]+)\s*[Kk][Gg]/`
- Tara: `/[Tt][Aa][Rr][Aa][:\s]+(\d[\d.,]+)\s*[Kk][Gg]/`

**Umbral de confianza:** si Vision API retorna `confidence < 0.85` en algún
bloque de texto relevante, el campo se considera no extraído.

---

## TAREA 4 — Notificación push al operador

### Timestamp: 2026-09-04T00:30

**Archivos creados/modificados:**
- `functions/src/actualizar_fcm_token.js` (nuevo — la CF que faltaba)
- `functions/src/validar_tarjeta_verde.js` (dispara push al pasar a pendiente_revision)
- `lib/services/auth_service.dart` (conecta actualizarFcmToken a la nueva CF)

---

## TAREA 5 — Pantalla de operador /admin/validaciones

### Timestamp: 2026-09-04T00:40

**Archivos creados/modificados:**
- `lib/screens/admin/admin_validaciones_screen.dart` (nuevo)
- `lib/router/app_router.dart` (nueva ruta bajo _AdminGuard)

---

## TAREA 6 — Subsanación por el chofer (Capa 3)

### Timestamp: 2026-09-04T00:50

**Archivo modificado:** `lib/screens/home/home_chofer_screen.dart`
Banner detecta `estadoValidacion == 'pendiente_subsanacion'` en el documento
del vehículo y muestra instrucciones para resubir.

---

## TAREA 7 — Motor de matcheo actualizado

### Timestamp: 2026-09-04T01:00

**Decisión: Opción C (híbrida).** El viaje sigue usando categoría string
(`mini|plus|max|heavy`). El vehículo ya usa kg reales (`capacidadMaxKg`).
Puente temporal con `UMBRAL_KG_POR_CATEGORIA`.

**Archivos modificados:**
- `functions/src/aceptar_viaje.js`
- `functions/test/aceptar_viaje.test.js`
- `lib/screens/home/home_chofer_screen.dart`

### Mapeo categoría de viaje → kg mínimo requerido

```javascript
const UMBRAL_KG_POR_CATEGORIA = {
  mini:  500,   // utilitario minKg
  plus:  800,   // pickup minKg
  max:   1400,  // camion_liviano minKg
  heavy: 4000,  // camion_mediano minKg
};
```

Fuente: `minKg` del `CATALOGO_REFERENCIA` en `validar_tarjeta_verde.js`.

### Lógica de aceptarViajeFretix (nuevo orden)

1. Verificar rol de chofer y `disponibleParaViajes`
2. Buscar vehículo con `estadoValidacion == 'validado'` en `/vehiculos/`
   — si no existe, rechazado **antes** de comparar capacidad
3. Leer `capacidadMaxKg` del vehículo validado
4. Transacción: verificar `estado == 'pending'`, luego `capacidadMaxKg >= umbral`

### Limitación conocida — sin techo de capacidad

El chequeo es `capacidadMaxKg >= umbral(categoria)` **sin cota superior**.
Un vehículo sobredimensionado (ej: camion_mediano 4900 kg) puede aceptar
un viaje `'mini'` (umbral 500 kg). Esto es ineficiente operativamente
(asignación subóptima) pero no es una falla de seguridad.

**Pendiente como futura Tarea "matcheo por mejor ajuste"**, fuera del
alcance de este módulo. Cubierto explícitamente por un test unitario
(`'sin techo — comportamiento documentado'`).

### Puente temporal — pendiente migración completa (DP-1)

La migración completa (Opción A: cliente declara `cargaKg` al cotizar,
el viaje lleva ese campo, el matcheo compara exacto) queda como pendiente
explícito para una sesión futura. El cotizador actual no captura `cargaKg`.
Marcado con `TODO(CPO/DP-1)` en el código.

---

## TAREA 8 — Migración de choferes existentes

### Timestamp: 2026-09-04T01:10

Instrucciones manuales para que el CPO valide choferes de prueba existentes.

---

## TAREA 9 — CONTEXT_FOR_AI.md actualizado

### Timestamp: 2026-09-04T01:20

---

## TAREA 10 — Vision API real contra emulador

### Timestamp: 2026-09-04T01:30

---

## Decisiones pendientes del CPO

### DP-1: ¿Cómo ingresa `cargaKg` al viaje?

El matcheo nuevo compara `capacidadMaxKg` del vehículo contra el peso de la
carga del viaje. El cotizador actual no captura peso. Opciones:

**Opción A:** El cliente ingresa `cargaKg` explícitamente en el cotizador
(campo nuevo, obligatorio). Más preciso, más fricción.

**Opción B:** Se infiere del límite inferior de la categoría seleccionada
(ej: `utilitario` → 500 kg, `pickup` → 800 kg). Menos fricción, menos preciso.

**Bloqueante para Tarea 7.** Implementación provisional: usar el límite inferior
de la categoría (Opción B) para no bloquear el resto del módulo, marcado con
`// TODO(CPO): reemplazar por campo explícito si se aprueba Opción A`.

### DP-2: Nombre del path de Storage para Tarjeta Verde

Propuesto: `/tarjetas_verde/{choferUid}/{vehiculoId}_{timestamp}.jpg`
¿El chofer puede resubir múltiples versiones (Capa 3) y quedar todas guardadas,
o se sobreescribe la anterior? Implementación actual: mantiene historial
(nombre único por timestamp). Confirmar si eso es correcto.

### DP-3: ¿Cuántos vehículos máximo por chofer?

No hay límite implementado. ¿Hay un máximo de negocio (ej: 1 para
`chofer_independiente`, N para `empresa_transporte_maestro`)?

---

## Estado de producción

**Confirmación explícita: NO se tocó producción en ningún momento durante esta sesión.**
- No se corrió `firebase deploy` a producción
- No se hicieron escrituras directas a Firestore de producción
- Storage rules: pendiente aprobación CPO (Tarea 2)
- Todo el trabajo está en la rama `feature-validacion-vehiculo-20260904`
