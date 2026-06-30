# FRETIX — Módulo 6: Panel Web Corporativo, Calificaciones y Cierre
**Versión:** 1.0 | **Fecha:** 2025-06-29
**Módulos anteriores:** [Arquitectura Firestore](./FRETIX_Arquitectura_Firestore.md) · [Auth](./FRETIX_Modulo2_Auth_Onboarding.md) · [Tarifas](./FRETIX_Modulo3_Tarifas_Mapas.md) · [Matcheo](./FRETIX_Modulo4_Flujo_Matcheo.md) · [UI Móvil](./FRETIX_Modulo5_UI_Flutter.md)
**Stack:** Flutter Web · Cloud Functions Node.js v2 · Firestore · fl_chart

> **Este documento cierra el plano de ingeniería completo de Fretix.**
> Cubre el flujo de cierre de viaje (calificaciones), el portal corporativo para
> clientes empresa y el portal para empresas de transporte.

---

## 1. OBJETIVO DEL MÓDULO

Completar el ciclo completo del viaje con la pantalla de calificación bidireccional,
y construir los dos portales web B2B que habilitan la gestión corporativa de Fretix:
cuenta corriente, sub-usuarios, flota propia y liquidaciones quincenales.

---

## 2. ARQUITECTURA GENERAL DEL PANEL WEB

```
Flutter Web — Responsive Layout Strategy
─────────────────────────────────────────
  < 600px   → Mobile (misma app móvil, no panel corporativo)
  600–1024px → Tablet (panel simplificado)
  > 1024px  → Desktop (panel corporativo completo)

Detección:
  LayoutBuilder + MediaQuery.of(context).size.width
  En el panel web, siempre asumimos > 1024px (portal B2B de escritorio).
```

### Estructura de rutas del panel web

```
/web/login                 → Acceso corporativo (email + contraseña o mismo OTP)
/web/cliente/dashboard     → KPIs y saldo de cuenta corriente
/web/cliente/usuarios      → ABM de sub-usuarios
/web/cliente/historial     → Tabla de viajes y facturación
/web/transporte/dashboard  → Resumen de operaciones y ganancias
/web/transporte/flota      → Gestión de vehículos
/web/transporte/choferes   → Gestión de choferes empleados
/web/transporte/liquidaciones → Historial de pagos quincenales
/web/admin/tarifas         → Editor de tarifas (solo rol admin)
/web/admin/usuarios        → Gestión global de usuarios (solo rol admin)
```

---

## 3. CLOUD FUNCTION — `registrarCalificacionFretix`

### Archivo
`functions/src/calificaciones.js`

### Lógica
Calificación **bidireccional**: cliente califica al chofer y el chofer califica al cliente.
Cada parte puede calificar una sola vez por viaje. El promedio se recalcula de forma
transaccional con la fórmula de promedio incremental para no releer todos los viajes.

**Fórmula de promedio incremental (O(1), sin releer historial):**
```
nuevoPromedio = ((promedioActual × totalCalificaciones) + nuevaCalificacion)
                / (totalCalificaciones + 1)
```

```javascript
// functions/src/calificaciones.js

const { onCall, HttpsError }        = require('firebase-functions/v2/https');
const { getFirestore, FieldValue }  = require('firebase-admin/firestore');

const db = getFirestore();

exports.registrarCalificacionFretix = onCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'No autenticado.');

    const { tripId, score, comentario } = request.data;
    const uid = request.auth.uid;

    // Validaciones
    if (!tripId) throw new HttpsError('invalid-argument', 'tripId requerido.');
    if (typeof score !== 'number' || score < 1 || score > 5 || !Number.isInteger(score)) {
      throw new HttpsError('invalid-argument', 'score debe ser un entero entre 1 y 5.');
    }

    const tripRef  = db.collection('trips').doc(tripId);
    const tripSnap = await tripRef.get();

    if (!tripSnap.exists) throw new HttpsError('not-found', 'Viaje no encontrado.');
    const trip = tripSnap.data();

    if (trip.estado !== 'completed') {
      throw new HttpsError('failed-precondition', 'Solo se puede calificar un viaje completado.');
    }

    // Determinar quién califica a quién
    const esCliente = trip.solicitadoPor?.userId === uid;
    const esChofer  = trip.asignacion?.userId    === uid;

    if (!esCliente && !esChofer) {
      throw new HttpsError('permission-denied', 'No participaste en este viaje.');
    }

    // Claves del campo en el documento del viaje
    const campoCalificacion = esCliente ? 'calificaciones.clienteAChofer' : 'calificaciones.choferACliente';
    const campoYaCalificado = esCliente ? 'calificaciones.clienteAChofer' : 'calificaciones.choferACliente';

    // Verificar idempotencia: no permitir doble calificación
    if (trip.calificaciones?.[esCliente ? 'clienteAChofer' : 'choferACliente']?.score) {
      return { success: true, alreadyRated: true };
    }

    await db.runTransaction(async (tx) => {
      // Escribir la calificación en el viaje
      tx.update(tripRef, {
        [`${campoCalificacion}.score`]:      score,
        [`${campoCalificacion}.comentario`]: comentario?.trim() ?? null,
        [`${campoCalificacion}.at`]:         new Date().toISOString(),
      });

      // Si el cliente califica → actualizar stats del chofer
      if (esCliente) {
        const driverId   = trip.asignacion?.driverId;
        if (!driverId) return;

        const driverRef  = db.collection('drivers').doc(driverId);
        const driverSnap = await tx.get(driverRef);
        if (!driverSnap.exists) return;

        const driverData  = driverSnap.data();
        const totalActual = driverData.stats?.totalCalificaciones ?? 0;
        const promedioAct = driverData.stats?.calificacionPromedio ?? 0;

        const nuevoTotal   = totalActual + 1;
        const nuevoPromedio = parseFloat(
          (((promedioAct * totalActual) + score) / nuevoTotal).toFixed(2)
        );

        tx.update(driverRef, {
          'stats.calificacionPromedio':  nuevoPromedio,
          'stats.totalCalificaciones':   nuevoTotal,
        });
      }

      // Si el chofer califica → actualizar stats del usuario cliente
      if (esChofer) {
        const clienteUserId = trip.solicitadoPor?.userId;
        if (!clienteUserId) return;

        const userRef  = db.collection('users').doc(clienteUserId);
        const userSnap = await tx.get(userRef);
        if (!userSnap.exists) return;

        const userData     = userSnap.data();
        const totalActual  = userData.stats?.totalCalificaciones ?? 0;
        const promedioAct  = userData.stats?.calificacionPromedio  ?? 0;

        const nuevoTotal    = totalActual + 1;
        const nuevoPromedio = parseFloat(
          (((promedioAct * totalActual) + score) / nuevoTotal).toFixed(2)
        );

        tx.update(userRef, {
          'stats.calificacionPromedio': nuevoPromedio,
          'stats.totalCalificaciones':  nuevoTotal,
        });
      }
    });

    return { success: true, score, tripId };
  }
);
```

---

## 4. PANTALLA DE CALIFICACIÓN — `RatingScreen` (Flutter Mobile)

### Archivo
`lib/screens/shared/rating_screen.dart`

### Argumentos de navegación
```dart
// Pasados como Map desde TripControlScreen y TripTrackingScreen:
{
  'tripId':           'trp_20250629_001',
  'rol':              'cliente' | 'chofer',
  'totalFinal':       36400,          // solo cuando viene de finalizarViaje (chofer)
  'costoEsperaExtra': 1260,           // idem
}
```

