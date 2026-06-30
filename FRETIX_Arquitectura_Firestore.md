# FRETIX — Arquitectura de Datos Firestore
**Versión:** 1.0 | **Fecha:** 2025-06-29  
**Stack:** Flutter + Firebase (Firestore + Auth OTP + Cloud Functions Node.js) + Google Maps API  
**Mercado:** Mendoza, Argentina

---

## 1. CONTEXTO DEL PROYECTO

Plataforma On-Demand Marketplace de logística estilo Uber. Conecta cargadores (clientes) con transportistas independientes o empresas de transporte en la provincia de Mendoza.

---

## 2. FLOTA / CATEGORÍAS DE VEHÍCULOS

| Categoría | Ejemplos | Uso Principal |
|---|---|---|
| `mini` | Partner, Berlingo, Fiorino | Paquetería pesada, ecommerce, insumos rápidos |
| `plus` | Hilux, Amarok, Ranger | Eventos, catering, mudanzas chicas |
| `max` | Sprinter, Transit | Mudanzas enteras, distribución, pallets livianos |
| `heavy` | Ford Cargo, Mercedes Accelo | Logística industrial, bodegas, pallets pesados |

---

## 3. MODELO DE ROLES B2B

### Lado Cliente (Cargador)
- **Cliente Particular:** usuario individual, pago efectivo o transferencia
- **Cliente Empresa:** CUIT + Razón Social, panel maestro, sub-usuarios autorizados (empleados), Factura A consolidada mensual, Cuenta Corriente a 15 días

### Lado Transportista (Oferta)
- **Chofer Independiente:** dueño de su vehículo, ve sus ganancias, cobra directo
- **Empresa de Transporte:** panel corporativo, gestiona flota propia y choferes empleados (relación de dependencia). La empresa recibe el dinero; el chofer empleado solo opera el viaje sin ver las ganancias totales.

---

## 4. LÓGICA DE TARIFAS

**Fórmula:** `Tarifa = Precio Base + (Precio/KM × Distancia) + (Precio/Min × Tiempo)`

| Categoría | Base | KM | Minuto | Espera Gratis | Costo Espera/Min |
|---|---|---|---|---|---|
| `mini` | $1.800 | $350 | $90 | 15 min | $60 |
| `plus` | $2.800 | $450 | $120 | 15 min | $80 |
| `max` | $6.500 | $700 | $180 | 15 min | $180 |
| `heavy` | $15.000 | $1.200 | $250 | 20 min | $300 |

### Reglas críticas
- Tarifa cerrada antes de confirmar (cotizador con Google Maps Directions + Distance Matrix)
- **Add-on Ayudante/Peón:** monto fijo ($5.000 configurable), va 100% al chofer, **exento de comisión**
- **Comisión Plataforma:** 15% fijo sobre subtotal transporte puro (excluye helperFee)
- **Radio de matcheo de choferes:** 5 km

### Ejemplo de cálculo (Flete Max, 18.4 km, 32 min, 7 min espera extra, con ayudante)
```
Base:                    $  6.500
KM (18.4 × $700):        $ 12.880
Minutos (32 × $180):     $  5.760
Subtotal transporte:     $ 25.140
Extra espera (7 × $180): $  1.260
Base para comisión:      $ 26.400
Comisión 15%:            $  3.960
Ayudante (exento):       $  5.000
──────────────────────────────────
TOTAL CLIENTE:           $ 36.400
Gana chofer/empresa:     $ 22.440
Gana Fretix:             $  3.960
```

---

## 5. COLECCIONES FIRESTORE — MODELOS COMPLETOS

### Escenario de ejemplo
> La bodega **Zuccardi Valle de Uco** (empresa cliente) solicita un Flete Max desde su planta en Maipú hacia Godoy Cruz. El chofer asignado es empleado de **TransAndina Logística S.R.L.** (empresa transportista).

---

### `/users/{userId}`

