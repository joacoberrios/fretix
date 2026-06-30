# FRETIX — Módulo 5: Interfaz de Usuario Flutter (Móvil)
**Versión:** 1.0 | **Fecha:** 2025-06-29
**Módulos anteriores:** [Arquitectura Firestore](./FRETIX_Arquitectura_Firestore.md) · [Auth](./FRETIX_Modulo2_Auth_Onboarding.md) · [Tarifas](./FRETIX_Modulo3_Tarifas_Mapas.md) · [Matcheo](./FRETIX_Modulo4_Flujo_Matcheo.md)
**Stack:** Flutter 3.x · Dart · google_maps_flutter · cloud_firestore · cloud_functions · geolocator

---

## 1. OBJETIVO DEL MÓDULO

Construir los widgets Flutter de alta fidelidad que conectan con los Streams de Firestore
y Cloud Functions definidos en los módulos anteriores. Toda la UI es reactiva: ningún
componente mantiene estado de negocio propio — escucha y reacciona a Firestore.

---

## 2. ARQUITECTURA DE CAPAS EN FLUTTER

```
┌─────────────────────────────────────────────────────┐
│                  UI Layer (Screens/Widgets)          │
│  OfertaViajeScreen · TripControlScreen · TrackingScreen │
└──────────────────────┬──────────────────────────────┘
                       │ StreamBuilder / FutureBuilder
┌──────────────────────▼──────────────────────────────┐
│               Service Layer                          │
│  TripService · DriverService · MapsService           │
└──────────────────────┬──────────────────────────────┘
                       │ onCall / onSnapshot
┌──────────────────────▼──────────────────────────────┐
│            Firebase Layer                            │
│  Firestore · Cloud Functions · FCM                   │
└─────────────────────────────────────────────────────┘
```

---

## 3. PALETA DE COLORES Y TOKENS DE DISEÑO

```dart
// lib/theme/fretix_colors.dart

abstract class FretixColors {
  static const background    = Color(0xFF0D0D0D);
  static const surface       = Color(0xFF1A1A1A);
  static const surfaceBorder = Color(0xFF2A2A2A);
  static const accent        = Color(0xFFF5A623);   // Naranja Fretix
  static const accentDark    = Color(0xFFD4891A);
  static const success       = Color(0xFF22C55E);
  static const danger        = Color(0xFFEF4444);
  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF888888);
  static const textMuted     = Color(0xFF444444);
  static const countdown     = Color(0xFFEF4444);   // Rojo para el timer
}

abstract class FretixRadius {
  static const card   = BorderRadius.all(Radius.circular(16));
  static const button = BorderRadius.all(Radius.circular(14));
  static const chip   = BorderRadius.all(Radius.circular(8));
}
```

---

## 4. SERVICE LAYER — `TripService`

```dart
// lib/services/trip_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class TripService {
  TripService._();
  static final TripService instance = TripService._();

  final _db        = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  // ── Streams ────────────────────────────────────────────────────────────────

  /// Escucha en tiempo real el documento del viaje activo.
  Stream<DocumentSnapshot<Map<String, dynamic>>> streamTrip(String tripId) =>
      _db.collection('trips').doc(tripId).snapshots();

  /// Escucha la primera oferta pendiente dirigida a este chofer.
  Stream<QuerySnapshot<Map<String, dynamic>>> streamOfertasPendientes(String driverId) =>
      _db.collection('ofertas_viaje')
          .where('driverId', isEqualTo: driverId)
          .where('estado',   isEqualTo: 'pendiente')
          .limit(1)
          .snapshots();

  /// Escucha la ubicación en tiempo real del chofer asignado (para el cliente).
  Stream<DocumentSnapshot<Map<String, dynamic>>> streamUbicacionChofer(String driverId) =>
      _db.collection('drivers').doc(driverId).snapshots();

  // ── Cloud Functions ────────────────────────────────────────────────────────

  Future<void> aceptarViaje(String tripId) async {
    await _functions.httpsCallable('aceptarViajeFretix').call({'tripId': tripId});
  }

  Future<void> rechazarViaje(String tripId) async {
    await _functions.httpsCallable('rechazarViajeFretix').call({'tripId': tripId});
  }

  Future<void> llegueAlOrigen(String tripId) async {
    await _functions.httpsCallable('llegueAlOrigenFretix').call({'tripId': tripId});
  }

  Future<void> iniciarCarga(String tripId) async {
    await _functions.httpsCallable('iniciarCargaFretix').call({'tripId': tripId});
  }

  Future<Map<String, dynamic>> finalizarViaje(String tripId) async {
    final result = await _functions
        .httpsCallable('finalizarViajeFretix')
        .call({'tripId': tripId});
    return Map<String, dynamic>.from(result.data as Map);
  }

  Future<void> cancelarViaje(String tripId, String motivo) async {
    await _functions.httpsCallable('cancelarViajeFretix')
        .call({'tripId': tripId, 'motivo': motivo});
  }
}
```

---

## 5. PANTALLA 1 — `OfertaViajeScreen` (Vista Chofer)

### Archivo
`lib/screens/chofer/oferta_viaje_screen.dart`

### Comportamiento
- Stream listener en `/ofertas_viaje` filtrado por `driverId` y `estado: pendiente`
- Countdown circular de 45 segundos con AnimationController
- Slider "Deslizar para aceptar" que llama a `aceptarViajeFretix`
- Botón secundario "Rechazar" que llama a `rechazarViajeFretix`
- Al expirar el timer sin acción → se cierra automáticamente (el backend avanza la cola)

