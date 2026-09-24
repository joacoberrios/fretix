import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

// Misma clave que web/index.html — ya pública en el HTML del proyecto.
const _kMapsApiKey = 'AIzaSyCPrygll6ye2BgPkP-wPSsTS7HoChs_lCw';

const _kMapStyleNocturno = r'''
[
  {"elementType":"geometry","stylers":[{"color":"#080f1c"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#2a3547"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#080f1c"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#080f1c"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"road.local","elementType":"geometry","stylers":[{"color":"#0d1829"}]},
  {"featureType":"road.local","elementType":"geometry.stroke","stylers":[{"color":"#080f1c"}]},
  {"featureType":"road.local","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#111d2e"}]},
  {"featureType":"road.arterial","elementType":"geometry.stroke","stylers":[{"color":"#080f1c"}]},
  {"featureType":"road.arterial","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#1a2d45"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#0d1829"}]},
  {"featureType":"road.highway","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#060c16"}]},
  {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#0d1829"}]},
  {"featureType":"administrative","elementType":"labels.text.fill","stylers":[{"color":"#2a3547"}]},
  {"featureType":"administrative","elementType":"labels.text.stroke","stylers":[{"color":"#080f1c"}]}
]
''';

class BuscandoChoferScreen extends StatefulWidget {
  const BuscandoChoferScreen({super.key, this.viajeId});

  final String? viajeId;

  @override
  State<BuscandoChoferScreen> createState() => _BuscandoChoferScreenState();
}

class _BuscandoChoferScreenState extends State<BuscandoChoferScreen> {
  bool _cancelando = false;

  Future<void> _cancelarViaje() async {
    if (_cancelando || widget.viajeId == null) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          '¿Cancelar el pedido?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'Si cancelás, el viaje se eliminará y tendrás que pedir uno nuevo.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Volver', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancelar pedido', style: TextStyle(color: FretixColors.danger)),
          ),
        ],
      ),
    );
    if (confirmar != true) return;

    setState(() => _cancelando = true);
    try {
      await FretixAuthService.instance.getCallable(
        'cancelarViajeFretix',
        timeout: const Duration(seconds: 15),
      ).call({'viajeId': widget.viajeId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:         Text('No se pudo cancelar el viaje. Intentá de nuevo.'),
        backgroundColor: FretixColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _cancelando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon:      const Icon(Icons.close_rounded, color: FretixColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: widget.viajeId == null
                  ? const _SearchingState()
                  : _ViajeWatcher(
                      viajeId:    widget.viajeId!,
                      cancelando: _cancelando,
                      onCancelar: _cancelarViaje,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Spinner genérico (sin viajeId — edge case) ────────────────────────────────

class _SearchingState extends StatelessWidget {
  const _SearchingState();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 56, height: 56,
          child: CircularProgressIndicator(color: FretixColors.accent, strokeWidth: 3),
        ),
        SizedBox(height: 32),
        Text(
          'Buscando chofer...',
          style: TextStyle(color: FretixColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 10),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            'Estamos conectándote con el chofer más cercano.\nEsto demora menos de un minuto.',
            textAlign: TextAlign.center,
            style: TextStyle(color: FretixColors.textSecondary, fontSize: 14, height: 1.6),
          ),
        ),
      ],
    );
  }
}

// ── StreamBuilder sobre /viajes/{viajeId} ─────────────────────────────────────

class _ViajeWatcher extends StatelessWidget {
  const _ViajeWatcher({
    required this.viajeId,
    required this.cancelando,
    required this.onCancelar,
  });