```json
// users/usr_chofer_empleado_001
{
  "uid": "usr_chofer_empleado_001",
  "displayName": "Rodrigo Alejandro Ferreyra",
  "phone": "+542614783921",
  "email": "rferreyra@transandina.com.ar",
  "photoURL": "https://storage.googleapis.com/fretix/avatars/usr_chofer_empleado_001.jpg",
  "roles": ["driver"],
  "createdAt": "2024-11-03T09:15:00Z",
  "isActive": true,
  "isVerified": true
}

// users/usr_chofer_independiente_002
{
  "uid": "usr_chofer_independiente_002",
  "displayName": "Marcelo Héctor Salinas",
  "phone": "+542614502376",
  "email": "msalinas.flete@gmail.com",
  "photoURL": null,
  "roles": ["driver", "customer"],
  "createdAt": "2024-08-17T14:22:00Z",
  "isActive": true,
  "isVerified": true
}

// users/usr_cliente_empresa_003
{
  "uid": "usr_cliente_empresa_003",
  "displayName": "Valentina Morán",
  "phone": "+542614691847",
  "email": "vmoran@zuccardiuc.com.ar",
  "photoURL": null,
  "roles": ["customer"],
  "createdAt": "2025-01-10T08:00:00Z",
  "isActive": true,
  "isVerified": true
}

// users/usr_sub_empleado_004
{
  "uid": "usr_sub_empleado_004",
  "displayName": "Lucas Ezequiel Pérez",
  "phone": "+542614834562",
  "email": "lperez@zuccardiuc.com.ar",
  "photoURL": null,
  "roles": ["customer"],
  "createdAt": "2025-02-05T10:30:00Z",
  "isActive": true,
  "isVerified": true
}

// users/usr_admin_fretix_000
{
  "uid": "usr_admin_fretix_000",
  "displayName": "Admin Fretix",
  "phone": "+542614000001",
  "email": "admin@fretix.com.ar",
  "photoURL": null,
  "roles": ["admin"],
  "createdAt": "2024-06-01T00:00:00Z",
  "isActive": true,
  "isVerified": true
}
```

---

### `/companies/{companyId}`

```json
// companies/cmp_zuccardi_cliente
{
  "companyId": "cmp_zuccardi_cliente",
  "type": "customer",
  "razonSocial": "Familia Zuccardi S.A.",
  "nombreComercial": "Zuccardi Valle de Uco",
  "cuit": "30-71234567-9",
  "condicionAfip": "responsable_inscripto",
  "direccionFiscal": {
    "calle": "Ruta Provincial 89 S/N",
    "localidad": "Vista Flores",
    "departamento": "Tunuyán",
    "provincia": "Mendoza",
    "codigoPostal": "5563"
  },
  "contactoPrincipal": {
    "nombre": "Valentina Morán",
    "cargo": "Jefa de Logística",
    "email": "vmoran@zuccardiuc.com.ar",
    "phone": "+542614691847"
  },
  "ownerUserId": "usr_cliente_empresa_003",
  "cuentaCorriente": {
    "habilitada": true,
    "limiteCreditoARS": 500000,
    "saldoActualARS": -87500,
    "diasCredito": 15,
    "proximoVencimiento": "2025-07-15"
  },
  "facturacion": {
    "tipoFactura": "A",
    "ciclo": "mensual",
    "emailFacturacion": "contaduria@zuccardiuc.com.ar"
  },
  "createdAt": "2025-01-10T08:00:00Z",
  "isActive": true
}

// companies/cmp_transandina_carrier
{
  "companyId": "cmp_transandina_carrier",
  "type": "carrier",
  "razonSocial": "TransAndina Logística S.R.L.",
  "nombreComercial": "TransAndina",
  "cuit": "30-68912345-1",
  "condicionAfip": "responsable_inscripto",
  "direccionFiscal": {
    "calle": "Av. Mitre 1450",
    "localidad": "Maipú",
    "departamento": "Maipú",
    "provincia": "Mendoza",
    "codigoPostal": "5515"
  },
  "contactoPrincipal": {
    "nombre": "Gustavo Reinaldo Bello",
    "cargo": "Gerente de Operaciones",
    "email": "gbello@transandina.com.ar",
    "phone": "+542614556789"
  },
  "ownerUserId": "usr_admin_transandina_099",
  "cuentaCorriente": null,
  "facturacion": {
    "tipoFactura": "A",
    "ciclo": "quincenal",
    "emailFacturacion": "facturacion@transandina.com.ar"
  },
  "comisionConfig": {
    "porcentajePlatforma": 15,
    "pagoCadaDias": 7
  },
  "createdAt": "2024-09-20T11:00:00Z",
  "isActive": true
}
```

