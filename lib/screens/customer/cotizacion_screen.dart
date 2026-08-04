// lib/screens/customer/cotizacion_screen.dart
//
// Pantalla de cotización de viaje — Módulo 3.
// Spec DEFINITIVA firmada por CPO · CMO · CTO · CEO. Inmutable.
// Usa FretixColors.accent (Cobre 0xFFD4A373, migrado globalmente en fretix_colors.dart).

import 'dart:math' show sin, cos, asin, sqrt, pi;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/cotizacion_args.dart';
import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

// ── Coordenadas mock — Mendoza Capital (usadas cuando no vienen args).
const _kOrigenMock  = LatLng(-32.8908, -68.8272);
const _kDestinoMock = LatLng(-32.9500, -68.8700);

// ── Dark map style nocturno — OBLIGATORIO (Bloque C).
// Prohibido el mapa diurno default, incluso como estado transitorio (spec CTO).
const _kMapStyleNocturno = r'''
[
  {"elementType":"geometry","stylers":[{"color":"#1a1a1a"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#555555"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#0d0d0d"}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#111111"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2a2a2a"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#111111"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#333333"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#1a1a1a"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0d0d0d"}]},
  {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#2a2a2a"}]}
]
''';

// ── Definición de categorías — orden del carrusel (spec F).
class _CategoriaFlota {
  final String   id;
  final String   label;
  final IconData icon;
  const _CategoriaFlota(this.id, this.label, this.icon);
}

const _kCategorias = [
  _CategoriaFlota('mini',  'Mini',    Icons.directions_car_outlined),
  _CategoriaFlota('plus',  'Plus',    Icons.airport_shuttle_outlined),
  _CategoriaFlota('max',   'Max',     Icons.local_shipping_outlined),
  _CategoriaFlota('heavy', 'Pesado',  Icons.construction_outlined),
];

// ═══════════════════════════════════════════════════════════════════════════════
// CotizacionScreen
// ═══════════════════════════════════════════════════════════════════════════════

class CotizacionScreen extends StatefulWidget {
  const CotizacionScreen({super.key, this.args});

  final CotizacionArgs? args;

  @override
  State<CotizacionScreen> createState() => _CotizacionScreenState();
}

class _CotizacionScreenState extends State<CotizacionScreen> {

  // ── [ESTADO] Spec B — reactivo ────────────────────────────────────────────
  String   _selectedCategory  = 'max';
  bool     _hasHelper         = false;
  bool     _isLoading         = false;
  Map<String, dynamic>? _cotizacionActual;
  Polyline? _rutaPolyline;
  // Inicia en true: el mapa solo se muestra si el backend confirma mapsFuente=google_maps.
  // Esto evita el crash de GoogleMap en web cuando no hay API key en index.html.
  bool     _modoContingencia  = true;

  // ── [ESTADO] Animación de precio — valores prev/next para TweenAnimationBuilder.
  double _precioActual   = 0;
  double _precioAnterior = 0;

  // ── [ESTADO] Mapa
  // _mapDisponible: false cuando Google Maps crashea sin API key (modo web sin clave).
  // En ese caso la pantalla parte directo en modoContingencia.
  GoogleMapController? _mapController;
  bool          _mapDisponible = true;
  Set<Marker>   _markers   = {};
  Set<Polyline> _polylines = {};

  // Coordenadas activas — desde args o mock si viene sin ellas.
  late final LatLng _origen;
  late final LatLng _destino;

  bool _isConfirming = false;

  // Contexto de crédito B2B — null = no resuelto/error → default-secure: bloquea.
  String?               _clientType;  // 'particular' | 'empresa' | null
  String?               _companyId;
  Map<String, dynamic>? _creditData;  // cuentaCorriente del company