```dart
// lib/screens/shared/rating_screen.dart

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../../theme/fretix_colors.dart';

class RatingScreen extends StatefulWidget {
  final Map args;
  const RatingScreen({super.key, required this.args});

  @override
  State<RatingScreen> createState() => _RatingScreenState();
}

class _RatingScreenState extends State<RatingScreen>
    with SingleTickerProviderStateMixin {
  int    _score     = 0;       // 0 = sin seleccionar
  bool   _enviando  = false;
  bool   _enviado   = false;
  final  _comentarioCtrl = TextEditingController();

  late final AnimationController _successCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final Animation<double> _successScale = CurvedAnimation(
    parent: _successCtrl, curve: Curves.elasticOut,
  );

  @override
  void dispose() {
    _comentarioCtrl.dispose();
    _successCtrl.dispose();
    super.dispose();
  }

  String get _tripId => widget.args['tripId'] as String;
  String get _rol    => widget.args['rol']    as String;

  bool get _esChofer => _rol == 'chofer';

  Future<void> _enviarCalificacion() async {
    if (_score == 0 || _enviando) return;
    setState(() => _enviando = true);

    try {
      final callable = FirebaseFunctions
          .instanceFor(region: 'us-central1')
          .httpsCallable('registrarCalificacionFretix');

      await callable.call({
        'tripId':     _tripId,
        'score':      _score,
        'comentario': _comentarioCtrl.text.trim().isEmpty
            ? null
            : _comentarioCtrl.text.trim(),
      });

      setState(() { _enviado = true; _enviando = false; });
      _successCtrl.forward();

      // Navegar al home después de 2 segundos
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);

    } catch (e) {
      if (!mounted) return;
      setState(() => _enviando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al enviar: $e'),
            backgroundColor: FretixColors.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalFinal     = widget.args['totalFinal']     as num?;
    final costoEsperaExtra = widget.args['costoEsperaExtra'] as num?;

    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: _enviado ? _buildExito() : _buildFormulario(totalFinal, costoEsperaExtra),
      ),
    );
  }

  // ── Vista de éxito ───────────────────────────────────────────────────────
  Widget _buildExito() {
    return Center(
      child: ScaleTransition(
        scale: _successScale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100, height: 100,
              decoration: const BoxDecoration(
                color:  FretixColors.success,
                shape:  BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 56),
            ),
            const SizedBox(height: 24),
            const Text('¡Gracias por tu calificación!',
                style: TextStyle(
                  color: FretixColors.textPrimary,
                  fontSize: 22, fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 8),
            const Text('Ayudás a mejorar la comunidad Fretix.',
                style: TextStyle(color: FretixColors.textSecondary, fontSize: 15)),
          ],
        ),
      ),
    );
  }

  // ── Formulario de calificación ───────────────────────────────────────────
  Widget _buildFormulario(num? totalFinal, num? costoEsperaExtra) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.local_shipping_rounded,
                  color: FretixColors.accent, size: 28),
              const SizedBox(width: 12),
              const Text('Viaje completado',
                  style: TextStyle(
                    color: FretixColors.textPrimary,
                    fontSize: 20, fontWeight: FontWeight.w700,
                  )),
            ],
          ),
          const SizedBox(height: 24),

          // Resumen financiero (solo chofer independiente o cliente)
          if (totalFinal != null) _buildResumenFinanciero(totalFinal, costoEsperaExtra),
          const SizedBox(height: 28),

          // Pregunta de calificación
          Text(
            _esChofer
                ? '¿Cómo fue el cliente?'
                : '¿Cómo calificás al chofer?',
            style: const TextStyle(
              color: FretixColors.textPrimary,
              fontSize: 18, fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _esChofer
                ? 'Tu opinión ayuda a mantener la calidad del servicio.'
                : 'Tu opinión ayuda a los mejores choferes a destacarse.',
            style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 24),

          // Estrellas interactivas
          _SelectorEstrellas(
            score:    _score,
            onChange: (v) => setState(() => _score = v),
          ),
          const SizedBox(height: 24),

          // Comentario opcional
          TextField(
            controller:  _comentarioCtrl,
            maxLines:    3,
            maxLength:   200,
            style: const TextStyle(color: FretixColors.textPrimary),
            decoration: InputDecoration(
              labelText:    'Comentario (opcional)',
              labelStyle:   const TextStyle(color: FretixColors.textSecondary),
              hintText:     'Contanos cómo fue la experiencia...',
              hintStyle:    const TextStyle(color: FretixColors.textMuted, fontSize: 13),
              filled:       true,
              fillColor:    FretixColors.surface,
              counterStyle: const TextStyle(color: FretixColors.textMuted),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: FretixColors.surfaceBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: FretixColors.surfaceBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: FretixColors.accent, width: 1.5),
              ),
            ),
          ),

          const Spacer(),

          // Botón enviar
          SizedBox(
            width: double.infinity, height: 56,
            child: ElevatedButton(
              onPressed: _score == 0 || _enviando ? null : _enviarCalificacion,
              style: ElevatedButton.styleFrom(
                backgroundColor:         FretixColors.accent,
                foregroundColor:         Colors.black,
                disabledBackgroundColor: FretixColors.surfaceBorder,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _enviando
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.black, strokeWidth: 2.5))
                  : Text(
                      _score == 0 ? 'Seleccioná una calificación' : 'Enviar calificación',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
            ),
          ),

          // Saltar calificación
          Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false),
              child: const Text('Saltar por ahora',
                  style: TextStyle(color: FretixColors.textMuted, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResumenFinanciero(num totalFinal, num? costoEsperaExtra) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _esChofer ? 'Ganaste en este viaje' : 'Total del viaje',
                style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13),
              ),
              Text(
                '\$${_formatPeso(totalFinal.toDouble())}',
                style: const TextStyle(
                  color: FretixColors.accent,
                  fontSize: 22, fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (costoEsperaExtra != null && costoEsperaExtra > 0) ...[
            const SizedBox(height: 8),
            const Divider(color: FretixColors.surfaceBorder, height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Espera extra facturada',
                    style: TextStyle(color: FretixColors.textMuted, fontSize: 12)),
                Text('\$${_formatPeso(costoEsperaExtra.toDouble())}',
                    style: const TextStyle(color: FretixColors.textMuted, fontSize: 12)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatPeso(double v) =>
      v.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.');
}

// ── Selector de estrellas interactivo ────────────────────────────────────────

class _SelectorEstrellas extends StatelessWidget {
  final int score;
  final void Function(int) onChange;

  const _SelectorEstrellas({required this.score, required this.onChange});

  static const _labels = ['', 'Muy malo', 'Malo', 'Regular', 'Bueno', '¡Excelente!'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (i) {
            final estrella = i + 1;
            final activa   = estrella <= score;
            return GestureDetector(
              onTap: () => onChange(estrella),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  activa ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: activa ? FretixColors.accent : FretixColors.surfaceBorder,
                  size:  40,
                ),
              ),
            );
          }),
        ),
        if (score > 0) ...[
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              _labels[score],
              key:   ValueKey(score),
              style: const TextStyle(
                color:      FretixColors.accent,
                fontSize:   14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
```

---

## 5. PANEL WEB — ESTRUCTURA COMPARTIDA (Scaffold)