```dart
// lib/screens/chofer/oferta_viaje_screen.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/trip_service.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';
import '../../widgets/fretix_slider_button.dart';

class OfertaViajeScreen extends StatefulWidget {
  /// Si se pasa [tripId], muestra esa oferta directamente (desde FCM push).
  /// Si es null, escucha el stream y espera la primera oferta entrante.
  final String? tripId;

  const OfertaViajeScreen({super.key, this.tripId});

  @override
  State<OfertaViajeScreen> createState() => _OfertaViajeScreenState();
}

class _OfertaViajeScreenState extends State<OfertaViajeScreen>
    with SingleTickerProviderStateMixin {
  // ── Countdown ────────────────────────────────────────────────────────────
  static const _duracionSegundos = 45;
  late final AnimationController _countdownCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: _duracionSegundos),
  );
  late final Animation<double> _countdownAnim = _countdownCtrl;
  Timer? _tickTimer;
  int _segundosRestantes = _duracionSegundos;

  // ── Estado ───────────────────────────────────────────────────────────────
  bool _procesando = false;
  Map<String, dynamic>? _ofertaData;
  Map<String, dynamic>? _tripData;
  String?               _ofertaId;

  GoogleMapController? _mapController;

  @override
  void initState() {
    super.initState();
    _countdownCtrl.forward();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _segundosRestantes--;
        if (_segundosRestantes <= 0) _onTimeout();
      });
    });
  }

  @override
  void dispose() {
    _countdownCtrl.dispose();
    _tickTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  void _onTimeout() {
    _tickTimer?.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _aceptar() async {
    if (_procesando || _tripData == null) return;
    setState(() => _procesando = true);
    try {
      await TripService.instance.aceptarViaje(_tripData!['tripId'] as String);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        '/chofer/trip_control',
        arguments: _tripData!['tripId'],
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _procesando = false);
      _mostrarError('No se pudo aceptar el viaje. Intentá de nuevo.');
    }
  }

  Future<void> _rechazar() async {
    if (_tripData == null) return;
    await TripService.instance.rechazarViaje(_tripData!['tripId'] as String);
    if (mounted) Navigator.of(context).pop();
  }

  void _mostrarError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: FretixColors.danger),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final currentUser = FretixAuthService.instance.currentUser;
    if (currentUser == null) return const SizedBox.shrink();

    // Si ya tenemos la oferta pasada por args (desde FCM), la mostramos directo.
    // Si no, escuchamos el stream.
    if (widget.tripId != null) {
      return _buildConTripId(widget.tripId!);
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: TripService.instance.streamOfertasPendientes(
        // El driverId se resuelve desde el perfil del chofer en una app real.
        // Aquí asumimos que el uid == driverId por simplicidad de este widget.
        currentUser.uid,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const _PantallaEspera();
        }
        final doc = snapshot.data!.docs.first;
        _ofertaId   = doc.id;
        _ofertaData = doc.data();
        return _buildConTripId(_ofertaData!['tripId'] as String);
      },
    );
  }

  Widget _buildConTripId(String tripId) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: TripService.instance.streamTrip(tripId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            backgroundColor: FretixColors.background,
            body: Center(child: CircularProgressIndicator(color: FretixColors.accent)),
          );
        }
        _tripData = snapshot.data!.data();
        if (_tripData == null) return const SizedBox.shrink();

        return _buildUI(_tripData!);
      },
    );
  }

  Widget _buildUI(Map<String, dynamic> trip) {
    final origen   = trip['ruta']?['origen']?['direccion']  as String? ?? '';
    final destino  = trip['ruta']?['destino']?['direccion'] as String? ?? '';
    final pricing  = trip['pricing'] as Map<String, dynamic>? ?? {};
    final categoria = trip['vehiculoCategoria'] as String? ?? '';

    final ganancia = pricing['gananciaEstimadaChofer'] as num? ?? 0;
    final total    = pricing['totalCliente']           as num? ?? 0;

    final originGeo = trip['ruta']?['origen']?['geoPoint'];
    final destGeo   = trip['ruta']?['destino']?['geoPoint'];

    final LatLng? originLatLng = originGeo != null
        ? LatLng((originGeo as GeoPoint).latitude, originGeo.longitude)
        : null;
    final LatLng? destLatLng = destGeo != null
        ? LatLng((destGeo as GeoPoint).latitude, destGeo.longitude)
        : null;

    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header con countdown ───────────────────────────────────────
            _buildHeader(categoria),
            // ── Mini mapa de ruta ──────────────────────────────────────────
            Expanded(
              flex: 3,
              child: _MiniMapaRuta(
                origin:      originLatLng,
                destination: destLatLng,
                onMapCreated: (ctrl) => _mapController = ctrl,
              ),
            ),
            // ── Card de datos del viaje ────────────────────────────────────
            _buildDatosViaje(
              origen:   origen,
              destino:  destino,
              ganancia: ganancia.toDouble(),
              total:    total.toDouble(),
              trip:     trip,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String categoria) {
    final color = _segundosRestantes <= 10
        ? FretixColors.countdown
        : FretixColors.accent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          // Countdown circular
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 64, height: 64,
                child: AnimatedBuilder(
                  animation: _countdownAnim,
                  builder: (_, __) => CircularProgressIndicator(
                    value:            1 - _countdownCtrl.value,
                    strokeWidth:      5,
                    backgroundColor:  FretixColors.surfaceBorder,
                    color:            color,
                  ),
                ),
              ),
              Text(
                '$_segundosRestantes',
                style: TextStyle(
                  color:      color,
                  fontSize:   20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nueva carga disponible',
                  style: TextStyle(
                    color:      FretixColors.textPrimary,
                    fontSize:   18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _CategoriaChip(categoria: categoria),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDatosViaje({
    required String origen,
    required String destino,
    required double ganancia,
    required double total,
    required Map<String, dynamic> trip,
  }) {
    final distanciaKm = trip['distanciaKm'] as num? ?? 0;
    final duracionMin = trip['duracionMin'] as num? ?? 0;
    final ayudante    = trip['opciones']?['ayudante'] as bool? ?? false;

    // Determinar si el chofer es empleado (para mostrar u ocultar ganancia)
    // En producción esto viene del perfil cargado en el estado global del app.
    // Aquí lo leemos del trip como proxy.
    final esEmpleado = trip['asignacion']?['employerCompanyId'] != null;

    return Container(
      decoration: const BoxDecoration(
        color: FretixColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Origen → Destino
          _RutaRow(origen: origen, destino: destino),
          const SizedBox(height: 16),

          // Métricas del viaje
          Row(
            children: [
              _MetricaChip(icon: Icons.straighten_rounded,
                  label: '${distanciaKm.toStringAsFixed(1)} km'),
              const SizedBox(width: 8),
              _MetricaChip(icon: Icons.schedule_rounded,
                  label: '$duracionMin min'),
              if (ayudante) ...[
                const SizedBox(width: 8),
                const _MetricaChip(
                  icon: Icons.person_add_rounded,
                  label: 'Con ayudante',
                  highlighted: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),

          // Ganancia (solo visible si no es empleado)
          if (!esEmpleado) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color:        FretixColors.accent.withOpacity(0.12),
                borderRadius: FretixRadius.card,
                border:       Border.all(color: FretixColors.accent.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Tu ganancia estimada',
                      style: TextStyle(color: FretixColors.textSecondary, fontSize: 13)),
                  Text(
                    '\$${_formatoPeso(ganancia)}',
                    style: const TextStyle(
                      color:      FretixColors.accent,
                      fontSize:   22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Slider de aceptación
          _procesando
              ? const Center(child: CircularProgressIndicator(color: FretixColors.accent))
              : FretixSliderButton(
                  label:   'Deslizá para aceptar',
                  onSlide: _aceptar,
                ),
          const SizedBox(height: 12),

          // Botón rechazar
          TextButton(
            onPressed: _rechazar,
            child: const Text(
              'Rechazar viaje',
              style: TextStyle(color: FretixColors.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  String _formatoPeso(double valor) =>
      valor.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]}.',
      );
}

// ── Widget auxiliar: pantalla de espera sin oferta ───────────────────────────

class _PantallaEspera extends StatelessWidget {
  const _PantallaEspera();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: FretixColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_shipping_outlined, color: FretixColors.textMuted, size: 64),
            SizedBox(height: 16),
            Text('Esperando nuevas cargas...',
                style: TextStyle(color: FretixColors.textSecondary, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}
```

