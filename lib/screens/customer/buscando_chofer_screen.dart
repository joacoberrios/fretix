import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

// Misma clave que web/index.html — ya pública en el HTML del proyecto.
// CPO-DP-05: verificar que esta clave tenga restricción de referrer HTTP
// en Google Cloud Console para evitar uso no autorizado.
const _kMapsApiKey = 'AIzaSyCPrygll6ye2BgPkP-wPSsTS7HoChs_lCw';

// Dark map style — mismo que cotizacion_screen.dart (spec CTO).
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
      final callable = FretixAuthService.instance.getCallable(
        'cancelarViajeFretix',
        timeout: const Duration(seconds: 15),
      );
      await callable.call({'viajeId': widget.viajeId});
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
          style: TextStyle(
            color: FretixColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700,
          ),
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
        if (snap.connectionState == ConnectionState.waiting) {
          return const _SearchingState();
        }
        if (snap.hasError || !snap.hasData || !snap.data!.exists) {
          return const _SearchingState();
        }

        final data   = snap.data!.data() as Map<String, dynamic>;
        final estado = data['estado'] as String? ?? 'pending';

        switch (estado) {
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
                ? LatLng(origenLat, origenLng)
                : null;
            return StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('viajes')
                  .doc(viajeId)
                  .collection('tracking')
                  .doc('actual')
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

          case 'en_curso':
            final choferData = data['choferData'] as Map<String, dynamic>?;
            final nombre     = choferData?['displayName'] as String? ?? 'Tu chofer';
            final origenMap2 = data['origen'] as Map<String, dynamic>?;
            final origenLat2 = (origenMap2?['lat'] as num?)?.toDouble();
            final origenLng2 = (origenMap2?['lng'] as num?)?.toDouble();
            final origenPos2 = (origenLat2 != null && origenLng2 != null)
                ? LatLng(origenLat2, origenLng2)
                : null;
            return StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('viajes')
                  .doc(viajeId)
                  .collection('tracking')
                  .doc('actual')
                  .snapshots(),
              builder: (context, trackSnap) {
                LatLng? choferPos;
                if (trackSnap.hasData && trackSnap.data!.exists) {
                  final td  = trackSnap.data!.data() as Map<String, dynamic>?;
                  final lat = (td?['lat'] as num?)?.toDouble();
                  final lng = (td?['lng'] as num?)?.toDouble();
                  if (lat != null && lng != null) choferPos = LatLng(lat, lng);
                }
                return _EnCursoView(
                  nombre:       nombre,
                  choferPos:    choferPos,
                  origenLatLng: origenPos2,
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
              icon:     Icons.check_circle_outline,
              color:    FretixColors.success,
              mensaje:  '¡Viaje completado!',
              detalle:  'Gracias por usar Fretix.',
            );

          case 'cancelado':
            Future.delayed(const Duration(seconds: 3), () {
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(context, AppRouter.homeCliente, (_) => false);
              }
            });
            return const _FinView(
              icon:     Icons.cancel_outlined,
              color:    FretixColors.danger,
              mensaje:  'Viaje cancelado',
              detalle:  'Podés pedir un nuevo viaje cuando quieras.',
            );

          default:
            // pending o estado desconocido
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
                  width:  16,
                  height: 16,
                  child:  CircularProgressIndicator(color: FretixColors.danger, strokeWidth: 2),
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

// ── Chofer asignado ───────────────────────────────────────────────────────────

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
  final int?    etaFallback;   // duracionMin de la cotización — usado si Directions API falla
  final bool         cancelando;
  final VoidCallback onCancelar;
  final LatLng? choferPos;
  final LatLng? origenLatLng;

  @override
  State<_ChoferAsignadoView> createState() => _ChoferAsignadoViewState();
}