```dart
// lib/screens/web/shared/web_scaffold.dart
// Shell de navegación lateral compartido por todos los paneles web.

import 'package:flutter/material.dart';
import '../../../theme/fretix_colors.dart';

class WebScaffold extends StatelessWidget {
  final String         titulo;
  final Widget         body;
  final List<_NavItem> navItems;
  final int            indexActivo;
  final void Function(int) onNavTap;

  const WebScaffold({
    super.key,
    required this.titulo,
    required this.body,
    required this.navItems,
    required this.indexActivo,
    required this.onNavTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      body: Row(
        children: [
          // ── Sidebar de navegación (240px fijo) ────────────────────────────
          Container(
            width:   240,
            color:   FretixColors.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Logo
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
                  child: Image.asset('assets/images/logo_fretix_white.png', height: 32),
                ),
                // Items de nav
                ...navItems.asMap().entries.map((e) => _NavTile(
                  item:   e.value,
                  activo: e.key == indexActivo,
                  onTap:  () => onNavTap(e.key),
                )),
                const Spacer(),
                // Versión
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Fretix v1.0 · Mendoza',
                      style: const TextStyle(
                          color: FretixColors.textMuted, fontSize: 11)),
                ),
              ],
            ),
          ),
          // ── Área de contenido ──────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Topbar
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: FretixColors.surfaceBorder),
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(titulo,
                        style: const TextStyle(
                          color: FretixColors.textPrimary,
                          fontSize: 18, fontWeight: FontWeight.w700,
                        )),
                  ),
                ),
                // Body scrollable
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(32),
                    child: body,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String   label;
  final String   route;
  const _NavItem({required this.icon, required this.label, required this.route});
}

class _NavTile extends StatelessWidget {
  final _NavItem item;
  final bool     activo;
  final VoidCallback onTap;
  const _NavTile({required this.item, required this.activo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color:        activo ? FretixColors.accent.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(item.icon,
                color: activo ? FretixColors.accent : FretixColors.textSecondary,
                size:  20),
            const SizedBox(width: 12),
            Text(item.label,
                style: TextStyle(
                  color:      activo ? FretixColors.accent : FretixColors.textSecondary,
                  fontSize:   14,
                  fontWeight: activo ? FontWeight.w600 : FontWeight.w400,
                )),
          ],
        ),
      ),
    );
  }
}
```

---

## 6. PANEL WEB — VISTA CLIENTE EMPRESA

### 6.1 Pantalla raíz del portal cliente

```dart
// lib/screens/web/cliente/portal_cliente_screen.dart

import 'package:flutter/material.dart';
import '../shared/web_scaffold.dart';
import 'tabs/dashboard_cliente_tab.dart';
import 'tabs/usuarios_tab.dart';
import 'tabs/historial_tab.dart';

class PortalClienteScreen extends StatefulWidget {
  final String companyId;
  const PortalClienteScreen({super.key, required this.companyId});

  @override
  State<PortalClienteScreen> createState() => _PortalClienteScreenState();
}

class _PortalClienteScreenState extends State<PortalClienteScreen> {
  int _tabIndex = 0;

  static const _navItems = [
    _NavItem(icon: Icons.dashboard_rounded,    label: 'Dashboard',    route: ''),
    _NavItem(icon: Icons.group_rounded,        label: 'Sub-usuarios', route: ''),
    _NavItem(icon: Icons.receipt_long_rounded, label: 'Historial',    route: ''),
  ];

  final _tabs = <Widget Function(String companyId)>[
    (id) => DashboardClienteTab(companyId: id),
    (id) => UsuariosTab(companyId: id),
    (id) => HistorialTab(companyId: id),
  ];

  static const _titulos = ['Dashboard', 'Sub-usuarios autorizados', 'Historial y Facturación'];

  @override
  Widget build(BuildContext context) {
    return WebScaffold(
      titulo:      _titulos[_tabIndex],
      navItems:    _navItems,
      indexActivo: _tabIndex,
      onNavTap:    (i) => setState(() => _tabIndex = i),
      body:        _tabs[_tabIndex](widget.companyId),
    );
  }
}
```

---

### 6.2 `DashboardClienteTab` — KPIs de Cuenta Corriente

```dart
// lib/screens/web/cliente/tabs/dashboard_cliente_tab.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../../theme/fretix_colors.dart';

class DashboardClienteTab extends StatelessWidget {
  final String companyId;
  const DashboardClienteTab({super.key, required this.companyId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('companies')
          .doc(companyId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: FretixColors.accent));
        }

        final company  = snap.data!.data() ?? {};
        final cc       = company['cuentaCorriente'] as Map<String, dynamic>? ?? {};
        final saldo    = (cc['saldoActualARS']   as num?)?.toDouble() ?? 0;
        final limite   = (cc['limiteCreditoARS'] as num?)?.toDouble() ?? 1;
        final dias     = cc['diasCredito'] as int? ?? 15;
        final vence    = cc['proximoVencimiento'] as String?;

        // El saldo es negativo cuando el cliente debe plata (consumió crédito)
        final consumido     = saldo.abs();
        final disponible    = (limite - consumido).clamp(0, limite);
        final porcentajeUso = (consumido / limite).clamp(0.0, 1.0);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Fila de KPI Cards ───────────────────────────────────────────
            Wrap(
              spacing: 16, runSpacing: 16,
              children: [
                _KpiCard(
                  titulo:    'Crédito disponible',
                  valor:     '\$${_fmt(disponible)}',
                  subtitulo: 'de \$${_fmt(limite)} de límite',
                  color:     disponible > limite * 0.3
                      ? FretixColors.success
                      : FretixColors.danger,
                  icon:      Icons.account_balance_wallet_rounded,
                ),
                _KpiCard(
                  titulo:    'Consumido en el período',
                  valor:     '\$${_fmt(consumido)}',
                  subtitulo: 'Crédito a $dias días',
                  color:     FretixColors.accent,
                  icon:      Icons.trending_up_rounded,
                ),
                _KpiCard(
                  titulo:    'Próximo vencimiento',
                  valor:     vence != null
                      ? _formatFecha(vence)
                      : 'Sin deuda',
                  subtitulo: vence != null ? 'Factura A pendiente' : '—',
                  color:     FretixColors.textSecondary,
                  icon:      Icons.calendar_today_rounded,
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ── Barra de consumo del crédito ────────────────────────────────
            _WebCard(
              titulo: 'Uso del crédito',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('\$${_fmt(consumido)} consumidos',
                          style: const TextStyle(
                              color: FretixColors.textPrimary, fontWeight: FontWeight.w600)),
                      Text('${(porcentajeUso * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(color: FretixColors.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value:            porcentajeUso,
                      minHeight:        10,
                      backgroundColor:  FretixColors.surfaceBorder,
                      valueColor: AlwaysStoppedAnimation(
                        porcentajeUso > 0.8 ? FretixColors.danger : FretixColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Límite de crédito: \$${_fmt(limite)}',
                    style: const TextStyle(color: FretixColors.textMuted, fontSize: 12),
                  ),
                  if (porcentajeUso > 0.8) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color:        FretixColors.danger.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border:       Border.all(color: FretixColors.danger.withOpacity(0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: FretixColors.danger, size: 16),
                          SizedBox(width: 8),
                          Text('Crédito al límite. Contactá a Fretix para ampliarlo.',
                              style: TextStyle(color: FretixColors.danger, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Últimos 5 viajes en tiempo real ─────────────────────────────
            _UltimosViajesPreview(companyId: companyId),
          ],
        );
      },
    );
  }

  static String _fmt(double v) =>
      v.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.');

  static String _formatFecha(String iso) {
    try {
      final d = DateTime.parse(iso);
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) { return iso; }
  }
}

class _UltimosViajesPreview extends StatelessWidget {
  final String companyId;
  const _UltimosViajesPreview({required this.companyId});

  @override
  Widget build(BuildContext context) {
    return _WebCard(
      titulo: 'Últimos viajes',
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .where('solicitadoPor.companyId', isEqualTo: companyId)
            .where('estado', isEqualTo: 'completed')
            .orderBy('completedAt', descending: true)
            .limit(5)
            .snapshots(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const LinearProgressIndicator();
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Text('Sin viajes registrados.',
                style: TextStyle(color: FretixColors.textSecondary));
          }
          return Column(
            children: docs.map((d) => _FilaViajePreview(trip: d.data())).toList(),
          );
        },
      ),
    );
  }
}

class _FilaViajePreview extends StatelessWidget {
  final Map<String, dynamic> trip;
  const _FilaViajePreview({required this.trip});

  @override
  Widget build(BuildContext context) {
    final ruta     = trip['ruta']    as Map<String, dynamic>? ?? {};
    final pricing  = trip['pricing'] as Map<String, dynamic>? ?? {};
    final total    = (pricing['totalFinal'] ?? pricing['totalCliente'] ?? 0) as num;
    final destino  = ruta['destino']?['direccion'] as String? ?? '—';
    final fecha    = trip['completedAt'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.local_shipping_rounded,
              color: FretixColors.textMuted, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(destino,
                style: const TextStyle(color: FretixColors.textPrimary, fontSize: 13),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 16),
          Text('\$${total.toStringAsFixed(0)}',
              style: const TextStyle(
                  color: FretixColors.accent, fontWeight: FontWeight.w600)),
          const SizedBox(width: 16),
          Text(fecha.length >= 10 ? fecha.substring(0, 10) : '',
              style: const TextStyle(color: FretixColors.textMuted, fontSize: 12)),
        ],
      ),
    );
  }
}
```