---

## 6. WIDGET AUXILIAR — `FretixSliderButton`

```dart
// lib/widgets/fretix_slider_button.dart
// Slider interactivo "deslizar para aceptar". Evita toques accidentales.

import 'package:flutter/material.dart';
import '../theme/fretix_colors.dart';

class FretixSliderButton extends StatefulWidget {
  final String   label;
  final VoidCallback onSlide;

  const FretixSliderButton({
    super.key,
    required this.label,
    required this.onSlide,
  });

  @override
  State<FretixSliderButton> createState() => _FretixSliderButtonState();
}

class _FretixSliderButtonState extends State<FretixSliderButton> {
  double _posicion  = 0;
  bool   _completado = false;

  static const _alturaTrack  = 60.0;
  static const _anchoPulgar  = 56.0;
  static const _umbralExito  = 0.85;   // 85% del ancho = éxito

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final anchoMax = constraints.maxWidth - _anchoPulgar - 8;

        return Container(
          height:      _alturaTrack,
          decoration:  BoxDecoration(
            color:        FretixColors.surfaceBorder,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Track de progreso
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width:    _anchoPulgar + 8 + (_posicion * anchoMax),
                decoration: BoxDecoration(
                  color:        FretixColors.accent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(30),
                ),
              ),

              // Label central
              Center(
                child: AnimatedOpacity(
                  opacity:  _completado ? 0 : (1 - (_posicion * 2).clamp(0, 1)),
                  duration: const Duration(milliseconds: 150),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.chevron_right_rounded,
                          color: FretixColors.textSecondary, size: 18),
                      const Icon(Icons.chevron_right_rounded,
                          color: FretixColors.textSecondary, size: 18),
                      const SizedBox(width: 4),
                      Text(
                        widget.label,
                        style: const TextStyle(
                          color:      FretixColors.textSecondary,
                          fontSize:   14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Pulgar deslizable
              Positioned(
                left: 4 + (_posicion * anchoMax),
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    if (_completado) return;
                    setState(() {
                      _posicion = ((_posicion * anchoMax + details.delta.dx) / anchoMax)
                          .clamp(0.0, 1.0);
                    });
                  },
                  onHorizontalDragEnd: (_) {
                    if (_posicion >= _umbralExito) {
                      setState(() => _completado = true);
                      widget.onSlide();
                    } else {
                      // Spring back al inicio
                      setState(() => _posicion = 0);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width:  _anchoPulgar,
                    height: _anchoPulgar,
                    decoration: BoxDecoration(
                      color:     _completado ? FretixColors.success : FretixColors.accent,
                      shape:     BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color:      FretixColors.accent.withOpacity(0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      _completado ? Icons.check_rounded : Icons.local_shipping_rounded,
                      color: Colors.black,
                      size:  24,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
```

---

## 7. WIDGETS AUXILIARES DE `OfertaViajeScreen`