  final String       viajeId;
  final bool         cancelando;
  final VoidCallback onCancelar;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('viajes')
          .doc(viajeId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const _SearchingState();
        if (snap.hasError || !snap.hasData || !snap.data!.exists) return const _SearchingState();

        final data   = snap.data!.data() as Map<String, dynamic>;
        final estado = data['estado'] as String? ?? 'pending';

        switch (estado) {

          // ── Chofer en camino al origen ────────────────────────────────────
          case 'aceptado':
            final choferData   = data['choferData'] as Map<String, dynamic>?;
            final nombre       = choferData?['displayName']       as String? ?? 'Tu chofer';
            final photoURL     = choferData?['photoURL']          as String?;
            final categoria    = choferData?['categoriaVehiculo'] as String?;
            final duracion     = (data['cotizacion'] as Map<String, dynamic>?)?['duracionMin'] as num?;
            final origenMap    = data['origen'] as Map<String, dynamic>?;
            final origenLat    = (origenMap?['lat'] as num?)?.toDouble();
            final origenLng    = (origenMap?['lng'] as num?)?.toDouble();
            final origenLatLng = (origenLat != null && origenLng != null)
                ? LatLng(origenLat, origenLng) : null;
            return StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('viajes').doc(viajeId)
                  .collection('tracking').doc('actual')
                  .snapshots(),
              builder: (context, trackSnap) {
                LatLng? choferPos;
                if (trackSnap.hasData && trackSnap.data!.exists) {
                  final td  = trackSnap.data!.data() as Map<String, dynamic>?;
                  final lat = (td?['lat'] as num?)?.toDouble();
                  final lng = (td?['lng'] as num?)?.toDouble();
                  if (lat != null && lng != null) choferPos = LatLng(lat, lng);
                }
                return _ChoferAsignadoView(
                  nombre:       nombre,
                  photoURL:     photoURL,
                  categoria:    categoria,
                  etaFallback:  duracion?.round(),
                  cancelando:   cancelando,
                  onCancelar:   onCancelar,
                  choferPos:    choferPos,
                  origenLatLng: origenLatLng,
                );
              },
            );

          // ── Chofer en el origen, cargando ─────────────────────────────────
          case 'en_curso':
            final choferData = data['choferData'] as Map<String, dynamic>?;
            final nombre     = choferData?['displayName'] as String? ?? 'Tu chofer';
            return _CargandoEnOrigenView(nombre: nombre);

          // ── Chofer en camino al destino con la carga ──────────────────────
          case 'en_transito':
            final choferData = data['choferData'] as Map<String, dynamic>?;
            final nombre     = choferData?['displayName'] as String? ?? 'Tu chofer';
            final destinoMap = data['destino'] as Map<String, dynamic>?;
            final destinoLat = (destinoMap?['lat'] as num?)?.toDouble();
            final destinoLng = (destinoMap?['lng'] as num?)?.toDouble();
            final destinoPos = (destinoLat != null && destinoLng != null)
                ? LatLng(destinoLat, destinoLng) : null;
            return StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('viajes').doc(viajeId)
                  .collection('tracking').doc('actual')
                  .snapshots(),
              builder: (context, trackSnap) {
                LatLng? choferPos;
                if (trackSnap.hasData && trackSnap.data!.exists) {
                  final td  = trackSnap.data!.data() as Map<String, dynamic>?;
                  final lat = (td?['lat'] as num?)?.toDouble();
                  final lng = (td?['lng'] as num?)?.toDouble();
                  if (lat != null && lng != null) choferPos = LatLng(lat, lng);
                }
                return _EnTransitoView(
                  nombre:        nombre,
                  choferPos:     choferPos,
                  destinoLatLng: destinoPos,
                );
              },
            );

          case 'completado':
            Future.delayed(const Duration(seconds: 3), () {
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(context, AppRouter.homeCliente, (_) => false);
              }
            });
            return const _FinView(
              icon:    Icons.check_circle_outline,
              color:   FretixColors.success,
              mensaje: '¡Viaje completado!',
              detalle: 'Gracias por usar Fretix.',
            );

          case 'cancelado':
            Future.delayed(const Duration(seconds: 3), () {
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(context, AppRouter.homeCliente, (_) => false);
              }
            });
            return const _FinView(
              icon:    Icons.cancel_outlined,
              color:   FretixColors.danger,
              mensaje: 'Viaje cancelado',
              detalle: 'Podés pedir un nuevo viaje cuando quieras.',
            );

          default:
            return _PendingView(cancelando: cancelando, onCancelar: onCancelar);
        }
      },
    );
  }
}

// ── Buscando / pending ────────────────────────────────────────────────────────

