# REPORTE CEO → CTO — SESIÓN [04/09/2026]
**Tema:** Alta de Chofer — Arquitectura de Validación de Tarjeta Verde

---

## DECISIÓN CERRADA POR EL CPO

El catálogo fijo de vehículos por categoría deja de ser la fuente primaria de matcheo. La fuente de verdad de carga útil es la Tarjeta Verde del vehículo real del chofer. El catálogo de referencia pasa a rol secundario: validación de razonabilidad del dato extraído y etiquetado visual por categoría en el cotizador para el cliente.

---

## FLUJO DE ALTA DE CHOFER — TRES CAPAS

### Capa 1 — OCR automático (primaria)

El chofer sube foto o PDF de su Tarjeta Verde al darse de alta. El sistema extrae automáticamente los campos PBT (Peso Bruto Total) y tara. Calcula carga útil real = PBT − tara. Ese valor queda persistido en el perfil del vehículo en Firestore como campo `capacidadMaxKg`. Si la extracción es exitosa, el chofer queda habilitado de forma inmediata para recibir viajes, sin intervención humana.

### Capa 2 — Corrección manual por operador (excepción)

Si el sistema no puede leer uno o más campos con certeza suficiente, el registro queda en estado `pendiente_revision`. Se dispara notificación push al operador (CPO en esta etapa). El operador carga manualmente el campo que el OCR no pudo resolver. El chofer queda habilitado una vez que el operador completa el campo.

### Capa 3 — Subsanación por el chofer (último recurso)

Si el documento es ilegible incluso para el operador, el chofer recibe una notificación solicitando que reenvíe la tarjeta verde en mejor calidad. El registro queda bloqueado hasta que el nuevo documento sea procesado exitosamente por Capa 1 o Capa 2.

---

## REGLA DE NEGOCIO NO NEGOCIABLE

Mientras el campo `capacidadMaxKg` del vehículo esté en cualquier estado que no sea `validado` (`pendiente_ocr`, `pendiente_revision`, `pendiente_subsanacion`), el chofer y su vehículo quedan bloqueados del pool de matcheo. No existe ningún caso en que un vehículo sin carga útil validada pueda recibir un viaje. **Principio default seguro: campo nulo o no definido = bloqueado.**

---

## NOTIFICACIONES

El sistema debe disparar notificación push al dispositivo del operador cada vez que una tarjeta verde caiga en estado `pendiente_revision`. El tiempo de respuesta del operador es el único cuello de botella en la habilitación del chofer, por lo que la notificación es crítica para la promesa de alta rápida.

---

## CATÁLOGO DE VEHÍCULOS — ROL SECUNDARIO

El catálogo tiene dos funciones exclusivamente:
- (a) validar razonabilidad del dato extraído por OCR
- (b) mostrar categorías comprensibles al cliente en el cotizador sin exponer datos técnicos de PBT y tara

Los valores de `capacidadMaxKg` por categoría son **rangos de referencia, no topes operativos**. El tope operativo real es siempre el dato extraído de la Tarjeta Verde del vehículo específico.

| Categoría (snake_case) | Modelos de referencia | Carga útil referencia |
|---|---|---|
| `utilitario` | Renault Kangoo Furgón 1.6/1.5dCi | 540–600 kg |
| `utilitario` | Citroën Berlingo Furgón VTI/HDI | 800 kg |
| `utilitario` | Peugeot Partner Confort 1.6/HDI | 800 kg |
| `pickup` | Ford Ranger Diesel Cab. Simple 4x2 | 1.086 kg |
| `pickup` | Ford Ranger Diesel Cab. Simple 4x4 | 1.117 kg |
| `pickup` | Ford Ranger Diesel Cab. Doble 4x2/4x4 | 861–975 kg |
| `pickup` | VW Amarok 2.0 TDI (todas las versiones) | Pendiente verificación oficial |
| `camion_liviano` | Iveco Daily 35S | 1.500–2.500 kg (estimado) |
| `camion_frio` | Iveco Daily Frigorífico / Accelo térmico | 1.500–4.000 kg (estimado) |
| `camion_mediano` | Mercedes-Benz Accelo 815/1016 | ~4.900 kg (estimado) |
| `camion_mudanza` | Iveco Daily furgón grande / Accelo baú | 2.500–4.900 kg, ~25 m³ (estimado) |

> **Nota:** valores marcados "estimado" requieren verificación en fuentes oficiales antes de usarlos como referencia de validación OCR. Utilitario y pickup Ranger están verificados en fichastecnicas.org.

> **Nota de arquitectura:** dado que dentro de una misma categoría hay variación significativa de carga útil (ej. Kangoo 540 kg vs Berlingo 800 kg dentro de `utilitario`), el campo `capacidadMaxKg` debe ser por vehículo registrado, no por categoría genérica. La categoría es solo etiqueta visual.

---

## VEHÍCULOS NO CATALOGADOS

Si un chofer registra un vehículo que no figura en el catálogo de referencia, el operador debe buscar la ficha técnica oficial del modelo, extraer PBT y tara, calcular carga útil, y cargar ese modelo al catálogo interno de FRETIX para uso futuro. El alta del chofer no se bloquea por esto; se bloquea únicamente si la Tarjeta Verde no pudo ser procesada correctamente.

---

## MÉTRICAS A INSTRUMENTAR DESDE DÍA UNO

- % de tarjetas verdes procesadas por Capa 1 sin intervención
- % que requieren Capa 2 (operador)
- % que requieren Capa 3 (subsanación al chofer)
- Tiempo promedio de habilitación desde carga del documento

> Si Capa 2 supera el 20%, revisar proveedor de OCR antes de escalar.

---

## FUERA DE ALCANCE PARA ESTE MÓDULO

- Automatización del rol de operador
- Integración automática con fuentes externas para completar modelos no catalogados

---

## CONFIRMACIONES DEL CPO

- **Proveedor de OCR:** Google Cloud Vision API (aprobado)
- **Privacidad de Tarjeta Verde:** solo el `choferUid` dueño del vehículo y usuarios con `isAdmin()` pueden leer la imagen en Storage. Sin excepciones. No negociable.