---

### 6.3 `UsuariosTab` — ABM de Sub-usuarios

```dart
// lib/screens/web/cliente/tabs/usuarios_tab.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../../../../theme/fretix_colors.dart';

class UsuariosTab extends StatefulWidget {
  final String companyId;
  const UsuariosTab({super.key, required this.companyId});

  @override
  State<UsuariosTab> createState() => _UsuariosTabState();
}

class _UsuariosTabState extends State<UsuariosTab> {
  bool _mostrandoFormulario = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Botón agregar ────────────────────────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Empleados con acceso a Fretix',
                style: TextStyle(color: FretixColors.textSecondary, fontSize: 14)),
            ElevatedButton.icon(
              onPressed: () => setState(() => _mostrandoFormulario = true),
              style: ElevatedButton.styleFrom(
                backgroundColor: FretixColors.accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon:  const Icon(Icons.add_rounded, size: 18),
              label: const Text('Agregar empleado',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ── Formulario inline de nuevo sub-usuario ───────────────────────────
        if (_mostrandoFormulario) ...[
          _FormularioNuevoUsuario(
            companyId: widget.companyId,
            onClose:   () => setState(() => _mostrandoFormulario = false),
          ),
          const SizedBox(height: 20),
        ],

        // ── Tabla de sub-usuarios ────────────────────────────────────────────
        _TablaUsuarios(companyId: widget.companyId),
      ],
    );
  }
}

class _FormularioNuevoUsuario extends StatefulWidget {
  final String companyId;
  final VoidCallback onClose;
  const _FormularioNuevoUsuario({required this.companyId, required this.onClose});

  @override
  State<_FormularioNuevoUsuario> createState() => _FormularioNuevoUsuarioState();
}

class _FormularioNuevoUsuarioState extends State<_FormularioNuevoUsuario> {
  final _formKey    = GlobalKey<FormState>();
  final _phoneCtrl  = TextEditingController();
  final _nombreCtrl = TextEditingController();
  final _limiteCtrl = TextEditingController();
  bool  _guardando  = false;

  @override
  void dispose() {
    _phoneCtrl.dispose(); _nombreCtrl.dispose(); _limiteCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _guardando = true);

    try {
      // Llama a la Cloud Function que crea el /company_members y envía invitación
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('invitarSubUsuarioFretix')
          .call({
        'companyId':             widget.companyId,
        'phone':                 _phoneCtrl.text.trim(),
        'displayName':           _nombreCtrl.text.trim(),
        'limiteGastoMensualARS': int.tryParse(_limiteCtrl.text) ?? 0,
      });

      widget.onClose();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: FretixColors.danger),
      );
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _WebCard(
      titulo: 'Nuevo sub-usuario',
      child: Form(
        key: _formKey,
        child: Wrap(
          spacing: 16, runSpacing: 16,
          children: [
            SizedBox(
              width: 260,
              child: _WebField(ctrl: _nombreCtrl, label: 'Nombre completo',
                  validator: (v) => (v?.trim().isEmpty ?? true) ? 'Requerido' : null),
            ),
            SizedBox(
              width: 200,
              child: _WebField(
                ctrl:      _phoneCtrl,
                label:     'Teléfono (+54261...)',
                inputType: TextInputType.phone,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Requerido';
                  if (!v.startsWith('+54')) return 'Incluí el código de país +54';
                  return null;
                },
              ),
            ),
            SizedBox(
              width: 200,
              child: _WebField(
                ctrl:      _limiteCtrl,
                label:     'Límite mensual (ARS)',
                inputType: TextInputType.number,
                validator: (v) => null,   // Opcional
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: _guardando ? null : _guardar,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FretixColors.accent,
                    foregroundColor: Colors.black,
                  ),
                  child: _guardando
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                      : const Text('Guardar', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: widget.onClose,
                  child: const Text('Cancelar',
                      style: TextStyle(color: FretixColors.textSecondary)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TablaUsuarios extends StatelessWidget {
  final String companyId;
  const _TablaUsuarios({required this.companyId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('company_members')
          .where('companyId', isEqualTo: companyId)
          .where('role',      isEqualTo: 'sub_user')
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const LinearProgressIndicator();
        final docs = snap.data!.docs;

        return _WebCard(
          titulo: '${docs.length} empleados autorizados',
          child: docs.isEmpty
              ? const Text('Sin sub-usuarios registrados.',
                  style: TextStyle(color: FretixColors.textSecondary))
              : Table(
                  columnWidths: const {
                    0: FlexColumnWidth(3),
                    1: FlexColumnWidth(2),
                    2: FlexColumnWidth(2),
                    3: FlexColumnWidth(1),
                  },
                  children: [
                    // Header
                    TableRow(
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: FretixColors.surfaceBorder),
                        ),
                      ),
                      children: ['Empleado', 'Teléfono', 'Límite mensual', 'Estado']
                          .map((h) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(h,
                                    style: const TextStyle(
                                      color: FretixColors.textMuted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                    )),
                              ))
                          .toList(),
                    ),
                    // Filas de datos
                    ...docs.map((d) => _filaUsuario(d.id, d.data())),
                  ],
                ),
        );
      },
    );
  }

  TableRow _filaUsuario(String membershipId, Map<String, dynamic> member) {
    final limite  = member['limiteGastoMensualARS'] as num?;
    final activo  = member['isActive'] as bool? ?? true;

    return TableRow(
      children: [
        _CeldaTabla(child: FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users').doc(member['userId']).get(),
          builder: (_, snap) {
            final nombre = (snap.data?.data() as Map?)
                ?['displayName'] as String? ?? '—';
            return Text(nombre,
                style: const TextStyle(color: FretixColors.textPrimary, fontSize: 13));
          },
        )),
        _CeldaTabla(child: FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users').doc(member['userId']).get(),
          builder: (_, snap) {
            final phone = (snap.data?.data() as Map?)?['phone'] as String? ?? '—';
            return Text(phone,
                style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13));
          },
        )),
        _CeldaTabla(child: Text(
          limite != null ? '\$${limite.toStringAsFixed(0)}' : 'Sin límite',
          style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13),
        )),
        _CeldaTabla(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color:        (activo ? FretixColors.success : FretixColors.danger)
                .withOpacity(0.15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            activo ? 'Activo' : 'Inactivo',
            style: TextStyle(
              color:      activo ? FretixColors.success : FretixColors.danger,
              fontSize:   11,
              fontWeight: FontWeight.w600,
            ),
          ),
        )),
      ],
    );
  }
}

class _CeldaTabla extends StatelessWidget {
  final Widget child;
  const _CeldaTabla({required this.child});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12), child: child);
}
```