class _PendingView extends StatelessWidget {
  const _PendingView({required this.cancelando, required this.onCancelar});
  final bool         cancelando;
  final VoidCallback onCancelar;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 56, height: 56,
          child: CircularProgressIndicator(color: FretixColors.accent, strokeWidth: 3),
        ),
        const SizedBox(height: 32),
        const Text(
          'Buscando chofer...',
          style: TextStyle(
            color: FretixColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            'Estamos conectándote con el chofer más cercano.\nEsto demora menos de un minuto.',
            textAlign: TextAlign.center,
            style: TextStyle(color: FretixColors.textSecondary, fontSize: 14, height: 1.6),
          ),
        ),
        const SizedBox(height: 40),
        TextButton(
          onPressed: cancelando ? null : onCancelar,
          child: cancelando
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(color: FretixColors.danger, strokeWidth: 2),
                )
              : const Text(
                  'Cancelar pedido',
                  style: TextStyle(color: FretixColors.danger, fontSize: 14),
                ),
        ),
      ],
    );
  }
}

// ── Chofer en camino al origen (aceptado) ─────────────────────────────────────

class _ChoferAsignadoView extends StatefulWidget {
  const _ChoferAsignadoView({
    required this.nombre,
    this.photoURL,
    this.categoria,
    this.etaFallback,
    required this.cancelando,
    required this.onCancelar,
    this.choferPos,
    this.origenLatLng,
  });

  final String  nombre;
  final String? photoURL;
  final String? categoria;
  final int?    etaFallback;
  final bool         cancelando;
  final VoidCallback onCancelar;
  final LatLng? choferPos;
  final LatLng? origenLatLng;

  @override
  State<_ChoferAsignadoView> createState() => _ChoferAsignadoViewState();
}