---

### `/company_members/{membershipId}`

```json
// company_members/mbr_vmoran_zuccardi
{
  "membershipId": "mbr_vmoran_zuccardi",
  "userId": "usr_cliente_empresa_003",
  "companyId": "cmp_zuccardi_cliente",
  "role": "owner",
  "permisos": {
    "pedirFletes": true,
    "verHistorial": true,
    "gestionarSubusuarios": true,
    "verFacturacion": true,
    "aprobarGastos": true
  },
  "limiteGastoMensualARS": null,
  "createdAt": "2025-01-10T08:00:00Z",
  "isActive": true
}

// company_members/mbr_lperez_zuccardi
{
  "membershipId": "mbr_lperez_zuccardi",
  "userId": "usr_sub_empleado_004",
  "companyId": "cmp_zuccardi_cliente",
  "role": "sub_user",
  "permisos": {
    "pedirFletes": true,
    "verHistorial": true,
    "gestionarSubusuarios": false,
    "verFacturacion": false,
    "aprobarGastos": false
  },
  "limiteGastoMensualARS": 150000,
  "createdAt": "2025-02-05T10:30:00Z",
  "isActive": true
}

// company_members/mbr_rferreyra_transandina
{
  "membershipId": "mbr_rferreyra_transandina",
  "userId": "usr_chofer_empleado_001",
  "companyId": "cmp_transandina_carrier",
  "role": "driver_employee",
  "permisos": {
    "verGananciasViaje": false,
    "aceptarViajes": true,
    "verAsignaciones": true
  },
  "limiteGastoMensualARS": null,
  "createdAt": "2024-11-03T09:15:00Z",
  "isActive": true
}
```

---

### `/vehicles/{vehicleId}`

```json
// vehicles/veh_sprinter_001
{
  "vehicleId": "veh_sprinter_001",
  "category": "max",
  "marca": "Mercedes-Benz",
  "modelo": "Sprinter 515 CDI",
  "año": 2022,
  "patente": "AB512CD",
  "color": "Blanco",
  "capacidadKg": 1500,
  "volumenM3": 14.5,
  "tieneRefrigeracion": false,
  "tienePlataformaHidraulica": false,
  "fotos": [
    "https://storage.googleapis.com/fretix/vehicles/veh_sprinter_001_front.jpg",
    "https://storage.googleapis.com/fretix/vehicles/veh_sprinter_001_cargo.jpg"
  ],
  "owner": {
    "type": "company",
    "companyId": "cmp_transandina_carrier",
    "userId": null
  },
  "documentacion": {
    "rto_vtv": true,
    "rto_vtv_vencimiento": "2026-03-15",
    "seguro_poliza": "POL-20241102-ART-004456",
    "seguro_vencimiento": "2025-11-02",
    "habilitacion_municipal": "HM-MPU-2024-00892",
    "registro_ruta": "RNT-0045123",
    "registro_ruta_vencimiento": "2026-01-20"
  },
  "isActive": true,
  "isVerified": true,
  "createdAt": "2024-11-05T10:00:00Z"
}

// vehicles/veh_hilux_002
{
  "vehicleId": "veh_hilux_002",
  "category": "plus",
  "marca": "Toyota",
  "modelo": "Hilux 4x4 SR",
  "año": 2020,
  "patente": "NEC314",
  "color": "Gris Oscuro",
  "capacidadKg": 1000,
  "volumenM3": null,
  "tieneRefrigeracion": false,
  "tienePlataformaHidraulica": false,
  "fotos": [
    "https://storage.googleapis.com/fretix/vehicles/veh_hilux_002_front.jpg"
  ],
  "owner": {
    "type": "individual",
    "companyId": null,
    "userId": "usr_chofer_independiente_002"
  },
  "documentacion": {
    "rto_vtv": true,
    "rto_vtv_vencimiento": "2025-09-30",
    "seguro_poliza": "POL-20231215-SANCOR-887721",
    "seguro_vencimiento": "2025-12-15",
    "habilitacion_municipal": "HM-GCRU-2024-00341",
    "registro_ruta": null,
    "registro_ruta_vencimiento": null
  },
  "isActive": true,
  "isVerified": true,
  "createdAt": "2024-08-17T14:30:00Z"
}
```