```dart
// lib/widgets/oferta_widgets.dart

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../theme/fretix_colors.dart';

// ── Mini mapa con marcadores de origen y destino ─────────────────────────────

class _MiniMapaRuta extends StatelessWidget {
  final LatLng? origin;
  final LatLng? destination;
  final void Function(GoogleMapController) onMapCreated;

  const _MiniMapaRuta({
    required this.origin,
    required this.destination,
    required this.onMapCreated,
  });

  @override
  Widget build(BuildContext context) {
    if (origin == null || destination == null) {
      return Container(
        color: FretixColors.surface,
        child: const Center(
          child: Icon(Icons.map_outlined, color: FretixColors.textMuted, size: 48),
        ),
      );
    }

    final markers = {
      Marker(
        markerId:   const MarkerId('origen'),
        position:   origin!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: const InfoWindow(title: 'Origen de carga'),
      ),
      Marker(
        markerId:   const MarkerId('destino'),
        position:   destination!,
        infoWindow: const InfoWindow(title: 'Destino de entrega'),
      ),
    };

    // Centrar el mapa entre origen y destino
    final centerLat = (origin!.latitude  + destination!.latitude)  / 2;
    final centerLng = (origin!.longitude + destination!.longitude) / 2;

    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(centerLat, centerLng),
        zoom:   12,
      ),
      markers:         markers,
      onMapCreated:    onMapCreated,
      zoomControlsEnabled:    false,
      myLocationButtonEnabled: false,
      liteModeEnabled:         true,   // Mapa estático liviano, sin scroll
    );
  }
}

// ── Fila de ruta origen → destino ───────────────────────────────────────────

class _RutaRow extends StatelessWidget {
  final String origen;
  final String destino;
  const _RutaRow({required this.origen, required this.destino});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Column(
          children: [
            const Icon(Icons.circle, color: FretixColors.accent, size: 10),
            Container(width: 1.5, height: 32, color: FretixColors.surfaceBorder),
            const Icon(Icons.location_on, color: FretixColors.textSecondary, size: 14),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(origen, style: const TextStyle(
                color: FretixColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500,
              ), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 20),
              Text(destino, style: const TextStyle(
                color: FretixColors.textSecondary, fontSize: 13,
              ), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Chip de métrica (distancia, tiempo, ayudante) ───────────────────────────

class _MetricaChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final bool     highlighted;
  const _MetricaChip({required this.icon, required this.label, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:        highlighted
            ? FretixColors.accent.withOpacity(0.15)
            : FretixColors.background,
        borderRadius: FretixRadius.chip,
        border: Border.all(
          color: highlighted ? FretixColors.accent.withOpacity(0.4) : FretixColors.surfaceBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: highlighted ? FretixColors.accent : FretixColors.textSecondary, size: 14),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
            color:      highlighted ? FretixColors.accent : FretixColors.textSecondary,
            fontSize:   12,
            fontWeight: FontWeight.w500,
          )),
        ],
      ),
    );
  }
}

// ── Chip de categoría ───────────────────────────────────────────────────────

class _CategoriaChip extends StatelessWidget {
  final String categoria;
  const _CategoriaChip({required this.categoria});

  static const _labels = {
    'mini':  'Flete Mini',
    'plus':  'Flete Plus',
    'max':   'Flete Max',
    'heavy': 'Carga Pesada',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        FretixColors.accent.withOpacity(0.15),
        borderRadius: FretixRadius.chip,
      ),
      child: Text(
        _labels[categoria] ?? categoria,
        style: const TextStyle(
          color: FretixColors.accent, fontSize: 11, fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
```

---

## 8. PANTALLA 2 — `TripControlScreen` (Vista Chofer)

### Archivo
`lib/screens/chofer/trip_control_screen.dart`

### Máquina de estados del botón principal

| Estado en Firestore | Texto del botón | Color | Cloud Function |
|---|---|---|---|
| `assigned` | "Llegué al Origen" | Azul `#3B82F6` | `llegueAlOrigenFretix` |
| `en_origen` | "Iniciar Carga / Tránsito" | Naranja `#F5A623` | `iniciarCargaFretix` |
| `in_progress` | "Finalizar Entrega" | Verde `#22C55E` | `finalizarViajeFretix` |
| `completed` | (navega a RatingScreen) | — | — |

