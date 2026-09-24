# KYC_DESIGN_LOG — Diseño del flujo de verificación de identidad (KYC)

**Fecha:** 2026-09-24  
**Estado:** Documento de diseño — sin código implementado  
**CPO:** joacoberriosb@gmail.com

---

## Contexto y motivación

Fretix opera en un mercado de carga y logística donde el chofer conduce un vehículo de trabajo con bienes de terceros. El KYC (Know Your Customer / verificación de identidad) cubre dos actores:

1. **Chofer (conductor):** ya tiene validación parcial de vehículo vía Tarjeta Verde + OCR (`validarTarjetaVerdeFretix`). Falta verificación de identidad personal.
2. **Cliente (empresa/particular):** actualmente sin verificación formal. Solo autenticación por OTP de teléfono.

---

## Alcance de este documento

Este documento cubre **solo el diseño** del flujo KYC para choferes (Fase 1). El KYC de clientes se pospone para Fase 2.

---

## Estado actual del flujo de onboarding de choferes

```
OTP → RoleSelection → SubirTarjetaVerdeScreen → HomeChofer
              ↓
    validarTarjetaVerdeFretix (CF)
              ↓
    estadoValidacion: pendiente_ocr → validado | pendiente_revision
```

El vehículo queda en `estadoValidacion: 'validado'` pero **no hay verificación del chofer como persona** (DNI, selfie, antecedentes).

---

## Propuesta de diseño — KYC personal del chofer

### Datos a verificar

| Campo | Prioridad | Método de verificación |
|-------|-----------|----------------------|
| DNI frente y dorso | Alta | OCR + validación manual fallback |
| Selfie con DNI | Alta | Comparación facial (humano o Vision API) |
| Licencia de conducir | Alta | OCR + fecha de vencimiento |
| Antecedentes penales | Media | Manual (certificado del chofer) |

### Estados del chofer (propuesta)

```
kycPendiente → kycEnRevision → kycAprobado | kycRechazado
```

Nuevo campo en `/users/{uid}`: `estadoKyc: String`.

### Flujo propuesto

```
SubirTarjetaVerde (vehículo) ✓
        ↓
KycDniScreen (DNI frente + dorso)
        ↓
KycSelfieScreen (selfie con DNI en mano)
        ↓
KycLicenciaScreen (licencia de conducir)
        ↓
KycEnviadoScreen (confirmación — "en revisión")
        ↓
[Admin revisa en admin_validaciones_screen.dart → aprueba/rechaza]
        ↓
HomeChofer (si kycAprobado) | Banner subsanación (si kycRechazado)
```

### Bloqueo de viajes

Un chofer con `kycAprobado == false` NO aparece en el pool de choferes disponibles aunque tenga `disponibleParaViajes: true`. La CF `buscarChoferesCercanos` (existente o futura) debe verificar `estadoKyc == 'kycAprobado'`.

### Impacto en reglas de Firestore

**Decisión pendiente del CPO** — cualquier cambio a `firestore.rules` requiere:
1. Diff completo
2. Tabla de impacto
3. Aprobación explícita antes de aplicar

Propuesta (sin código — solo intención):
- `/users/{uid}`: el chofer puede leer/escribir su propio doc KYC fields durante onboarding
- `/vehiculos/{id}`: sin cambio
- Solo admins pueden escribir `estadoKyc: 'kycAprobado' | 'kycRechazado'`

---

## Decisiones de producto pendientes del CPO

| # | Decisión | Impacto |
|---|----------|---------|
| CPO-KYC-01 | ¿Se usa Google Cloud Vision para OCR del DNI? (costo real) | Requiere `USE_REAL_OCR=true` + aprobación separada |
| CPO-KYC-02 | ¿Verificación facial automática o 100% manual? | Define si se integra Vision API o solo admin review |
| CPO-KYC-03 | ¿El KYC bloquea o solo alerta al chofer? | Impacto en disponibilidad de choferes en producción |
| CPO-KYC-04 | ¿Antecedentes penales requeridos en Fase 1? | Define alcance del onboarding |
| CPO-KYC-05 | ¿Cómo se notifica al chofer cuando el KYC es aprobado/rechazado? | Depende de Tarea 2 (push notifications — bloqueada) |

---

## Dependencias técnicas

- **Tarea 2 (VAPID / push notifications):** bloqueada — sin CF para enviar notificación de aprobación KYC
- **`USE_REAL_OCR`:** actualmente `false` en producción. Activar implica costo de Google Cloud Vision
- **`admin_validaciones_screen.dart`:** ya existe, podría extenderse para revisar KYC docs

---

## Lo que NO se cubre en este documento

- KYC de clientes (empresa/particular) — Fase 2
- Integración con registros de RENAPER o equivalente
- Scoring de riesgo

---

## Referencias

- `lib/screens/chofer/subir_tarjeta_verde_screen.dart` — flujo OCR vehículo existente
- `lib/screens/admin/admin_validaciones_screen.dart` — panel admin existente
- `lib/services/auth_service.dart:278` — VAPID placeholder (Tarea 2, bloqueada)
- `functions/src/confirmar_carga.js` — ejemplo de CF en_transito (patrón reutilizable)