---

### 6.4 `HistorialTab` — Viajes y Facturación

```dart
// lib/screens/web/cliente/tabs/historial_tab.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../../theme/fretix_colors.dart';

class HistorialTab extends StatefulWidget {
  final String companyId;
  const HistorialTab({super.key, required this.companyId});

  @override
  State<HistorialTab> createState() => _HistorialTabState();
}

class _HistorialTabState extends State<HistorialTab> {
  // Filtro de mes seleccionado (YYYY-MM)
  String _mesSeleccionado = _mesActual();

  static String _mesActual() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Selector de mes ─────────────────────────────────────────────────
        Row(
          children: [
            const Text('Período:',
                style: TextStyle(color: FretixColors.textSecondary, fontSize: 13)),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value:           _mesSeleccionado,
              dropdownColor:   FretixColors.surface,
              style:           const TextStyle(color: FretixColors.textPrimary),
              underline:       const SizedBox.shrink(),
              items:           _ultimos6Meses().map((m) => DropdownMenuItem(
                value: m,
                child: Text(m),
              )).toList(),
              onChanged: (v) => setState(() => _mesSeleccionado = v!),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ── Tabla de viajes del mes ─────────────────────────────────────────
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('trips')
              .where('solicitadoPor.companyId', isEqualTo: widget.companyId)
              .where('estado', isEqualTo: 'completed')
              .orderBy('completedAt', descending: true)
              .limit(100)
              .snapshots(),
          builder: (context, snap) {
            if (!snap.hasData) return const LinearProgressIndicator();

            // Filtrar por mes seleccionado en cliente (Firestore no soporta
            // query por substring de fecha, filtramos en memoria para 100 docs)
            final docs = snap.data!.docs.where((d) {
              final fecha = d.data()['completedAt'] as String? ?? '';
              return fecha.startsWith(_mesSeleccionado);
            }).toList();

            final totalMes = docs.fold<double>(
              0,
              (acc, d) =>
                  acc + ((d.data()['pricing']?['totalFinal']
                          ?? d.data()['pricing']?['totalCliente']
                          ?? 0) as num).toDouble(),
            );

            return _WebCard(
              titulo: '${docs.length} viajes · Total: \$${_fmt(totalMes)}',
              child: Column(
                children: [
                  // Botón descargar CSV (placeholder)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {/* TODO: generar CSV */},
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: FretixColors.surfaceBorder),
                          foregroundColor: FretixColors.textSecondary,
                        ),
                        icon:  const Icon(Icons.download_rounded, size: 16),
                        label: const Text('Descargar Factura A'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  if (docs.isEmpty)
                    const Text('Sin viajes en este período.',
                        style: TextStyle(color: FretixColors.textSecondary))
                  else
                    Table(
                      columnWidths: const {
                        0: FlexColumnWidth(1),
                        1: FlexColumnWidth(3),
                        2: FlexColumnWidth(2),
                        3: FlexColumnWidth(1),
                        4: FlexColumnWidth(1),
                      },
                      children: [
                        // Header
                        TableRow(
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: FretixColors.surfaceBorder),
                            ),
                          ),
                          children: ['Fecha', 'Destino', 'Solicitado por',
                              'Categoría', 'Total']
                              .map((h) => Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Text(h,
                                        style: const TextStyle(
                                          color:      FretixColors.textMuted,
                                          fontSize:   11,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                        )),
                                  ))
                              .toList(),
                        ),
                        ...docs.map((d) => _filaViaje(d.data())),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  TableRow _filaViaje(Map<String, dynamic> trip) {
    final ruta       = trip['ruta']    as Map<String, dynamic>? ?? {};
    final solicitado = trip['solicitadoPor'] as Map<String, dynamic>? ?? {};
    final pricing    = trip['pricing'] as Map<String, dynamic>? ?? {};
    final total      = (pricing['totalFinal'] ?? pricing['totalCliente'] ?? 0) as num;
    final fecha      = trip['completedAt'] as String? ?? '';
    final categoria  = trip['vehiculoCategoria'] as String? ?? '';
    final destino    = ruta['destino']?['direccion'] as String? ?? '—';

    const celda = TextStyle(color: FretixColors.textPrimary, fontSize: 12);
    const muted = TextStyle(color: FretixColors.textSecondary, fontSize: 12);

    return TableRow(
      children: [
        _CeldaTabla(child: Text(fecha.length >= 10 ? fecha.substring(0, 10) : '', style: muted)),
        _CeldaTabla(child: Text(destino, style: celda, maxLines: 1, overflow: TextOverflow.ellipsis)),
        _CeldaTabla(child: Text(solicitado['displayName'] as String? ?? '—', style: muted)),
        _CeldaTabla(child: _CategoriaChipWeb(categoria: categoria)),
        _CeldaTabla(child: Text('\$${_fmt(total.toDouble())}',
            style: const TextStyle(
                color: FretixColors.accent, fontWeight: FontWeight.w600, fontSize: 12))),
      ],
    );
  }

  static List<String> _ultimos6Meses() {
    final result = <String>[];
    var d = DateTime.now();
    for (int i = 0; i < 6; i++) {
      result.add('${d.year}-${d.month.toString().padLeft(2, '0')}');
      d = DateTime(d.year, d.month - 1);
    }
    return result;
  }

  static String _fmt(double v) =>
      v.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.');
}
```

---

## 7. PANEL WEB — VISTA EMPRESA DE TRANSPORTE

### 7.1 `GestionFlotaTab` — Vehículos y Documentación