---

### `/drivers/{driverId}`

> **Campo crítico para matcheo:** `lastLocation` (GeoPoint) + `lastUpdated` (Timestamp).  
> **Campo crítico para visibilidad de ganancias:** `tipo` + `employerCompanyId`.

```json
// drivers/drv_rferreyra_001
{
  "driverId": "drv_rferreyra_001",
  "userId": "usr_chofer_empleado_001",
  "tipo": "empleado",
  "employerCompanyId": "cmp_transandina_carrier",
  "vehicleIdActivo": "veh_sprinter_001",
  "vehiclesHabilitados": ["veh_sprinter_001"],

  "documentacionChofer": {
    "licencia_linti": "B2-00345678-MZA",
    "licencia_linti_vencimiento": "2027-06-30",
    "licencia_linti_categorias": ["B1", "B2", "C1"],
    "rto_vtv": true,
    "registro_ruta": "RNT-DRV-0023456",
    "registro_ruta_vencimiento": "2026-08-15"
  },

  "estadoServicio": "online",
  "lastLocation": {
    "_type": "GeoPoint",
    "latitude": -32.9741,
    "longitude": -68.8120
  },
  "lastUpdated": "2025-06-29T14:37:52Z",

  "stats": {
    "totalViajes": 312,
    "calificacionPromedio": 4.87,
    "totalCalificaciones": 298,
    "cancelaciones": 4,
    "aceptacionRate": 0.94
  },

  "ganancias": {
    "visibleParaChofer": false,
    "descripcion": "Empleado en relación de dependencia — ganancias gestionadas por TransAndina"
  },

  "createdAt": "2024-11-03T09:15:00Z",
  "isActive": true,
  "isVerified": true
}

// drivers/drv_msalinas_002
{
  "driverId": "drv_msalinas_002",
  "userId": "usr_chofer_independiente_002",
  "tipo": "independiente",
  "employerCompanyId": null,
  "vehicleIdActivo": "veh_hilux_002",
  "vehiclesHabilitados": ["veh_hilux_002"],

  "documentacionChofer": {
    "licencia_linti": "B1-00567890-MZA",
    "licencia_linti_vencimiento": "2026-03-20",
    "licencia_linti_categorias": ["B1"],
    "rto_vtv": true,
    "registro_ruta": null,
    "registro_ruta_vencimiento": null
  },

  "estadoServicio": "offline",
  "lastLocation": {
    "_type": "GeoPoint",
    "latitude": -32.8895,
    "longitude": -68.8402
  },
  "lastUpdated": "2025-06-29T11:05:18Z",

  "stats": {
    "totalViajes": 89,
    "calificacionPromedio": 4.72,
    "totalCalificaciones": 81,
    "cancelaciones": 3,
    "aceptacionRate": 0.91
  },

  "ganancias": {
    "visibleParaChofer": true,
    "balancePendienteARS": 34200,
    "totalHistoricoARS": 1285600
  },

  "createdAt": "2024-08-17T14:22:00Z",
  "isActive": true,
  "isVerified": true
}
```

---

### `/trips/{tripId}`

> **Regla de comisión:** `pricing.helperFee.exento_comision = true` → la Cloud Function excluye ese monto antes de calcular el 15%.