```dart
// lib/screens/chofer/trip_control_screen.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/trip_service.dart';
import '../../theme/fretix_colors.dart';

class TripControlScreen extends StatefulWidget {
  final String tripId;
  const TripControlScreen({super.key, required this.tripId});

  @override
  State<TripControlScreen> createState() => _TripControlScreenState();
}

class _TripControlScreenState extends State<TripControlScreen> {
  bool _procesando = false;
  GoogleMapController? _mapController;
  LatLng? _choferPosition;

  // ── Config del botón según el estado del viaje ───────────────────────────
  _EstadoBoton _configBoton(String estado) {
    switch (estado) {
      case 'assigned':
        return _EstadoBoton(
          label:  'Llegué al Origen',
          color:  const Color(0xFF3B82F6),
          icon:   Icons.flag_rounded,
          accion: () => TripService.instance.llegueAlOrigen(widget.tripId),
        );
      case 'en_origen':
        return _EstadoBoton(
          label:  'Iniciar Carga / Tránsito',
          color:  FretixColors.accent,
          icon:   Icons.play_arrow_rounded,
          accion: () => TripService.instance.iniciarCarga(widget.tripId),
        );
      case 'in_progress':
        return _EstadoBoton(
          label:  'Finalizar Entrega',
          color:  FretixColors.success,
          icon:   Icons.check_circle_rounded,
          accion: () => _confirmarFinalizacion(),
        );
      default:
        return _EstadoBoton(
          label:  'Procesando...',
          color:  FretixColors.textMuted,
          icon:   Icons.hourglass_bottom_rounded,
          accion: null,
        );
    }
  }

  Future<void> _ejecutarAccion(_EstadoBoton config) async {
    if (_procesando || config.accion == null) return;
    setState(() => _procesando = true);
    try {
      await config.accion!();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: FretixColors.danger),
      );
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _confirmarFinalizacion() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: FretixColors.surface,
        title: const Text('¿Finalizar entrega?',
            style: TextStyle(color: FretixColors.textPrimary)),
        content: const Text(
          'Confirmá que la mercadería fue entregada en el destino.',
          style: TextStyle(color: FretixColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar',
                style: TextStyle(color: FretixColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: FretixColors.success),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    setState(() => _procesando = true);
    try {
      final resultado = await TripService.instance.finalizarViaje(widget.tripId);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        '/rating',
        arguments: {
          'tripId':         widget.tripId,
          'totalFinal':     resultado['totalFinal'],
          'costoEsperaExtra': resultado['costoEsperaExtra'],
          'rol':            'chofer',
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _procesando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al finalizar: $e'), backgroundColor: FretixColors.danger),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: TripService.instance.streamTrip(widget.tripId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            backgroundColor: FretixColors.background,
            body: Center(child: CircularProgressIndicator(color: FretixColors.accent)),
          );
        }

        final trip   = snapshot.data!.data() ?? {};
        final estado = trip['estado'] as String? ?? '';

        // Navegación automática al completarse el viaje (por el cliente o el sistema)
        if (estado == 'completed' || estado == 'cancelled') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (estado == 'completed') {
              Navigator.of(context).pushReplacementNamed('/rating',
                  arguments: {'tripId': widget.tripId, 'rol': 'chofer'});
            } else {
              Navigator.of(context).pop();
            }
          });
        }

        final config      = _configBoton(estado);
        final cliente     = trip['solicitadoPor']  as Map<String, dynamic>? ?? {};
        final ruta        = trip['ruta']            as Map<String, dynamic>? ?? {};
        final asignacion  = trip['asignacion']      as Map<String, dynamic>? ?? {};

        return Scaffold(
          backgroundColor: FretixColors.background,
          body: Stack(
            children: [
              // ── Mapa de fondo (ocupa 55% de la pantalla) ──────────────────
              _MapaNavegacion(
                trip:             trip,
                choferPosition:   _choferPosition,
                onMapCreated:     (ctrl) => _mapController = ctrl,
              ),

              // ── Panel inferior deslizable ──────────────────────────────────
              DraggableScrollableSheet(
                initialChildSize: 0.45,
                minChildSize:     0.35,
                maxChildSize:     0.75,
                builder: (_, controller) => _buildPanelInferior(
                  scrollCtrl: controller,
                  trip:       trip,
                  estado:     estado,
                  config:     config,
                  cliente:    cliente,
                  ruta:       ruta,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPanelInferior({
    required ScrollController  scrollCtrl,
    required Map<String, dynamic> trip,
    required String               estado,
    required _EstadoBoton         config,
    required Map<String, dynamic> cliente,
    required Map<String, dynamic> ruta,
  }) {
    return Container(
      decoration: const BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: ListView(
        controller:  scrollCtrl,
        padding:     const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          // Handle de drag
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color:        FretixColors.surfaceBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Indicador de estado actual
          _EstadoIndicador(estado: estado),
          const SizedBox(height: 20),

          // Datos del cliente
          _InfoCard(
            title: 'Cliente',
            children: [
              _InfoRow(icon: Icons.person_outline_rounded,
                  label: cliente['displayName'] as String? ?? 'Cliente'),
              _InfoRow(icon: Icons.phone_outlined,
                  label: cliente['phone']       as String? ?? ''),
              if (cliente['companyId'] != null)
                const _InfoRow(icon: Icons.business_rounded, label: 'Cuenta empresa'),
            ],
          ),
          const SizedBox(height: 12),

          // Ruta
          _InfoCard(
            title: 'Ruta',
            children: [
              _InfoRow(
                icon:  Icons.circle,
                label: ruta['origen']?['direccion'] as String? ?? '',
                color: FretixColors.accent,
              ),
              _InfoRow(
                icon:  Icons.location_on_rounded,
                label: ruta['destino']?['direccion'] as String? ?? '',
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Botón de acción principal
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: SizedBox(
              key:    ValueKey(estado),
              width:  double.infinity,
              height: 58,
              child: ElevatedButton.icon(
                onPressed: _procesando ? null : () => _ejecutarAccion(config),
                style: ElevatedButton.styleFrom(
                  backgroundColor: config.color,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: FretixColors.surfaceBorder,
                  shape: RoundedRectangleBorder(borderRadius: FretixRadius.button),
                  elevation: 0,
                ),
                icon: _procesando
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5),
                      )
                    : Icon(config.icon, size: 22),
                label: Text(
                  _procesando ? 'Procesando...' : config.label,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Modelo interno del botón de estado ──────────────────────────────────────

class _EstadoBoton {
  final String      label;
  final Color       color;
  final IconData    icon;
  final Future<void> Function()? accion;

  const _EstadoBoton({
    required this.label,
    required this.color,
    required this.icon,
    required this.accion,
  });
}

// ── Indicador visual del estado actual ──────────────────────────────────────

class _EstadoIndicador extends StatelessWidget {
  final String estado;
  const _EstadoIndicador({required this.estado});

  static const _config = {
    'assigned':    ('En camino al origen',   Icons.directions_car_rounded, Color(0xFF3B82F6)),
    'en_origen':   ('En el punto de carga',  Icons.inventory_2_rounded,    FretixColors.accent),
    'in_progress': ('En tránsito al destino',Icons.local_shipping_rounded, FretixColors.success),
  };

  @override
  Widget build(BuildContext context) {
    final cfg = _config[estado];
    if (cfg == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:        (cfg.$3 as Color).withOpacity(0.12),
        borderRadius: FretixRadius.chip,
        border:       Border.all(color: (cfg.$3 as Color).withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(cfg.$2 as IconData, color: cfg.$3 as Color, size: 16),
          const SizedBox(width: 8),
          Text(cfg.$1 as String,
              style: TextStyle(
                  color: cfg.$3 as Color, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Mapa de navegación ───────────────────────────────────────────────────────

class _MapaNavegacion extends StatelessWidget {
  final Map<String, dynamic>     trip;
  final LatLng?                  choferPosition;
  final void Function(GoogleMapController) onMapCreated;

  const _MapaNavegacion({
    required this.trip,
    required this.choferPosition,
    required this.onMapCreated,
  });

  @override
  Widget build(BuildContext context) {
    final rutaData  = trip['ruta'] as Map<String, dynamic>? ?? {};
    final originGeo = rutaData['origen']?['geoPoint'] as GeoPoint?;
    final destGeo   = rutaData['destino']?['geoPoint'] as GeoPoint?;

    final markers = <Marker>{};
    if (originGeo != null) {
      markers.add(Marker(
        markerId: const MarkerId('origen'),
        position: LatLng(originGeo.latitude, originGeo.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ));
    }
    if (destGeo != null) {
      markers.add(Marker(
        markerId: const MarkerId('destino'),
        position: LatLng(destGeo.latitude, destGeo.longitude),
      ));
    }

    final initialPosition = choferPosition
        ?? (originGeo != null ? LatLng(originGeo.latitude, originGeo.longitude) : null)
        ?? const LatLng(-32.9741, -68.8120);   // Mendoza capital como fallback

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.55,
      child: GoogleMap(
        initialCameraPosition: CameraPosition(target: initialPosition, zoom: 14),
        markers:                markers,
        onMapCreated:           onMapCreated,
        myLocationEnabled:      true,
        myLocationButtonEnabled: false,
        zoomControlsEnabled:    false,
      ),
    );
  }
}

// ── Widgets de info reutilizables ────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final String         title;
  final List<Widget>   children;
  const _InfoCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:     const EdgeInsets.all(14),
      decoration:  BoxDecoration(
        color:        FretixColors.background,
        borderRadius: FretixRadius.card,
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: const TextStyle(
                color: FretixColors.textMuted, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 1.2,
              )),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _InfoRow({required this.icon, required this.label,
      this.color = FretixColors.textSecondary});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(child: Text(label,
              style: const TextStyle(color: FretixColors.textPrimary, fontSize: 13),
              maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}
```