```dart
// lib/screens/web/transporte/tabs/gestion_flota_tab.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../../theme/fretix_colors.dart';

class GestionFlotaTab extends StatelessWidget {
  final String companyId;
  const GestionFlotaTab({super.key, required this.companyId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('vehicles')
          .where('owner.companyId', isEqualTo: companyId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const LinearProgressIndicator();
        final docs = snap.data!.docs;

        // Separar vehículos con documentación próxima a vencer (< 30 días)
        final ahora = DateTime.now();
        final criticos = docs.where((d) {
          final venc = d.data()['documentacion']?['rto_vtv_vencimiento'] as String?;
          if (venc == null) return false;
          try {
            final fecha = DateTime.parse(venc);
            return fecha.difference(ahora).inDays < 30;
          } catch (_) { return false; }
        }).length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Alerta de vencimientos
            if (criticos > 0) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color:        FretixColors.danger.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: FretixColors.danger.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: FretixColors.danger, size: 20),
                    const SizedBox(width: 10),
                    Text('$criticos vehículo(s) con RTO/VTV próximo a vencer (< 30 días).',
                        style: const TextStyle(color: FretixColors.danger, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // Botón agregar vehículo
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${docs.length} vehículos registrados',
                    style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13)),
                ElevatedButton.icon(
                  onPressed: () {/* TODO: Modal alta de vehículo */},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FretixColors.accent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon:  const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Agregar vehículo',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Tabla de flota
            _WebCard(
              titulo: 'Flota',
              child: docs.isEmpty
                  ? const Text('Sin vehículos registrados.',
                      style: TextStyle(color: FretixColors.textSecondary))
                  : Table(
                      columnWidths: const {
                        0: FlexColumnWidth(1.5),
                        1: FlexColumnWidth(2),
                        2: FlexColumnWidth(1),
                        3: FlexColumnWidth(1.5),
                        4: FlexColumnWidth(1.5),
                        5: FlexColumnWidth(1),
                      },
                      children: [
                        // Header
                        TableRow(
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: FretixColors.surfaceBorder),
                            ),
                          ),
                          children: [
                            'Patente', 'Modelo', 'Categoría',
                            'RTO/VTV vence', 'Chofer asignado', 'Estado'
                          ].map((h) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(h,
                                    style: const TextStyle(
                                      color:      FretixColors.textMuted,
                                      fontSize:   11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                    )),
                              )).toList(),
                        ),
                        ...docs.map((d) => _filaVehiculo(d.id, d.data())),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  TableRow _filaVehiculo(String vehicleId, Map<String, dynamic> v) {
    final doc       = v['documentacion'] as Map<String, dynamic>? ?? {};
    final rtvVence  = doc['rto_vtv_vencimiento'] as String?;
    final vencido   = _estaVencido(rtvVence);
    final proxVencer = _proximoAVencer(rtvVence);
    final activo    = v['isActive'] as bool? ?? true;

    Color colorRtv = FretixColors.success;
    if (vencido)     colorRtv = FretixColors.danger;
    else if (proxVencer) colorRtv = FretixColors.accent;

    return TableRow(
      children: [
        _CeldaTabla(child: Text(
          (v['patente'] as String? ?? '').toUpperCase(),
          style: const TextStyle(
              color: FretixColors.textPrimary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              fontSize: 12),
        )),
        _CeldaTabla(child: Text(
          '${v['marca'] ?? ''} ${v['modelo'] ?? ''}',
          style: const TextStyle(color: FretixColors.textSecondary, fontSize: 12),
        )),
        _CeldaTabla(child: _CategoriaChipWeb(categoria: v['category'] as String? ?? '')),
        _CeldaTabla(child: Text(
          rtvVence != null ? rtvVence.substring(0, 10) : 'Sin datos',
          style: TextStyle(color: colorRtv, fontSize: 12),
        )),
        // Chofer asignado: query a /drivers donde vehicleIdActivo == vehicleId
        _CeldaTabla(child: _ChoferAsignadoCell(vehicleId: vehicleId, companyId: companyId)),
        _CeldaTabla(child: _BadgeEstado(activo: activo)),
      ],
    );
  }

  static bool _estaVencido(String? fecha) {
    if (fecha == null) return false;
    try { return DateTime.parse(fecha).isBefore(DateTime.now()); }
    catch (_) { return false; }
  }

  static bool _proximoAVencer(String? fecha) {
    if (fecha == null) return false;
    try {
      return DateTime.parse(fecha).difference(DateTime.now()).inDays < 30;
    } catch (_) { return false; }
  }
}

class _ChoferAsignadoCell extends StatelessWidget {
  final String vehicleId;
  final String companyId;
  const _ChoferAsignadoCell({required this.vehicleId, required this.companyId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('drivers')
          .where('vehicleIdActivo', isEqualTo: vehicleId)
          .where('employerCompanyId', isEqualTo: companyId)
          .limit(1)
          .get(),
      builder: (_, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return const Text('Sin asignar',
              style: TextStyle(color: FretixColors.textMuted, fontSize: 12));
        }
        final driverUserId = snap.data!.docs.first.data()['userId'] as String?;
        if (driverUserId == null) return const Text('—',
            style: TextStyle(color: FretixColors.textMuted));

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance.collection('users').doc(driverUserId).get(),
          builder: (_, uSnap) {
            final nombre = uSnap.data?.data()?['displayName'] as String? ?? '—';
            return Text(nombre,
                style: const TextStyle(color: FretixColors.textPrimary, fontSize: 12),
                maxLines: 1, overflow: TextOverflow.ellipsis);
          },
        );
      },
    );
  }
}
```

---

### 7.2 `LiquidacionesTab` — Balance y Pagos Quincenales