```json
// trips/trp_20250629_001
{
  "tripId": "trp_20250629_001",
  "estado": "completed",
  "historialEstados": [
    { "estado": "quoting",     "timestamp": "2025-06-29T13:00:00Z" },
    { "estado": "confirmed",   "timestamp": "2025-06-29T13:02:14Z" },
    { "estado": "assigned",    "timestamp": "2025-06-29T13:03:45Z" },
    { "estado": "in_progress", "timestamp": "2025-06-29T13:18:00Z" },
    { "estado": "completed",   "timestamp": "2025-06-29T14:35:22Z" }
  ],

  "solicitadoPor": {
    "userId": "usr_sub_empleado_004",
    "displayName": "Lucas Ezequiel Pérez",
    "phone": "+542614834562",
    "contexto": "empresa",
    "companyId": "cmp_zuccardi_cliente",
    "membershipId": "mbr_lperez_zuccardi"
  },

  "vehiculoCategoria": "max",

  "opciones": {
    "ayudante": true,
    "notasAdicionales": "Pallets de vino fraccionado, manejo cuidadoso. Acceso por portón lateral."
  },

  "ruta": {
    "origen": {
      "direccion": "Ruta 60, Km 14.5, Zona Industrial Maipú, Mendoza",
      "geoPoint": {
        "_type": "GeoPoint",
        "latitude": -32.9941,
        "longitude": -68.7731
      }
    },
    "destino": {
      "direccion": "Av. San Martín 1250, Godoy Cruz, Mendoza",
      "geoPoint": {
        "_type": "GeoPoint",
        "latitude": -32.9147,
        "longitude": -68.8392
      }
    },
    "distanciaKm": 18.4,
    "duracionMinutos": 32,
    "polyline": "encodedPolylineStringAqui..."
  },

  "pricing": {
    "categoria": "max",
    "tarifasAplicadas": {
      "base": 6500,
      "precioPorKm": 700,
      "precioPorMinuto": 180
    },

    "calculoTransporte": {
      "base": 6500,
      "kmCosto": 12880,
      "minutoCosto": 5760,
      "subtotalTransporte": 25140
    },

    "esperaExtra": {
      "minutosGratis": 15,
      "minutosUtilizados": 22,
      "minutosFacturables": 7,
      "costoExtraEspera": 1260
    },

    "helperFee": {
      "monto": 5000,
      "exento_comision": true,
      "descripcion": "Add-on ayudante/peón — 100% para el chofer"
    },

    "baseParaComision": 26400,
    "comisionPorcentaje": 15,
    "comisionMonto": 3960,

    "totalCliente": 36400,
    "gananciaChoferOEmpresa": 22440
  },

  "pagoInfo": {
    "metodoPago": "cuenta_corriente",
    "estado": "pendiente_facturacion",
    "facturaId": null,
    "procesadoAt": null
  },

  "asignacion": {
    "driverId": "drv_rferreyra_001",
    "userId": "usr_chofer_empleado_001",
    "displayName": "Rodrigo Alejandro Ferreyra",
    "vehicleId": "veh_sprinter_001",
    "patente": "AB512CD",
    "employerCompanyId": "cmp_transandina_carrier",
    "pagoDestinatario": "company"
  },

  "calificaciones": {
    "clienteAChofer": {
      "score": 5,
      "comentario": "Muy cuidadoso con la mercadería.",
      "at": "2025-06-29T14:50:00Z"
    },
    "choferACliente": {
      "score": 5,
      "comentario": "Sin problemas.",
      "at": "2025-06-29T14:52:10Z"
    }
  },

  "createdAt": "2025-06-29T13:00:00Z",
  "completedAt": "2025-06-29T14:35:22Z"
}
```

---

### `/config/{configId}`