---

## 9. PANTALLA 3 — `TripTrackingScreen` (Vista Cliente)

### Archivo
`lib/screens/cliente/trip_tracking_screen.dart`

### Comportamiento
- Stream en `/trips/{tripId}` para el estado del viaje
- Stream en `/drivers/{driverId}` para la ubicación del chofer (actualización cada 5s)
- Animación suave del marcador del camión con `AnimatedMarker` via interpolación
- Card inferior con foto del chofer, patente, estado y ETA

```dart
// lib/screens/cliente/trip_tracking_screen.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../services/trip_service.dart';
import '../../theme/fretix_colors.dart';

class TripTrackingScreen extends StatefulWidget {
  final String tripId;
  const TripTrackingScreen({super.key, required this.tripId});

  @override
  State<TripTrackingScreen> createState() => _TripTrackingScreenState();
}

class _TripTrackingScreenState extends State<TripTrackingScreen> {
  GoogleMapController? _mapController;

  LatLng? _choferPosition;       // posición actual del marcador
  LatLng? _choferPositionTarget; // posición objetivo (para interpolación)
  Timer?  _animTimer;

  String? _driverIdActivo;

  @override
  void dispose() {
    _animTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // Interpolación suave entre posición actual y nueva posición del chofer.
  // Se llama cada vez que Firestore emite una nueva ubicación.
  void _animarChoferA(LatLng nuevaPosicion) {
    _animTimer?.cancel();
    final inicio = _choferPosition ?? nuevaPosicion;
    const pasos  = 30;
    int   step   = 0;

    _animTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      step++;
      final t = step / pasos;
      final interpolada = LatLng(
        inicio.latitude  + (nuevaPosicion.latitude  - inicio.latitude)  * t,
        inicio.longitude + (nuevaPosicion.longitude - inicio.longitude) * t,
      );
      if (mounted) setState(() => _choferPosition = interpolada);
      if (step >= pasos) {
        timer.cancel();
        _choferPosition = nuevaPosicion;
      }
    });
  }

  void _centrarEnChofer() {
    if (_choferPosition == null || _mapController == null) return;
    _mapController!.animateCamera(
      CameraUpdate.newLatLng(_choferPosition!),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: TripService.instance.streamTrip(widget.tripId),
      builder: (context, tripSnap) {
        if (!tripSnap.hasData) {
          return const Scaffold(
            backgroundColor: FretixColors.background,
            body: Center(child: CircularProgressIndicator(color: FretixColors.accent)),
          );
        }

        final trip        = tripSnap.data!.data() ?? {};
        final estado      = trip['estado']    as String? ?? '';
        final asignacion  = trip['asignacion'] as Map<String, dynamic>? ?? {};
        final driverId    = asignacion['driverId'] as String?;

        // Navegación automática al completarse
        if (estado == 'completed') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.of(context).pushReplacementNamed('/rating',
                arguments: {'tripId': widget.tripId, 'rol': 'cliente'});
          });
        }

        _driverIdActivo = driverId;

        return Scaffold(
          backgroundColor: FretixColors.background,
          body: Stack(
            children: [
              // ── Mapa en tiempo real ──────────────────────────────────────
              _buildMapa(trip, driverId),

              // ── Botón centrar ────────────────────────────────────────────
              Positioned(
                top:   56,
                right: 16,
                child: _BotonCentrar(onTap: _centrarEnChofer),
              ),

              // ── Card inferior del chofer ─────────────────────────────────
              Positioned(
                left: 0, right: 0, bottom: 0,
                child: _buildCardChofer(trip, asignacion, estado, driverId),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMapa(Map<String, dynamic> trip, String? driverId) {
    final rutaData  = trip['ruta']   as Map<String, dynamic>? ?? {};
    final originGeo = rutaData['origen']?['geoPoint']  as GeoPoint?;
    final destGeo   = rutaData['destino']?['geoPoint'] as GeoPoint?;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: driverId != null
          ? TripService.instance.streamUbicacionChofer(driverId)
          : const Stream.empty(),
      builder: (context, driverSnap) {
        if (driverSnap.hasData && driverSnap.data!.exists) {
          final driverData = driverSnap.data!.data() ?? {};
          final geo        = driverData['lastLocation'] as GeoPoint?;
          if (geo != null) {
            final nueva = LatLng(geo.latitude, geo.longitude);
            if (nueva != _choferPositionTarget) {
              _choferPositionTarget = nueva;
              WidgetsBinding.instance.addPostFrameCallback((_) => _animarChoferA(nueva));
            }
          }
        }

        final markers = <Marker>{};

        if (originGeo != null) {
          markers.add(Marker(
            markerId: const MarkerId('origen'),
            position: LatLng(originGeo.latitude, originGeo.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
            infoWindow: const InfoWindow(title: 'Punto de carga'),
          ));
        }

        if (destGeo != null) {
          markers.add(Marker(
            markerId: const MarkerId('destino'),
            position: LatLng(destGeo.latitude, destGeo.longitude),
            infoWindow: const InfoWindow(title: 'Destino de entrega'),
          ));
        }

        if (_choferPosition != null) {
          markers.add(Marker(
            markerId:  const MarkerId('chofer'),
            position:  _choferPosition!,
            // En producción: reemplazar con BitmapDescriptor.fromAsset para
            // usar el ícono del camión de Fretix.
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            infoWindow: const InfoWindow(title: 'Tu chofer'),
          ));
        }

        final initialPos = _choferPosition
            ?? (originGeo != null ? LatLng(originGeo.latitude, originGeo.longitude) : null)
            ?? const LatLng(-32.9147, -68.8392);

        return GoogleMap(
          initialCameraPosition: CameraPosition(target: initialPos, zoom: 14),
          markers:               markers,
          onMapCreated:          (ctrl) {
            _mapController = ctrl;
            // Estilo de mapa oscuro para consistencia con la paleta de Fretix
            ctrl.setMapStyle(_mapStyleNocturno);
          },
          myLocationButtonEnabled: false,
          zoomControlsEnabled:    false,
        );
      },
    );
  }

  Widget _buildCardChofer(
    Map<String, dynamic> trip,
    Map<String, dynamic> asignacion,
    String               estado,
    String?              driverId,
  ) {
    final ruta          = trip['ruta']    as Map<String, dynamic>? ?? {};
    final distanciaKm   = trip['distanciaKm'] as num? ?? 0;
    final etaMin        = trip['duracionMin'] as num? ?? 0;

    final nombreChofer  = asignacion['displayName'] as String? ?? 'Tu chofer';
    final patente       = asignacion['vehicleId']   as String? ?? '';

    return Container(
      decoration: const BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(color: Colors.black54, blurRadius: 20, spreadRadius: 4),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: FretixColors.surfaceBorder, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),

          // Estado actual del viaje
          _BannerEstado(estado: estado),
          const SizedBox(height: 16),

          // Info del chofer
          Row(
            children: [
              // Avatar
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: FretixColors.surfaceBorder,
                ),
                child: const Icon(Icons.person_rounded,
                    color: FretixColors.textSecondary, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombreChofer,
                        style: const TextStyle(
                          color: FretixColors.textPrimary,
                          fontSize: 16, fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _PatenteChip(patente: patente),
                        const SizedBox(width: 8),
                        // Verificado
                        const Row(
                          children: [
                            Icon(Icons.verified_rounded,
                                color: FretixColors.success, size: 14),
                            SizedBox(width: 3),
                            Text('Verificado',
                                style: TextStyle(
                                    color: FretixColors.success, fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ETA
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('ETA',
                      style: const TextStyle(
                          color: FretixColors.textMuted, fontSize: 11)),
                  Text('~$etaMin min',
                      style: const TextStyle(
                        color: FretixColors.textPrimary,
                        fontSize: 18, fontWeight: FontWeight.w700,
                      )),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Destino
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color:        FretixColors.background,
              borderRadius: FretixRadius.card,
              border:       Border.all(color: FretixColors.surfaceBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on_rounded,
                    color: FretixColors.accent, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ruta['destino']?['direccion'] as String? ?? '',
                    style: const TextStyle(
                        color: FretixColors.textSecondary, fontSize: 13),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
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

// ── Banner de estado del viaje (vista cliente) ───────────────────────────────

class _BannerEstado extends StatelessWidget {
  final String estado;
  const _BannerEstado({required this.estado});

  static const _config = {
    'confirmed':   ('Buscando tu chofer...',     FretixColors.accent,  Icons.search_rounded),
    'assigned':    ('Tu chofer está en camino',  Color(0xFF3B82F6),    Icons.directions_car_rounded),
    'en_origen':   ('El chofer llegó al origen', FretixColors.accent,  Icons.inventory_2_rounded),
    'in_progress': ('Tu carga está en tránsito', FretixColors.success, Icons.local_shipping_rounded),
    'completed':   ('¡Entrega completada!',       FretixColors.success, Icons.check_circle_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final cfg   = _config[estado] ?? _config['assigned']!;
    final color = cfg.$2 as Color;
    final icon  = cfg.$3 as IconData;
    final label = cfg.$1 as String;

    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.12),
        borderRadius: FretixRadius.chip,
        border:       Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Chip de patente del vehículo ─────────────────────────────────────────────

class _PatenteChip extends StatelessWidget {
  final String patente;
  const _PatenteChip({required this.patente});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        FretixColors.background,
        borderRadius: FretixRadius.chip,
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Text(
        patente.toUpperCase(),
        style: const TextStyle(
          color: FretixColors.textPrimary, fontSize: 11,
          fontWeight: FontWeight.w700, letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// ── Botón de centrar mapa ────────────────────────────────────────────────────

class _BotonCentrar extends StatelessWidget {
  final VoidCallback onTap;
  const _BotonCentrar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color:     FretixColors.surface,
          shape:     BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 8)],
        ),
        child: const Icon(Icons.my_location_rounded,
            color: FretixColors.textSecondary, size: 20),
      ),
    );
  }
}

// ── Estilo de mapa oscuro (JSON para GoogleMap.setMapStyle) ─────────────────
const _mapStyleNocturno = '''
[
  {"elementType": "geometry",           "stylers": [{"color": "#1d2c4d"}]},
  {"elementType": "labels.text.fill",   "stylers": [{"color": "#8ec3b9"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#1a3646"}]},
  {"featureType": "road",               "elementType": "geometry", "stylers": [{"color": "#304a7d"}]},
  {"featureType": "road",               "elementType": "labels.text.fill", "stylers": [{"color": "#98a5be"}]},
  {"featureType": "water",              "elementType": "geometry", "stylers": [{"color": "#0e1626"}]}
]
''';
```