class _ChoferAsignadoViewState extends State<_ChoferAsignadoView> {
  GoogleMapController? _mapController;
  int? _etaCalculado;
  bool _etaLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.choferPos != null) _recalcularEta();
  }

  @override
  void didUpdateWidget(covariant _ChoferAsignadoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.choferPos != oldWidget.choferPos && widget.choferPos != null) {
      _recalcularEta();
    }
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _recalcularEta() async {
    final chofer = widget.choferPos;
    final origen = widget.origenLatLng;
    if (chofer == null || origen == null) return;
    setState(() => _etaLoading = true);
    try {
      final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${chofer.latitude},${chofer.longitude}'
        '&destination=${origen.latitude},${origen.longitude}'
        '&mode=driving'
        '&key=$_kMapsApiKey',
      );
      final response = await http.get(uri);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final body   = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = body['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final leg     = ((routes.first as Map)['legs'] as List?)?.first as Map?;
          final durSecs = (leg?['duration']?['value'] as num?)?.toInt();
          if (durSecs != null) {
            setState(() { _etaCalculado = (durSecs / 60).ceil(); _etaLoading = false; });
            return;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _etaLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final etaDisplay = _etaCalculado ?? widget.etaFallback;
    final etaEsReal  = _etaCalculado != null;

    return Column(
      children: [
        if (widget.origenLatLng != null) ...[
          SizedBox(
            height: 200,
            child: _MapaCliente(
              referenciaPos: widget.origenLatLng!,
              choferPos:     widget.choferPos,
              onMapCreated:  (ctrl) {
                _mapController = ctrl;
              },
            ),
          ),
          // TAREA F: badge cuando el chofer aún no emitió posición GPS
          if (widget.choferPos == null) const _EsperandoUbicacionBadge(),
        ],
        Expanded(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 24),
                  _AvatarChofer(nombre: widget.nombre, photoURL: widget.photoURL),
                  const SizedBox(height: 24),
                  const Text(
                    '¡Chofer en camino a buscar tu carga!',
                    style: TextStyle(
                      color: FretixColors.success, fontSize: 20, fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.nombre,
                    style: const TextStyle(
                      color: FretixColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.categoria != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _etiquetaCategoria(widget.categoria!),
                      style: const TextStyle(color: FretixColors.textMuted, fontSize: 13),
                    ),
                  ],
                  if (etaDisplay != null || _etaLoading) ...[
                    const SizedBox(height: 16),
                    _EtaBadge(
                      eta:     etaDisplay,
                      loading: _etaLoading,
                      label:   etaEsReal ? 'ETA' : 'ETA estimada',
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Quedá en el punto de origen para que el chofer pueda encontrarte.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: FretixColors.textSecondary, fontSize: 13, height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: widget.cancelando ? null : widget.onCancelar,
                    child: widget.cancelando
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(color: FretixColors.danger, strokeWidth: 2),
                          )
                        : const Text(
                            'Cancelar pedido',
                            style: TextStyle(color: FretixColors.danger, fontSize: 13),
                          ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _etiquetaCategoria(String cat) {
    const nombres = {
      'utilitario':        'Utilitario',
      'pickup':            'Pickup',
      'pickup_estructura': 'Pickup con estructura',
      'camion_liviano':    'Camión liviano',
      'camion_frio':       'Camión frío',
      'camion_mediano':    'Camión mediano',
      'camion_mudanza':    'Camión mudanza',
    };
    return nombres[cat] ?? cat;
  }
}

// ── Chofer cargando en el origen (en_curso) ───────────────────────────────────

class _CargandoEnOrigenView extends StatelessWidget {
  const _CargandoEnOrigenView({required this.nombre});
  final String nombre;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: FretixColors.accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.inventory_2_outlined, color: FretixColors.accent, size: 40),
          ),
          const SizedBox(height: 24),
          const Text(
            'Cargando en origen',
            style: TextStyle(
              color: FretixColors.accent, fontSize: 22, fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$nombre está cargando tu mercadería',
            style: const TextStyle(
              color: FretixColors.textSecondary, fontSize: 14, height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Text(
            'En breve saldrá rumbo al destino.',
            style: TextStyle(color: FretixColors.textMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Chofer en camino al destino con la carga (en_transito) ───────────────────

class _EnTransitoView extends StatefulWidget {
  const _EnTransitoView({required this.nombre, this.choferPos, this.destinoLatLng});
  final String  nombre;
  final LatLng? choferPos;
  final LatLng? destinoLatLng;

  @override
  State<_EnTransitoView> createState() => _EnTransitoViewState();
}

class _EnTransitoViewState extends State<_EnTransitoView> {
  GoogleMapController? _mapController;
  int?  _etaCalculado;
  bool  _etaLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.choferPos != null) _recalcularEta();
  }

  @override
  void didUpdateWidget(covariant _EnTransitoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.choferPos != oldWidget.choferPos && widget.choferPos != null) {
      _recalcularEta();
    }
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _recalcularEta() async {
    final chofer  = widget.choferPos;
    final destino = widget.destinoLatLng;
    if (chofer == null || destino == null) return;
    setState(() => _etaLoading = true);
    try {
      final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${chofer.latitude},${chofer.longitude}'
        '&destination=${destino.latitude},${destino.longitude}'
        '&mode=driving'
        '&key=$_kMapsApiKey',
      );
      final response = await http.get(uri);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final body   = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = body['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final leg     = ((routes.first as Map)['legs'] as List?)?.first as Map?;
          final durSecs = (leg?['duration']?['value'] as num?)?.toInt();
          if (durSecs != null) {
            setState(() { _etaCalculado = (durSecs / 60).ceil(); _etaLoading = false; });
            return;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _etaLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.destinoLatLng != null) ...[
          SizedBox(
            height: 200,
            child: _MapaCliente(
              referenciaPos: widget.destinoLatLng!,
              choferPos:     widget.choferPos,
              onMapCreated:  (ctrl) {
                _mapController = ctrl;
              },
            ),
          ),
          if (widget.choferPos == null) const _EsperandoUbicacionBadge(),
        ],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 16),
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: FretixColors.success.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.local_shipping_rounded, color: FretixColors.success, size: 40),
                ),
                const SizedBox(height: 24),
                const Text(
                  'En camino a destino',
                  style: TextStyle(
                    color: FretixColors.success, fontSize: 22, fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.nombre} está llevando tu carga',
                  style: const TextStyle(
                    color: FretixColors.textSecondary, fontSize: 14, height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_etaCalculado != null || _etaLoading) ...[
                  const SizedBox(height: 16),
                  _EtaBadge(eta: _etaCalculado, loading: _etaLoading, label: 'ETA a destino'),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Te avisaremos cuando llegue a destino.',
                  style: TextStyle(color: FretixColors.textMuted, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Estado final (completado / cancelado) ─────────────────────────────────────

class _FinView extends StatelessWidget {
  const _FinView({
    required this.icon,
    required this.color,
    required this.mensaje,
    required this.detalle,
  });
  final IconData icon;
  final Color    color;
  final String   mensaje;
  final String   detalle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 64),
        const SizedBox(height: 16),
        Text(
          mensaje,
          style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            detalle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: FretixColors.textSecondary, fontSize: 14),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Redirigiendo...',
          style: TextStyle(color: FretixColors.textMuted, fontSize: 13),
        ),
      ],
    );
  }
}

// ── Mapa del cliente (punto de referencia + posición del chofer) ──────────────
// referenciaPos: origen en estado aceptado, destino en estado en_transito.

class _MapaCliente extends StatelessWidget {
  const _MapaCliente({
    required this.referenciaPos,
    this.choferPos,
    required this.onMapCreated,
  });

  final LatLng  referenciaPos;
  final LatLng? choferPos;
  final void Function(GoogleMapController) onMapCreated;

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('referencia'),
        position: referenciaPos,
        icon:     BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ),
      if (choferPos != null)
        Marker(
          markerId: const MarkerId('chofer'),
          position: choferPos!,
          icon:     BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
    };

    return GoogleMap(
      initialCameraPosition:   CameraPosition(target: choferPos ?? referenciaPos, zoom: 13),
      style:                   _kMapStyleNocturno,
      markers:                 markers,
      onMapCreated:            onMapCreated,
      myLocationButtonEnabled: false,
      zoomControlsEnabled:     false,
      mapToolbarEnabled:       false,
      compassEnabled:          false,
    );
  }
}

// ── Badge "Esperando ubicación" (TAREA F) ─────────────────────────────────────

class _EsperandoUbicacionBadge extends StatelessWidget {
  const _EsperandoUbicacionBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      color:   FretixColors.surface,
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 10, height: 10,
            child: CircularProgressIndicator(color: FretixColors.textMuted, strokeWidth: 1.5),
          ),
          SizedBox(width: 8),
          Text(
            'Esperando ubicación del chofer...',
            style: TextStyle(color: FretixColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ── Badge ETA ─────────────────────────────────────────────────────────────────

class _EtaBadge extends StatelessWidget {
  const _EtaBadge({required this.eta, required this.loading, required this.label});
  final int?   eta;
  final bool   loading;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule_outlined, color: FretixColors.accent, size: 18),
          const SizedBox(width: 8),
          if (loading)
            const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(color: FretixColors.accent, strokeWidth: 2),
            )
          else
            Text(
              '$label: $eta min',
              style: const TextStyle(color: FretixColors.textSecondary, fontSize: 14),
            ),
        ],
      ),
    );
  }
}

// ── Avatar del chofer ─────────────────────────────────────────────────────────

class _AvatarChofer extends StatelessWidget {
  const _AvatarChofer({required this.nombre, this.photoURL});
  final String  nombre;
  final String? photoURL;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96, height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: FretixColors.surface,
        border: Border.all(color: FretixColors.accent, width: 2),
      ),
      child: photoURL != null
          ? ClipOval(
              child: Image.network(
                photoURL!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _DefaultAvatar(nombre: nombre),
              ),
            )
          : _DefaultAvatar(nombre: nombre),
    );
  }
}

class _DefaultAvatar extends StatelessWidget {
  const _DefaultAvatar({required this.nombre});
  final String nombre;

  @override
  Widget build(BuildContext context) {
    final inicial = nombre.isNotEmpty ? nombre[0].toUpperCase() : '?';
    return Center(
      child: Text(
        inicial,
        style: const TextStyle(
          color: FretixColors.accent, fontSize: 36, fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