```json
// config/tarifas_flete_mini
{
  "configId": "tarifas_flete_mini",
  "categoria": "mini",
  "label": "Flete Mini",
  "descripcion": "Partner, Berlingo, Fiorino",
  "pricing": {
    "base": 1800,
    "precioPorKm": 350,
    "precioPorMinuto": 90
  },
  "esperaGratisMinutos": 15,
  "costoEsperaPorMinutoARS": 60,
  "updatedAt": "2025-06-01T00:00:00Z",
  "updatedBy": "usr_admin_fretix_000"
}

// config/tarifas_flete_plus
{
  "configId": "tarifas_flete_plus",
  "categoria": "plus",
  "label": "Flete Plus",
  "descripcion": "Hilux, Amarok, Ranger",
  "pricing": {
    "base": 2800,
    "precioPorKm": 450,
    "precioPorMinuto": 120
  },
  "esperaGratisMinutos": 15,
  "costoEsperaPorMinutoARS": 80,
  "updatedAt": "2025-06-01T00:00:00Z",
  "updatedBy": "usr_admin_fretix_000"
}

// config/tarifas_flete_max
{
  "configId": "tarifas_flete_max",
  "categoria": "max",
  "label": "Flete Max",
  "descripcion": "Sprinter, Transit",
  "pricing": {
    "base": 6500,
    "precioPorKm": 700,
    "precioPorMinuto": 180
  },
  "esperaGratisMinutos": 15,
  "costoEsperaPorMinutoARS": 180,
  "updatedAt": "2025-06-01T00:00:00Z",
  "updatedBy": "usr_admin_fretix_000"
}

// config/tarifas_carga_pesada
{
  "configId": "tarifas_carga_pesada",
  "categoria": "heavy",
  "label": "Carga Pesada",
  "descripcion": "Ford Cargo, Mercedes Accelo",
  "pricing": {
    "base": 15000,
    "precioPorKm": 1200,
    "precioPorMinuto": 250
  },
  "esperaGratisMinutos": 20,
  "costoEsperaPorMinutoARS": 300,
  "updatedAt": "2025-06-01T00:00:00Z",
  "updatedBy": "usr_admin_fretix_000"
}

// config/global_plataforma
{
  "configId": "global_plataforma",
  "comisionPorcentaje": 15,
  "helperFee": {
    "montoARS": 5000,
    "exento_comision": true,
    "descripcion": "Add-on ayudante/peón — va 100% al chofer"
  },
  "radioMatcheoKm": 5,
  "tiempoLimiteAceptacionSeg": 45,
  "updatedAt": "2025-06-01T00:00:00Z",
  "updatedBy": "usr_admin_fretix_000"
}
```

---

## 6. MAPA DE IDs CRUZADOS (Escenario Completo)

```
usr_sub_empleado_004  (Lucas Pérez — empleado de Zuccardi)
    │
    └── company_members/mbr_lperez_zuccardi
            └── companyId: cmp_zuccardi_cliente
                    │
                    ▼
            trips/trp_20250629_001
            solicitadoPor.companyId: cmp_zuccardi_cliente
                    │
                    ▼
            asignacion.driverId: drv_rferreyra_001
                    │
                    ├── userId: usr_chofer_empleado_001
                    ├── vehicleId: veh_sprinter_001
                    └── employerCompanyId: cmp_transandina_carrier
                                │
                                ▼
                    pagoDestinatario: "company"
                    → El pago va a TransAndina, no al chofer
```

---

## 7. REGLAS DE NEGOCIO CRÍTICAS PARA CLOUD FUNCTIONS

| Regla | Campo gatillo | Lógica |
|---|---|---|
| Visibilidad de ganancias | `drivers.tipo` | Si `"empleado"` → ocultar montos al chofer en la app |
| Destino del pago | `drivers.employerCompanyId` | Si `null` → pago al chofer; si tiene valor → pago a la empresa |
| Exención de comisión | `pricing.helperFee.exento_comision` | Si `true` → excluir `helperFee.monto` de `baseParaComision` antes de aplicar 15% |
| Sub-usuario empresa | `trips.solicitadoPor.companyId` | Si existe → el viaje se agrupa bajo esa empresa para facturación consolidada |
| Matcheo geográfico | `drivers.lastLocation` (GeoPoint) | Query Firestore geo dentro de radio 5km + `estadoServicio == "online"` |
| Documentación vencida | `drivers.documentacionChofer.*_vencimiento` | Cloud Function diaria verifica vencimientos y desactiva el chofer si corresponde |

---

## 8. ESTADOS DEL VIAJE (`trips.estado`)

```
quoting → confirmed → assigned → in_progress → completed
                                              ↘ cancelled
```

| Estado | Descripción |
|---|---|
| `quoting` | Cliente recibe cotización, aún no confirmó |
| `confirmed` | Cliente confirmó, sistema busca chofer disponible |
| `assigned` | Chofer aceptó, en camino al origen |
| `in_progress` | Carga iniciada, en tránsito al destino |
| `completed` | Entregado y confirmado |
| `cancelled` | Cancelado por cliente o chofer |

---

*Documento generado como referencia de arquitectura para el desarrollo de FRETIX.*  
*Para uso interno del equipo de desarrollo — no contiene datos reales.*