---

## 10. MANEJO DE FCM EN FLUTTER (Foreground / Background)

```dart
// lib/services/fcm_service.dart
// Configura los handlers de FCM para navegar a la pantalla correcta
// cuando llega una notificación.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  // Referencia al NavigatorKey para navegar fuera del contexto de widgets
  static final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> init() async {
    final messaging = FirebaseMessaging.instance;

    // Solicitar permiso en iOS
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    // Handler: app en foreground
    FirebaseMessaging.onMessage.listen(_onMensajeEnForeground);

    // Handler: app en background o cerrada, usuario tocó la notificación
    FirebaseMessaging.onMessageOpenedApp.listen(_navegarDesdeNotificacion);

    // Handler: app estaba cerrada y se abre desde la notificación
    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) _navegarDesdeNotificacion(initialMessage);
  }

  void _onMensajeEnForeground(RemoteMessage message) {
    final data  = message.data;
    final screen = data['screen'] as String?;

    // Si es una oferta de viaje entrante, mostrar OfertaViajeScreen como overlay
    if (screen == 'oferta_viaje') {
      final tripId = data['tripId'] as String?;
      navigatorKey.currentState?.pushNamed('/chofer/oferta', arguments: tripId);
    }
    // Para otras notificaciones en foreground: mostrar SnackBar o in-app notification
  }

  void _navegarDesdeNotificacion(RemoteMessage message) {
    final data   = message.data;
    final screen = data['screen'] as String?;
    final tripId = data['tripId'] as String?;

    switch (screen) {
      case 'oferta_viaje':
        navigatorKey.currentState?.pushNamed('/chofer/oferta', arguments: tripId);
        break;
      case 'trip_tracking':
        navigatorKey.currentState?.pushNamed('/cliente/tracking', arguments: tripId);
        break;
      case 'trip_control':
        navigatorKey.currentState?.pushNamed('/chofer/trip_control', arguments: tripId);
        break;
      case 'rating':
        navigatorKey.currentState?.pushNamed('/rating',
            arguments: {'tripId': tripId, 'rol': data['rol']});
        break;
    }
  }
}

// Handler para notificaciones con app cerrada (debe ser top-level function)
@pragma('vm:entry-point')
Future<void> fcmBackgroundHandler(RemoteMessage message) async {
  // Solo procesar data payload — no mostrar UI aquí
  debugPrint('[FCM Background] ${message.data}');
}
```