```dart
// lib/screens/web/transporte/tabs/liquidaciones_tab.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../../../theme/fretix_colors.dart';

class LiquidacionesTab extends StatelessWidget {
  final String companyId;
  const LiquidacionesTab({super.key, required this.companyId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('companies')
          .doc(companyId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const LinearProgressIndicator();

        final company  = snap.data!.data() ?? {};
        final balance  = (company['balancePendienteARS'] as num?)?.toDouble() ?? 0;
        final historico = (company['totalViajesARS']     as num?)?.toDouble() ?? 0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── KPI Cards de ganancias ───────────────────────────────────────
            Wrap(
              spacing: 16, runSpacing: 16,
              children: [
                _KpiCard(
                  titulo:    'Balance pendiente de cobro',
                  valor:     '\$${_fmt(balance)}',
                  subtitulo: 'Próxima liquidación quincenal',
                  color:     FretixColors.success,
                  icon:      Icons.account_balance_rounded,
                ),
                _KpiCard(
                  titulo:    'Total histórico acumulado',
                  valor:     '\$${_fmt(historico)}',
                  subtitulo: 'Desde el inicio de operaciones',
                  color:     FretixColors.accent,
                  icon:      Icons.stacked_bar_chart_rounded,
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ── Historial de liquidaciones ───────────────────────────────────
            _WebCard(
              titulo: 'Historial de liquidaciones',
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('liquidaciones')
                    .where('companyId', isEqualTo: companyId)
                    .orderBy('fecha', descending: true)
                    .limit(20)
                    .snapshots(),
                builder: (ctx, liqSnap) {
                  if (!liqSnap.hasData) return const LinearProgressIndicator();
                  final docs = liqSnap.data!.docs;

                  if (docs.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(24),
                      child: const Column(
                        children: [
                          Icon(Icons.hourglass_empty_rounded,
                              color: FretixColors.textMuted, size: 40),
                          SizedBox(height: 12),
                          Text('Las liquidaciones quincenales aparecerán aquí\ncuando se procesen.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: FretixColors.textSecondary)),
                        ],
                      ),
                    );
                  }

                  return Table(
                    columnWidths: const {
                      0: FlexColumnWidth(2),
                      1: FlexColumnWidth(2),
                      2: FlexColumnWidth(1.5),
                      3: FlexColumnWidth(1),
                    },
                    children: [
                      TableRow(
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: FretixColors.surfaceBorder),
                          ),
                        ),
                        children: ['Período', 'Viajes incluidos', 'Monto neto', 'Estado']
                            .map((h) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Text(h,
                                      style: const TextStyle(
                                        color:      FretixColors.textMuted,
                                        fontSize:   11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.8,
                                      )),
                                ))
                            .toList(),
                      ),
                      ...docs.map((d) => _filaLiquidacion(d.data())),
                    ],
                  );
                },
              ),
            ),

            const SizedBox(height: 24),

            // ── Viajes del período actual (pendientes de liquidar) ────────────
            _WebCard(
              titulo: 'Viajes en el período actual (pendientes de liquidar)',
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('trips')
                    .where('asignacion.employerCompanyId', isEqualTo: companyId)
                    .where('estado', isEqualTo: 'completed')
                    .orderBy('completedAt', descending: true)
                    .limit(50)
                    .snapshots(),
                builder: (ctx, tripSnap) {
                  if (!tripSnap.hasData) return const LinearProgressIndicator();
                  final docs = tripSnap.data!.docs;

                  final totalPendiente = docs.fold<double>(
                    0,
                    (acc, d) => acc +
                        ((d.data()['pricing']?['gananciaFinal']
                                ?? d.data()['pricing']?['gananciaChoferOEmpresa']
                                ?? 0) as num).toDouble(),
                  );

                  if (docs.isEmpty) {
                    return const Text('Sin viajes completados en este período.',
                        style: TextStyle(color: FretixColors.textSecondary));
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ...docs.take(10).map((d) => _FilaViajeTransporte(trip: d.data())),
                      if (docs.length > 10)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('...y ${docs.length - 10} más.',
                              style: const TextStyle(
                                  color: FretixColors.textMuted, fontSize: 12)),
                        ),
                      const Divider(color: FretixColors.surfaceBorder, height: 24),
                      Text(
                        'Total pendiente: \$${_fmt(totalPendiente)}',
                        style: const TextStyle(
                          color:      FretixColors.success,
                          fontSize:   16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  TableRow _filaLiquidacion(Map<String, dynamic> liq) {
    final pagado  = liq['estado'] == 'pagado';
    return TableRow(
      children: [
        _CeldaTabla(child: Text(liq['periodo'] as String? ?? '—',
            style: const TextStyle(color: FretixColors.textPrimary, fontSize: 12))),
        _CeldaTabla(child: Text('${liq['cantidadViajes'] ?? 0} viajes',
            style: const TextStyle(color: FretixColors.textSecondary, fontSize: 12))),
        _CeldaTabla(child: Text(
          '\$${_fmt((liq['montoNeto'] as num?)?.toDouble() ?? 0)}',
          style: const TextStyle(
              color: FretixColors.success, fontWeight: FontWeight.w600, fontSize: 12),
        )),
        _CeldaTabla(child: _BadgeEstado(activo: pagado, labelActivo: 'Pagado', labelInactivo: 'Pendiente')),
      ],
    );
  }

  static String _fmt(double v) =>
      v.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.');
}

class _FilaViajeTransporte extends StatelessWidget {
  final Map<String, dynamic> trip;
  const _FilaViajeTransporte({required this.trip});

  @override
  Widget build(BuildContext context) {
    final ruta      = trip['ruta']     as Map<String, dynamic>? ?? {};
    final pricing   = trip['pricing']  as Map<String, dynamic>? ?? {};
    final ganancia  = (pricing['gananciaFinal']
                        ?? pricing['gananciaChoferOEmpresa'] ?? 0) as num;
    final destino   = ruta['destino']?['direccion'] as String? ?? '—';
    final fecha     = trip['completedAt'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.local_shipping_rounded,
              color: FretixColors.textMuted, size: 16),
          const SizedBox(width: 10),
          Expanded(child: Text(destino,
              style: const TextStyle(color: FretixColors.textPrimary, fontSize: 12),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text('\$${ganancia.toStringAsFixed(0)}',
              style: const TextStyle(
                  color: FretixColors.success, fontWeight: FontWeight.w600, fontSize: 12)),
          const SizedBox(width: 16),
          Text(fecha.length >= 10 ? fecha.substring(0, 10) : '',
              style: const TextStyle(color: FretixColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}
```

---

## 8. WIDGETS COMPARTIDOS DEL PANEL WEB

```dart
// lib/screens/web/shared/web_widgets.dart

import 'package:flutter/material.dart';
import '../../../theme/fretix_colors.dart';

// ── Card contenedora para secciones del panel ────────────────────────────────

class _WebCard extends StatelessWidget {
  final String  titulo;
  final Widget  child;
  const _WebCard({required this.titulo, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo.toUpperCase(),
              style: const TextStyle(
                color:      FretixColors.textMuted,
                fontSize:   11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

// ── KPI Card ─────────────────────────────────────────────────────────────────

class _KpiCard extends StatelessWidget {
  final String   titulo;
  final String   valor;
  final String   subtitulo;
  final Color    color;
  final IconData icon;
  const _KpiCard({
    required this.titulo,
    required this.valor,
    required this.subtitulo,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   260,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(titulo,
                  style: const TextStyle(
                      color: FretixColors.textSecondary, fontSize: 12))),
            ],
          ),
          const SizedBox(height: 12),
          Text(valor,
              style: TextStyle(
                color:      color,
                fontSize:   26,
                fontWeight: FontWeight.w800,
              )),
          const SizedBox(height: 4),
          Text(subtitulo,
              style: const TextStyle(
                  color: FretixColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

// ── Badge de estado activo/inactivo ──────────────────────────────────────────

class _BadgeEstado extends StatelessWidget {
  final bool   activo;
  final String labelActivo;
  final String labelInactivo;
  const _BadgeEstado({
    required this.activo,
    this.labelActivo   = 'Activo',
    this.labelInactivo = 'Inactivo',
  });

  @override
  Widget build(BuildContext context) {
    final color = activo ? FretixColors.success : FretixColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        activo ? labelActivo : labelInactivo,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Chip de categoría de vehículo ────────────────────────────────────────────

class _CategoriaChipWeb extends StatelessWidget {
  final String categoria;
  const _CategoriaChipWeb({required this.categoria});

  static const _labels = {
    'mini': 'Mini', 'plus': 'Plus', 'max': 'Max', 'heavy': 'Pesada',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color:        FretixColors.accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _labels[categoria] ?? categoria,
        style: const TextStyle(
            color: FretixColors.accent, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Campo de texto web ───────────────────────────────────────────────────────

class _WebField extends StatelessWidget {
  final TextEditingController        ctrl;
  final String                       label;
  final TextInputType?               inputType;
  final String? Function(String?)?   validator;
  const _WebField({
    required this.ctrl,
    required this.label,
    this.inputType,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller:   ctrl,
      keyboardType: inputType,
      validator:    validator,
      style: const TextStyle(color: FretixColors.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        labelText:     label,
        labelStyle:    const TextStyle(color: FretixColors.textSecondary, fontSize: 12),
        filled:        true,
        fillColor:     FretixColors.background,
        isDense:       true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: FretixColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: FretixColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: FretixColors.accent, width: 1.5),
        ),
      ),
    );
  }
}
```

---

## 9. ACTUALIZACIÓN DE `functions/index.js` — FINAL