  @override
  void initState() {
    super.initState();
    _origen  = widget.args?.origen  ?? _kOrigenMock;
    _destino = widget.args?.destino ?? _kDestinoMock;
    _cotizar();
    _loadUserCreditContext();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  // ── [CLOUD FUNCTION] Spec D ───────────────────────────────────────────────
  // Disparada automáticamente en cada cambio de categoría o ayudante.
  // isLoading=true antes, false siempre al salir (éxito, contingencia o error real).
  Future<void> _cotizar() async {
    setState(() => _isLoading = true);

    try {
      final callable = FretixAuthService.instance.getCallable('cotizarViajeFretix');

      // Payload exacto según contrato de cotizacion.js (Spec D).
      final result = await callable.call({
        'originLat':      _origen.latitude,
        'originLng':      _origen.longitude,
        'destinationLat': _destino.latitude,
        'destinationLng': _destino.longitude,
        'categoria':      _selectedCategory,
        'ayudante':       _hasHelper,
        'paradas': [
          {'lat': _origen.latitude,  'lng': _origen.longitude},
          {'lat': _destino.latitude, 'lng': _destino.longitude},
        ],
      });

      final data        = Map<String, dynamic>.from(result.data as Map);
      final fuente      = data['mapsFuente'] as String? ?? '';
      final polylineStr = data['polyline']   as String?;
      final esContingencia = fuente == 'haversine_contingencia';

      // [ANIMACIÓN] Guardar precio previo antes de actualizar para el tween (Spec E).
      _precioAnterior = _precioActual;
      _precioActual   = (data['total'] as num).toDouble();

      // [POLILÍNEA] Decodificar con flutter_polyline_points (dep ya en pubspec, Spec C).
      // Color: FretixColors.accent — no un color inline (restricción de legibilidad Spec A).
      Set<Polyline> newPolylines = {};
      if (!esContingencia && polylineStr != null && polylineStr.isNotEmpty) {
        final puntos = PolylinePoints()
            .decodePolyline(polylineStr)
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList();

        newPolylines = {
          Polyline(
            polylineId: const PolylineId('ruta_fretix'),
            points:     puntos,
            color:      FretixColors.accent, // Cobre — trazado de ruta (Spec C + A)
            width:      4,
          ),
        };
      }

      setState(() {
        _cotizacionActual = data;
        _modoContingencia = esContingencia;
        _rutaPolyline     = newPolylines.isNotEmpty ? newPolylines.first : null;
        _polylines        = newPolylines;
        _markers          = _buildMarkers();
        _isLoading        = false;
      });

      // [AUTO-ZOOM] Spec C — solo cuando hay GoogleMap (no en contingencia).
      if (!esContingencia) _autoZoom();

    } on FirebaseFunctionsException catch (_) {
      const useEmulator = bool.fromEnvironment('USE_EMULATOR', defaultValue: false);
      if (useEmulator) {
        // En el emulador de Codespaces el preflight CORS falla (bug del emulador v2).
        // Fallback client-side: misma fórmula Haversine×1.35 que usa el backend.
        _fallbackEmulador();
      } else {
        setState(() => _isLoading = false);
        _showErrorSnackBar('Error al cotizar. Intentá de nuevo.');
      }
    } catch (_) {
      const useEmulator = bool.fromEnvironment('USE_EMULATOR', defaultValue: false);
      if (useEmulator) {
        _fallbackEmulador();
      } else {
        setState(() => _isLoading = false);
        _showErrorSnackBar('Sin conexión. Intentá de nuevo.');
      }
    }
  }

  // Fallback client-side para emulador — mismos coeficientes que /config/tarifas en Firestore.
  // Solo activo cuando USE_EMULATOR=true y el emulador de Functions no responde CORS.
  void _fallbackEmulador() {
    const tarifas = {
      'mini':  {'base': 1800.0, 'perKm': 350.0, 'perMin': 90.0},
      'plus':  {'base': 2800.0, 'perKm': 450.0, 'perMin': 120.0},
      'max':   {'base': 6500.0, 'perKm': 700.0, 'perMin': 180.0},
      'heavy': {'base': 15000.0,'perKm': 1200.0,'perMin': 250.0},
    };
    const comision   = 0.15;
    const helperFeeM = 5000.0;
    const factorMendoza = 1.35;
    const velocidadKmh  = 30.0;

    final tarifa  = tarifas[_selectedCategory]!;
    final distKm  = double.parse(
      (_haversineKm(_origen, _destino) * factorMendoza).toStringAsFixed(2),
    );
    final durMin  = double.parse(
      ((distKm / velocidadKmh) * 60).toStringAsFixed(1),
    );

    final base     = tarifa['base']!;
    final costoKm  = tarifa['perKm']!  * distKm;
    final costoMin = tarifa['perMin']! * durMin;
    final subtotal = base + costoKm + costoMin;
    final helper   = _hasHelper ? helperFeeM : 0.0;
    final comisionM = subtotal * comision;
    final total    = subtotal + comisionM + helper;

    _precioAnterior = _precioActual;
    _precioActual   = total;

    setState(() {
      _modoContingencia = true;
      _isLoading        = false;
      _cotizacionActual = {
        'total':       total,
        'subtotal':    subtotal,
        'helperFee':   helper,
        'comisionApp': comisionM,
        'distanciaKm': distKm,
        'duracionMin': durMin,
        'mapsFuente':  'haversine_contingencia',
      };
    });
  }

  // Haversine entre dos puntos geográficos — espejo de la implementación en cotizacion.js.
  double _haversineKm(LatLng a, LatLng b) {
    double toRad(double deg) => deg * pi / 180;
    final dLat = toRad(b.latitude  - a.latitude);
    final dLng = toRad(b.longitude - a.longitude);
    final x = sin(dLat / 2) * sin(dLat / 2) +
              cos(toRad(a.latitude)) * cos(toRad(b.latitude)) *
              sin(dLng / 2) * sin(dLng / 2);
    return 2 * 6371 * asin(sqrt(x));
  }

  Set<Marker> _buildMarkers() => {
    Marker(
      markerId: const MarkerId('origen'),
      position: _origen,
      icon: BitmapDescriptor.defaultMarkerWithHue(40.0),
    ),
    Marker(
      markerId: const MarkerId('destino'),
      position: _destino,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
    ),
  };

  // [AUTO-ZOOM] Spec C — padding 80dp, reactivo al recibir cotización.
  Future<void> _autoZoom() async {
    if (_mapController == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        _origen.latitude  < _destino.latitude  ? _origen.latitude  : _destino.latitude,
        _origen.longitude < _destino.longitude ? _origen.longitude : _destino.longitude,
      ),
      northeast: LatLng(
        _origen.latitude  > _destino.latitude  ? _origen.latitude  : _destino.latitude,
        _origen.longitude > _destino.longitude ? _origen.longitude : _destino.longitude,
      ),
    );
    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80.0),
    );
  }

  void _showErrorSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:         Text(msg),
      backgroundColor: FretixColors.danger,
      behavior:        SnackBarBehavior.floating,
      duration:        const Duration(seconds: 3),
    ));
  }

  Future<void> _loadUserCreditContext() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return; // sin auth → _clientType sigue null → bloquea

    try {
      final userSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final onboardingRole = userSnap.data()?['onboardingRole'] as String?;

      if (onboardingRole != 'cliente_empresa_maestro') {
        if (mounted) setState(() => _clientType = 'particular');
        return;
      }

      // Empresa → buscar companyId en /company_members
      final memberSnap = await FirebaseFirestore.instance
          .collection('company_members')
          .where('userId', isEqualTo: uid)
          .limit(1)
          .get();

      if (memberSnap.docs.isEmpty) return; // anomalía → _clientType null → bloquea

      final companyId = memberSnap.docs.first.data()['companyId'] as String?;
      if (companyId == null) return; // dato corrupto → bloquea

      final companySnap = await FirebaseFirestore.instance
          .collection('companies')
          .doc(companyId)
          .get();
      final cc = companySnap.data()?['cuentaCorriente'] as Map<String, dynamic>?;

      if (mounted) {
        setState(() {
          _clientType = 'empresa';
          _companyId  = companyId;
          _creditData = cc; // null aquí → puedeConfirmarPorCredito bloqueará
        });
      }
    } catch (_) {
      // Cualquier falla de red/Firestore → _clientType sigue null → bloquea.
    }
  }

  // ── [CONFIRMAR VIAJE] Llama a confirmarViajeFretix (Cloud Function) que
  // escribe /viajes/{id} desde el servidor. Evita el WebChannel de Firestore,
  // incompatible con el tunnel HTTPS de Codespaces.
  Future<void> _confirmarViaje() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _cotizacionActual == null) return;

    setState(() => _isConfirming = true);
    try {
      final callable = FretixAuthService.instance.getCallable(
        'confirmarViajeFretix',
        timeout: const Duration(seconds: 20),
      );
      await callable.call({
        'clientType':    _clientType!,   // seguro: botón deshabilitado mientras null
        if (_clientType == 'empresa') 'companyId': _companyId!,
        'pricingMethod': _cotizacionActual!['mapsFuente'] ?? 'haversine_contingencia',
        'categoria':     _selectedCategory,
        'ayudante':      _hasHelper,
        'origen': {
          'lat':     _origen.latitude,
          'lng':     _origen.longitude,
          'address': widget.args?.origenLabel ?? '',
        },
        'destino': {
          'lat':     _destino.latitude,
          'lng':     _destino.longitude,
          'address': widget.args?.destinoLabel ?? '',
        },
        'cotizacion': {
          'total':       _cotizacionActual!['total'],
          'distanciaKm': _cotizacionActual!['distanciaKm'],
          'duracionMin': _cotizacionActual!['duracionMin'],
        },
      });

      if (!mounted) return;
      Navigator.of(context).pushNamed(AppRouter.buscandoChofer);
    } catch (e) {
      if (!mounted) return;
      _showErrorSnackBar('No se pudo confirmar el viaje. Intentá de nuevo.');
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  // [REACTIVE] Cambio de categoría → nueva cotización automática (Spec D).
  void _onCategoryChanged(String cat) {
    if (_selectedCategory == cat) return;
    setState(() => _selectedCategory = cat);
    _cotizar();
  }

  // [REACTIVE] Toggle ayudante → nueva cotización automática (Spec D).
  void _onHelperChanged(bool value) {
    setState(() => _hasHelper = value);
    _cotizar();
  }

  // [FORMATO PESO] Patrón _formatPeso del proyecto — miles con punto (Spec E, Módulo 6).
  String _formatPeso(double monto) {
    final entero = monto.toStringAsFixed(0);
    final buf    = StringBuffer();
    final len    = entero.length;
    for (int i = 0; i < len; i++) {
      if (i > 0 && (len - i) % 3 == 0) buf.write('.');
      buf.write(entero[i]);
    }
    return '\$ ${buf.toString()}';
  }

  // ── [SPEC H] Validación de crédito B2B — hook listo para Módulo 4 ─────────
  //
  // Mapeo Firestore confirmado (onboarding.js, líneas 139-147):
  //   creditCheckEnabled → cuentaCorriente.habilitada
  //   saldoActualARS     → cuentaCorriente.saldoActualARS
  //   limiteCreditoARS   → cuentaCorriente.limiteCreditoARS
  //   macroLimitAudit    → cuentaCorriente.macroLimitAudit (campo nuevo, CPO Módulo 4.1)
  //
  // TODO(Módulo 4): leer /companies/{companyId} en tiempo real y pasar los valores.

  /// Evalúa si la empresa puede confirmar el viaje según su cuenta corriente.
  /// PRINCIPIO DE DEFAULT SEGURO: cualquier dato nulo o inconsistente → riesgo máximo → bloquear.
  bool puedeConfirmarPorCredito({
    required bool    creditCheckEnabled,
    required double? saldoActualARS,
    required double? limiteCreditoARS,
    required double? macroLimitAudit,
  }) {
    if (!creditCheckEnabled) {
      // Cuenta liberada — pero se exige integridad del dato de auditoría.
      if (macroLimitAudit == null || macroLimitAudit <= 0) {
        return false; // Default seguro: auditoría ausente/inválida → bloquear.
      }
      return true;
    }
    // Validación en caliente: saldo no puede superar el límite habilitado.
    if (saldoActualARS == null || limiteCreditoARS == null) return false;
    return saldoActualARS.abs() <= limiteCreditoARS;
  }

  bool _creditPermitido() {
    if (_clientType == null) return false;          // resolviendo o error → bloquea
    if (_clientType == 'particular') return true;   // sin validación de crédito
    if (_creditData == null) return false;          // empresa sin datos → bloquea
    final cc = _creditData!;
    return puedeConfirmarPorCredito(
      creditCheckEnabled: cc['habilitada']       as bool?   ?? false,
      saldoActualARS:    (cc['saldoActualARS']   as num?)?.toDouble(),
      limiteCreditoARS:  (cc['limiteCreditoARS'] as num?)?.toDouble(),
      macroLimitAudit:   (cc['macroLimitAudit']  as num?)?.toDouble(),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasArgs = widget.args != null;

    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Chips de ruta (Módulo 4) — solo cuando vienen args de SearchLocation.
            if (hasArgs)
              _RouteChips(
                origenLabel:  widget.args!.origenLabel,
                destinoLabel: widget.args!.destinoLabel,
                onBack: () => Navigator.of(context).pop(),
              ),

            // ── Zona superior 60% — mapa o contingencia (Spec A + G) ──────────
            Expanded(
              flex: 6,
              child: _modoContingencia
                  ? _ContingenciaZona(
                      precioAnterior: _precioAnterior,
                      precioActual:   _precioActual,
                      isLoading:      _isLoading,
                      formatPeso:     _formatPeso,
                    )
                  : _MapaZona(
                      origen:    _origen,
                      destino:   _destino,
                      polylines: _polylines,
                      markers:   _markers,
                      onMapCreated: (ctrl) async {
                        _mapController = ctrl;
                        // Aplica dark style de inmediato — sin transición diurna (Spec C).
                        await ctrl.setMapStyle(_kMapStyleNocturno);
                        if (_cotizacionActual != null && !_modoContingencia) {
                          _autoZoom();
                        }
                      },
                    ),
            ),

            // ── Panel inferior flotante 40% (Spec A) ──────────────────────────
            Expanded(
              flex: 4,
              child: _PanelControl(
                selectedCategory:  _selectedCategory,
                hasHelper:         _hasHelper,
                isLoading:         _isLoading,
                isConfirming:      _isConfirming,
                precioAnterior:    _precioAnterior,
                precioActual:      _precioActual,
                formatPeso:        _formatPeso,
                onCategoryChanged: _onCategoryChanged,
                onHelperChanged:   _onHelperChanged,
                puedeConfirmar:    _cotizacionActual != null && !_isLoading && _creditPermitido(),
                onConfirmar:       _confirmarViaje,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _MapaZona — GoogleMap con dark style nocturno (Spec C)
// ═══════════════════════════════════════════════════════════════════════════════

class _MapaZona extends StatelessWidget {
  const _MapaZona({
    required this.origen,
    required this.destino,
    required this.polylines,
    required this.markers,
    required this.onMapCreated,
  });

  final LatLng        origen;
  final LatLng        destino;
  final Set<Polyline> polylines;
  final Set<Marker>   markers;
  final void Function(GoogleMapController) onMapCreated;

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(
          (origen.latitude  + destino.latitude)  / 2,
          (origen.longitude + destino.longitude) / 2,
        ),
        zoom: 12,
      ),
      onMapCreated:            onMapCreated,
      polylines:               polylines,
      markers:                 markers,
      myLocationButtonEnabled: false,
      zoomControlsEnabled:     false,
      mapToolbarEnabled:       false,
      compassEnabled:          false,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _ContingenciaZona — Spec G: estado de negocio esperado, no error.
// CERO SnackBars / dialogs / íconos de warning.
// ═══════════════════════════════════════════════════════════════════════════════

class _ContingenciaZona extends StatelessWidget {
  const _ContingenciaZona({
    required this.precioAnterior,
    required this.precioActual,
    required this.isLoading,
    required this.formatPeso,
  });

  final double precioAnterior;
  final double precioActual;
  final bool   isLoading;
  final String Function(double) formatPeso;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: FretixColors.background, // fondo liso #0D0D0D (Spec G)
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Precio con misma jerarquía financiera que el panel (Spec G → Spec E)
          _PrecioAnimado(
            anterior:   precioAnterior,
            actual:     precioActual,
            isLoading:  isLoading,
            formatPeso: formatPeso,
          ),
          const SizedBox(height: 20),
          // Copy exacto aprobado — no parafrasear (Spec G)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 36),
            child: Text(
              'Estimación por distancia confirmada. El trazado se ajusta automáticamente al iniciar el viaje.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:    FretixColors.textSecondary, // NO FretixColors.accent (Spec A)
                fontSize: 14,
                height:   1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _PanelControl — bottom sheet flotante con sombra (Spec A)
// ═══════════════════════════════════════════════════════════════════════════════

class _PanelControl extends StatelessWidget {
  const _PanelControl({
    required this.selectedCategory,
    required this.hasHelper,
    required this.isLoading,
    required this.isConfirming,
    required this.precioAnterior,
    required this.precioActual,
    required this.formatPeso,
    required this.onCategoryChanged,
    required this.onHelperChanged,
    required this.puedeConfirmar,
    required this.onConfirmar,
  });

  final String   selectedCategory;
  final bool     hasHelper;
  final bool     isLoading;
  final bool     isConfirming;
  final double   precioAnterior;
  final double   precioActual;
  final String Function(double)  formatPeso;
  final void Function(String)    onCategoryChanged;
  final void Function(bool)      onHelperChanged;
  final bool     puedeConfirmar;
  final Future<void> Function()  onConfirmar;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: FretixColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withOpacity(0.35),
            blurRadius: 20,
            offset:     const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        children: [
          // Handle decorativo
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color:        FretixColors.surfaceBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Carrusel de categorías (Spec F)
                  _CarruselCategorias(
                    selected:  selectedCategory,
                    onChanged: onCategoryChanged,
                  ),
                  const SizedBox(height: 20),

                  // ── Precio animado (Spec E)
                  _PrecioAnimado(
                    anterior:   precioAnterior,
                    actual:     precioActual,
                    isLoading:  isLoading,
                    formatPeso: formatPeso,
                  ),

                  // ── Disclaimer legal — texto exacto, no parafrasear (Spec F)
                  const SizedBox(height: 4),
                  const Text(
                    'Tarifa estimada, sujeta a variación según kilometraje y tiempo real de viaje.',
                    style: TextStyle(
                      color:    FretixColors.textMuted, // NO FretixColors.accent (Spec A)
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Switch ayudante custom (Spec F)
                  _SwitchAyudante(
                    value:     hasHelper,
                    onChanged: onHelperChanged,
                  ),
                  const SizedBox(height: 24),

                  // ── Botón confirmar (Módulo 4)
                  SizedBox(
                    width:  double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: puedeConfirmar && !isConfirming ? onConfirmar : null,
                      style: ElevatedButton.styleFrom(
                        disabledBackgroundColor: FretixColors.surfaceBorder,
                        disabledForegroundColor: FretixColors.textMuted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: isConfirming
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                color:       FretixColors.accent,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Text(
                              'Confirmar viaje',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _PrecioAnimado — TweenAnimationBuilder count-up/down (Spec E)
// ═══════════════════════════════════════════════════════════════════════════════

class _PrecioAnimado extends StatelessWidget {
  const _PrecioAnimado({
    required this.anterior,
    required this.actual,
    required this.isLoading,
    required this.formatPeso,
  });

  final double anterior;
  final double actual;
  final bool   isLoading;
  final String Function(double) formatPeso;

  @override
  Widget build(BuildContext context) {
    // Loader propio en FretixColors.accent — sin nuevas dependencias (Spec D).
    if (isLoading && actual == 0) {
      return const SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(
            width: 28, height: 28,
            child: CircularProgressIndicator(
              color:       FretixColors.accent,
              strokeWidth: 2.5,
            ),
          ),
        ),
      );
    }

    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        // Spinner sutil de recotización sobre precio anterior visible
        if (isLoading)
          const Positioned(
            right: 0,
            child: SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(
                color: FretixColors.accent, strokeWidth: 1.5,
              ),
            ),
          ),

        // [TWEEN] Interpola suave de precio anterior → nuevo. Nunca salta (Spec E).
        TweenAnimationBuilder<double>(
          tween:    Tween<double>(begin: anterior, end: actual),
          duration: const Duration(milliseconds: 200),
          curve:    Curves.easeOut,
          builder:  (_, value, __) => Text(
            formatPeso(value),
            style: const TextStyle(
              color:         FretixColors.textPrimary, // NO FretixColors.accent (Spec A + E)
              fontSize:      34,
              fontWeight:    FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _CarruselCategorias — selector horizontal, borde activo en accent (Spec F)
// ═══════════════════════════════════════════════════════════════════════════════

class _CarruselCategorias extends StatelessWidget {
  const _CarruselCategorias({required this.selected, required this.onChanged});

  final String selected;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: ListView.separated(
        scrollDirection:  Axis.horizontal,
        itemCount:        _kCategorias.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final cat      = _kCategorias[i];
          final isActive = cat.id == selected;

          return GestureDetector(
            onTap: () => onChanged(cat.id),
            child: AnimatedContainer(
              duration:    const Duration(milliseconds: 180),
              curve:       Curves.easeOut,
              width:       84,
              padding:     const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              decoration:  BoxDecoration(
                color: isActive
                    ? FretixColors.accent.withOpacity(0.10)
                    : FretixColors.surfaceBorder.withOpacity(0.40),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isActive ? FretixColors.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Ícono transiciona textMuted → FretixColors.accent (Spec F)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      cat.icon,
                      size:  22,
                      color: isActive ? FretixColors.accent : FretixColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    cat.label,
                    style: TextStyle(
                      color:      isActive
                          ? FretixColors.textPrimary
                          : FretixColors.textSecondary,
                      fontSize:   12,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _SwitchAyudante — custom con AnimatedAlign + AnimatedContainer (Spec F)
// NO usa Switch Material. Activo: FretixColors.accent. Inactivo: surfaceBorder.
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// _RouteChips — chips de origen/destino en la parte superior (Módulo 4)
// ═══════════════════════════════════════════════════════════════════════════════

class _RouteChips extends StatelessWidget {
  const _RouteChips({
    required this.origenLabel,
    required this.destinoLabel,
    required this.onBack,
  });

  final String origenLabel;
  final String destinoLabel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 20, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: FretixColors.textSecondary, size: 18),
            onPressed: onBack,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RouteChip(
                  icon:  Icons.trip_origin_rounded,
                  color: FretixColors.accent,
                  label: origenLabel,
                ),
                const SizedBox(height: 4),
                _RouteChip(
                  icon:  Icons.location_on_rounded,
                  color: FretixColors.textSecondary,
                  label: destinoLabel,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteChip extends StatelessWidget {
  const _RouteChip({required this.icon, required this.color, required this.label});
  final IconData icon;
  final Color    color;
  final String   label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines:  1,
            overflow:  TextOverflow.ellipsis,
            style: const TextStyle(
              color:    FretixColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _SwitchAyudante extends StatelessWidget {
  const _SwitchAyudante({required this.value, required this.onChanged});

  final bool value;
  final void Function(bool) onChanged;

  static const _trackW  = 48.0;
  static const _trackH  = 28.0;
  static const _thumbSz = 22.0;
  static const _pad     =  3.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Track animado
        GestureDetector(
          onTap: () => onChanged(!value),
          child: AnimatedContainer(
            duration:    const Duration(milliseconds: 200),
            curve:       Curves.easeInOut,
            width:       _trackW,
            height:      _trackH,
            padding:     const EdgeInsets.all(_pad),
            decoration:  BoxDecoration(
              color: value ? FretixColors.accent : FretixColors.surfaceBorder,
              borderRadius: BorderRadius.circular(_trackH / 2),
            ),
            child: AnimatedAlign(
              duration:  const Duration(milliseconds: 200),
              curve:     Curves.easeInOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width:  _thumbSz,
                height: _thumbSz,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? FretixColors.background : FretixColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),

        // Microtextos — textSecondary, NO FretixColors.accent (Spec A + F)
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ayudante',
                style: TextStyle(
                  color:      FretixColors.textPrimary,
                  fontSize:   14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Incluye asistencia en carga y descarga', // texto exacto (Spec F)
                style: TextStyle(
                  color:    FretixColors.textSecondary,   // NO FretixColors.accent (Spec A)
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