---

## 11. TABLA DE RUTAS DE NAVEGACIÓN

```dart
// lib/app.dart (extracto del router)

MaterialApp(
  navigatorKey: FcmService.navigatorKey,
  routes: {
    '/chofer/oferta':       (ctx) => OfertaViajeScreen(
                                  tripId: ModalRoute.of(ctx)!.settings.arguments as String?),
    '/chofer/trip_control': (ctx) => TripControlScreen(
                                  tripId: ModalRoute.of(ctx)!.settings.arguments as String),
    '/cliente/tracking':    (ctx) => TripTrackingScreen(
                                  tripId: ModalRoute.of(ctx)!.settings.arguments as String),
    '/rating':              (ctx) => RatingScreen(
                                  args: ModalRoute.of(ctx)!.settings.arguments as Map),
  },
)
```

---

## 12. ARCHIVOS DEL MÓDULO

| Archivo | Tipo | Estado |
|---|---|---|
| `lib/theme/fretix_colors.dart` | Dart | ✅ |
| `lib/services/trip_service.dart` | Dart | ✅ |
| `lib/services/fcm_service.dart` | Dart | ✅ |
| `lib/widgets/fretix_slider_button.dart` | Dart | ✅ |
| `lib/widgets/oferta_widgets.dart` | Dart | ✅ |
| `lib/screens/chofer/oferta_viaje_screen.dart` | Dart | ✅ |
| `lib/screens/chofer/trip_control_screen.dart` | Dart | ✅ |
| `lib/screens/cliente/trip_tracking_screen.dart` | Dart | ✅ |
| `lib/screens/shared/rating_screen.dart` | Dart | Pendiente — Módulo 6 |

### Dependencias Flutter requeridas (`pubspec.yaml`)

```yaml
dependencies:
  google_maps_flutter:   ^2.x
  geolocator:            ^10.x
  flutter_polyline_points: ^2.x
  firebase_messaging:    ^14.x
  cloud_firestore:       ^4.x
  cloud_functions:       ^4.x
```

---

## 13. DECISIONES DE ARQUITECTURA REGISTRADAS

| Decisión | Razonamiento |
|---|---|
| `liteModeEnabled: true` en el mini mapa de la oferta | El chofer puede recibir la oferta con conectividad limitada. El modo lite carga más rápido y no requiere tiles interactivos en esa pantalla |
| Slider en lugar de botón para aceptar | Evita aceptaciones accidentales por toques involuntarios. Crítico porque aceptar es una acción irreversible que bloquea al chofer |
| Interpolación de marcador con `Timer` | `google_maps_flutter` no tiene animación nativa de marcadores. La interpolación de 30 pasos en 480ms produce un movimiento fluido sin sobrecargar el isolate |
| `DraggableScrollableSheet` en `TripControlScreen` | El mapa siempre visible en 55% superior da contexto geográfico mientras el chofer interactúa con los controles; el panel puede expandirse para ver más detalles |
| `AnimatedSwitcher` en el botón de estado | La transición animada entre textos de botón (Llegué / Iniciar / Finalizar) da feedback visual de que el estado cambió, sin navegación a otra pantalla |
| `navigatorKey` global en `FcmService` | Permite navegar desde el handler de FCM (que corre fuera del árbol de widgets) sin pasar el `BuildContext` hacia arriba |
| Estilo de mapa oscuro con JSON | Consistencia visual con la paleta `#0D0D0D` del resto de la app. El mapa blanco default rompería la experiencia premium |

---

## 14. PENDIENTES PARA MÓDULO 6 (Panel Web Admin + Calificaciones)

| Componente | Descripción |
|---|---|
| `RatingScreen` | Calificación bidireccional 1-5 estrellas post-viaje, comentario opcional, llamada a `calificarViajeFretix` |
| Panel Web Admin Flutter | Dashboard de métricas, editor de tarifas `/config`, gestión de choferes y documentación pendiente |
| `PhoneInputScreen` | Pantalla de ingreso del número telefónico con validación de prefijo +54 y selector de área |
| `OtpInputScreen` | 6 campos individuales, auto-focus, countdown de reenvío (60s) |
| Modo empresa (sub-usuario) | Pantalla de selección de empresa activa antes de pedir un flete |

---

*Documento de referencia técnica — Módulo 5 aprobado.*
*Adjuntar junto a los módulos anteriores para contexto completo de Fretix.*