```javascript
// functions/index.js — versión final con todos los módulos

const { initializeApp } = require('firebase-admin/app');
initializeApp();

// Módulo 2 — Onboarding
const { completarOnboardingFretix }  = require('./src/onboarding');

// Módulo 3 — Tarifas y Mapas
const { cotizarViajeFretix }         = require('./src/cotizacion');

// Módulo 4 — Matcheo y Estados
const { triggerMatcheoEnConfirmacion,
        onOfertaExpirada }           = require('./src/matcheo');
const { aceptarViajeFretix,
        rechazarViajeFretix,
        iniciarCargaFretix,
        llegueAlOrigenFretix,
        finalizarViajeFretix,
        cancelarViajeFretix }        = require('./src/estados_viaje');
const { actualizarUbicacionChofer }  = require('./src/ubicacion');

// Módulo 6 — Calificaciones y B2B
const { registrarCalificacionFretix } = require('./src/calificaciones');
const { invitarSubUsuarioFretix }     = require('./src/subusuarios');

module.exports = {
  // Onboarding
  completarOnboardingFretix,
  // Cotización
  cotizarViajeFretix,
  // Matcheo
  triggerMatcheoEnConfirmacion,
  onOfertaExpirada,
  // Estados del viaje
  aceptarViajeFretix,
  rechazarViajeFretix,
  iniciarCargaFretix,
  llegueAlOrigenFretix,
  finalizarViajeFretix,
  cancelarViajeFretix,
  // Ubicación
  actualizarUbicacionChofer,
  // Calificaciones
  registrarCalificacionFretix,
  // B2B
  invitarSubUsuarioFretix,
};
```

---

## 10. COLECCIONES NUEVAS EN ESTE MÓDULO

### `/liquidaciones/{liquidacionId}`
Generada por un proceso quincenal (Cloud Scheduler).

```json
{
  "liquidacionId": "liq_transandina_2025_07_01",
  "companyId":     "cmp_transandina_carrier",
  "periodo":       "2025-07-01 al 2025-07-15",
  "cantidadViajes": 47,
  "montoNeto":     285400,
  "comisionFretix": 50365,
  "estado":        "pendiente",
  "tripIds":       ["trp_001", "trp_002", "..."],
  "fecha":         "2025-07-16T00:00:00Z"
}
```

### Campos nuevos en `/users` (stats de clientes)

```json
{
  "stats": {
    "calificacionPromedio":  4.82,
    "totalCalificaciones":   34
  }
}
```

---

## 11. ARCHIVOS DEL MÓDULO

| Archivo | Tipo | Estado |
|---|---|---|
| `functions/src/calificaciones.js` | Node.js | ✅ |
| `lib/screens/shared/rating_screen.dart` | Dart | ✅ |
| `lib/screens/web/shared/web_scaffold.dart` | Dart | ✅ |
| `lib/screens/web/shared/web_widgets.dart` | Dart | ✅ |
| `lib/screens/web/cliente/portal_cliente_screen.dart` | Dart | ✅ |
| `lib/screens/web/cliente/tabs/dashboard_cliente_tab.dart` | Dart | ✅ |
| `lib/screens/web/cliente/tabs/usuarios_tab.dart` | Dart | ✅ |
| `lib/screens/web/cliente/tabs/historial_tab.dart` | Dart | ✅ |
| `lib/screens/web/transporte/tabs/gestion_flota_tab.dart` | Dart | ✅ |
| `lib/screens/web/transporte/tabs/liquidaciones_tab.dart` | Dart | ✅ |
| `functions/src/subusuarios.js` | Node.js | Pendiente (stub) |
| `functions/index.js` | Node.js | ✅ versión final |

---

## 12. DECISIONES DE ARQUITECTURA REGISTRADAS

| Decisión | Razonamiento |
|---|---|
| Promedio incremental en `registrarCalificacion` | Calcular el promedio releer todos los viajes del chofer escalaría O(n). Con la fórmula incremental se calcula en O(1) en una sola transacción |
| Filtro de mes en cliente (no en Firestore) | Firestore no soporta `startsWith` en strings de fecha. Con límite de 100 docs por empresa el filtro en memoria es aceptable. Escalar: añadir campo `periodo` (YYYY-MM) indexado |
| `DraggableScrollableSheet` + `Table` en web | Flutter Web no tiene DataTable nativo tan flexible. `Table` con `columnWidths` es más predecible en layout responsivo de escritorio |
| `liteModeEnabled` no aplica en web | El modo lite es solo para Android/iOS. En web, Flutter renderiza el mapa normalmente |
| `invitarSubUsuarioFretix` como Cloud Function | El flujo de invitar a un empleado requiere verificar que el número no esté ya registrado con otra empresa y enviar un SMS de invitación — lógica de backend pura |
| `/liquidaciones` como colección separada | No mezclar datos de liquidación en `/companies` para mantener el historial auditable e inmutable una vez generado el registro de pago |
| Alerta de RTO/VTV < 30 días en frontend | Se calcula en cliente porque no requiere query adicional a Firestore — ya tenemos todos los vehículos en el stream. Evita una Cloud Function scheduled extra para alertas |

---

## 13. RESUMEN GENERAL DEL PLANO DE INGENIERÍA — FRETIX COMPLETO

| Módulo | Alcance | Estado |
|---|---|---|
| **M1 — Arquitectura Firestore** | Colecciones, modelos de datos, IDs cruzados | ✅ Aprobado |
| **M2 — Auth y Onboarding** | Firebase Auth OTP, roles, creación atómica de empresa | ✅ Aprobado |
| **M3 — Motor de Tarifas y Mapas** | Cotizador con Google Maps, Haversine fallback, `/quotations` | ✅ Aprobado |
| **M4 — Flujo del Viaje y Matcheo** | Geohash, cola de asignación, máquina de estados, FCM | ✅ Aprobado |
| **M5 — UI Flutter Móvil** | OfertaViajeScreen, TripControlScreen, TrackingScreen, Slider | ✅ Aprobado |
| **M6 — Web B2B y Cierre** | RatingScreen, Portal cliente, Portal transporte, Liquidaciones | ✅ Aprobado |

### Cloud Functions totales del sistema

| Función | Módulo | Tipo |
|---|---|---|
| `completarOnboardingFretix` | M2 | onCall |
| `cotizarViajeFretix` | M3 | onCall |
| `triggerMatcheoEnConfirmacion` | M4 | onDocumentUpdated |
| `onOfertaExpirada` | M4 | onDocumentDeleted (TTL) |
| `aceptarViajeFretix` | M4 | onCall |
| `rechazarViajeFretix` | M4 | onCall |
| `llegueAlOrigenFretix` | M4 | onCall |
| `iniciarCargaFretix` | M4 | onCall |
| `finalizarViajeFretix` | M4 | onCall |
| `cancelarViajeFretix` | M4 | onCall |
| `actualizarUbicacionChofer` | M4 | onCall (minInstances: 1) |
| `registrarCalificacionFretix` | M6 | onCall |
| `invitarSubUsuarioFretix` | M6 | onCall |

**Total: 13 Cloud Functions · 7 colecciones raíz · 1 colección auxiliar (`ofertas_viaje`) · 1 colección de auditoría (`quotations`) · 1 colección de liquidaciones**

---

*Plano de ingeniería de FRETIX completado — Módulo 6 aprobado.*
*Sistema listo para implementación incremental comenzando por M1 → M2 → M3.*