class _ChoferAsignadoViewState extends State<_ChoferAsignadoView> {
  GoogleMapController? _mapController;
  int? _etaCalculado;   // minutos calculados por Directions API
  bool _etaLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.choferPos != null) _recalcularEta();
  }

  @override
  void didUpdateWidget(covariant _ChoferAsignadoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Recalcula ETA solo cuando la posición del chofer cambia (valor distinto).
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
          final leg      = ((routes.first as Map)['legs'] as List?)?.first as Map?;
          final durSecs  = (leg?['duration']?['value'] as num?)?.toInt();
          if (durSecs != null) {
            setState(() { _etaCalculado = (durSecs / 60).ceil(); _etaLoading = false; });
            return;
          }
        }
      }
    } catch (_) {
      // Fallback al duracionMin — no bloqueante.
    }
    if (mounted) setState(() => _etaLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final etaDisplay = _etaCalculado ?? widget.etaFallback;
    final etaEsReal  = _etaCalculado != null;

    return Column(
      children: [
        // Mapa en tiempo real — solo cuando hay posición del chofer Y coords de origen.
        if (widget.origenLatLng != null)
          SizedBox(
            height: 200,
            child: _MapaCliente(
              origenPos:    widget.origenLatLng!,
              choferPos:    widget.choferPos,
              onMapCreated: (ctrl) async {
                _mapController = ctrl;
                await ctrl.setMapStyle(_kMapStyleNocturno);
              },
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 24),
                  Container(
                    width:  96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: FretixColors.surface,
                      border: Border.all(color: FretixColors.accent, width: 2),
                    ),
                    child: widget.photoURL != null
                        ? ClipOval(
                            child: Image.network(
                              widget.photoURL!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _DefaultAvatar(nombre: widget.nombre),
                            ),
                          )
                        : _DefaultAvatar(nombre: widget.nombre),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '¡Chofer en camino!',
                    style: TextStyle(
                      color:      FretixColors.success,
                      fontSize:   22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.nombre,
                    style: const TextStyle(
                      color:      FretixColors.textPrimary,
                      fontSize:   18,
                      fontWeight: FontWeight.w600,
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
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color:        FretixColors.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.schedule_outlined, color: FretixColors.accent, size: 18),
                          const SizedBox(width: 8),
                          if (_etaLoading)
                            const SizedBox(
                              width:  14, height: 14,
                              child:  CircularProgressIndicator(color: FretixColors.accent, strokeWidth: 2),
                            )
                          else
                            Text(
                              etaEsReal
                                  ? 'ETA: $etaDisplay min'
                                  : 'ETA estimada: $etaDisplay min',
                              style: const TextStyle(color: FretixColors.textSecondary, fontSize: 14),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Quedá en el punto de origen para que el chofer pueda encontrarte.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color:    FretixColors.textSecondary,
                        fontSize: 13,
                        height:   1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: widget.cancelando ? null : widget.onCancelar,
                    child: widget.cancelando
                        ? const SizedBox(
                            width:  16,
                            height: 16,
                            child:  CircularProgressIndicator(color: FretixColors.danger, strokeWidth: 2),
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

// ── En curso ──────────────────────────────────────────────────────────────────

class _EnCursoView extends StatefulWidget {
  const _EnCursoView({required this.nombre, this.choferPos, this.origenLatLng});
  final String  nombre;
  final LatLng? choferPos;
  final LatLng? origenLatLng;

  @override
  State<_EnCursoView> createState() => _EnCursoViewState();
}

class _EnCursoViewState extends State<_EnCursoView> {
  GoogleMapController? _mapController;

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.origenLatLng != null)
          SizedBox(
            height: 200,
            child: _MapaCliente(
              origenPos:    widget.origenLatLng!,
              choferPos:    widget.choferPos,
              onMapCreated: (ctrl) async {
                _mapController = ctrl;
                await ctrl.setMapStyle(_kMapStyleNocturno);
              },
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width:  80,
                  height: 80,
                  decoration: BoxDecoration(
                    color:  FretixColors.success.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.local_shipping_rounded, color: FretixColors.success, size: 40),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Viaje en curso',
                  style: TextStyle(
                    color:      FretixColors.success,
                    fontSize:   22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${widget.nombre} está llevando tu carga',
                  style: const TextStyle(
                    color:    FretixColors.textSecondary,
                    fontSize: 14,
                    height:   1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
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

// ── Mapa del cliente (origen + posición del chofer) ───────────────────────────

class _MapaCliente extends StatelessWidget {
  const _MapaCliente({
    required this.origenPos,
    this.choferPos,
    required this.onMapCreated,
  });

  final LatLng  origenPos;
  final LatLng? choferPos;
  final void Function(GoogleMapController) onMapCreated;

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('origen'),
        position: origenPos,
        icon:     BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ),
      if (choferPos != null)
        Marker(
          markerId: const MarkerId('chofer'),
          position: choferPos!,
          icon:     BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        ),
    };

    final target = choferPos ?? origenPos;

    return GoogleMap(
      initialCameraPosition:   CameraPosition(target: target, zoom: 13),
      markers:                 markers,
      onMapCreated:            onMapCreated,
      myLocationButtonEnabled: false,
      zoomControlsEnabled:     false,
      mapToolbarEnabled:       false,
      compassEnabled:          false,
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
          style: TextStyle(
            color:      color,
            fontSize:   22,
            fontWeight: FontWeight.w700,
          ),
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
          color:      FretixColors.accent,
          fontSize:   36,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
