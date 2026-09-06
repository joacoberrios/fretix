import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

// Misma clave que web/index.html y buscando_chofer_screen.dart.
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

class ViajeActivoScreen extends StatefulWidget {
  const ViajeActivoScreen({super.key, required this.viajeId});

  final String viajeId;

  @override
  State<ViajeActivoScreen> createState() => _ViajeActivoScreenState();
}

class _ViajeActivoScreenState extends State<ViajeActivoScreen> {
  bool _iniciando        = false;
  bool _confirmando      = false;
  bool _finalizando      = false;
  bool _cancelando       = false;

  // ── GPS tracking ────────────────────────────────────────────────────────────
  Position?                     _currentPosition;
  StreamSubscription<Position>? _positionSub;
  Timer?                        _trackingTimer;
  bool                          _locationDenied = false;
  GoogleMapController?          _mapController;

  // ── ETA del chofer (TAREA C) ─────────────────────────────────────────────
  // Target se actualiza desde el StreamBuilder cuando cambia estado/coords.
  LatLng? _etaTarget;
  int?    _etaCalculado;
  bool    _etaLoading = false;

  @override
  void initState() {
    super.initState();
    _startTracking();
  }

  @override
  void dispose() {
    _stopTracking();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _startTracking() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (mounted) setState(() => _locationDenied = true);
      return;
    }

    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy:       LocationAccuracy.high,
        distanceFilter: 50,
      ),
    ).listen((pos) {
      _currentPosition = pos;
      if (mounted) setState(() {});
      _writeTracking(pos.latitude, pos.longitude);
      _updateMapCamera(pos);
      // Recalcula ETA cuando el chofer se mueve y hay un destino conocido.
      if (_etaTarget != null) _recalcularEta();
    });

    _trackingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final pos = _currentPosition;
      if (pos != null) _writeTracking(pos.latitude, pos.longitude);
    });
  }

  void _stopTracking() {
    _positionSub?.cancel();
    _positionSub = null;
    _trackingTimer?.cancel();
    _trackingTimer = null;
  }

  Future<void> _writeTracking(double lat, double lng) async {
    try {
      await FirebaseFirestore.instance
          .collection('viajes')
          .doc(widget.viajeId)
          .collection('tracking')
          .doc('actual')
          .set({
        'lat':           lat,
        'lng':           lng,
        'actualizadoEn': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  void _updateMapCamera(Position pos) {
    _mapController?.animateCamera(
      CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
    );
  }

  // Actualiza el punto de referencia para ETA y recalcula si hay posición GPS.
  // Llamado desde el StreamBuilder cuando estado o coords cambian.
  void _maybeUpdateEtaTarget(LatLng? newTarget) {
    if (newTarget == _etaTarget) return;
    // addPostFrameCallback evita llamar setState() dentro de build().
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _etaTarget    = newTarget;
        _etaCalculado = null;   // invalida ETA anterior si el destino cambió
      });
      if (_currentPosition != null && newTarget != null) _recalcularEta();
    });
  }

  Future<void> _recalcularEta() async {
    final pos    = _currentPosition;
    final target = _etaTarget;
    if (pos == null || target == null) return;
    if (mounted) setState(() => _etaLoading = true);
    try {
      final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${pos.latitude},${pos.longitude}'
        '&destination=${target.latitude},${target.longitude}'
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
            if (mounted) setState(() { _etaCalculado = (durSecs / 60).ceil(); _etaLoading = false; });
            return;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _etaLoading = false);
  }

  Future<void> _iniciarViaje() async {
    if (_iniciando) return;
    setState(() => _iniciando = true);
    try {
      await FretixAuthService.instance.getCallable(
        'iniciarViajeFretix',
        timeout: const Duration(seconds: 15),
      ).call({'viajeId': widget.viajeId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_mensajeError(e)), backgroundColor: FretixColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _iniciando = false);
    }
  }

  Future<void> _confirmarCarga() async {
    if (_confirmando) return;
    setState(() => _confirmando = true);
    try {
      await FretixAuthService.instance.getCallable(
        'confirmarCargaFretix',
        timeout: const Duration(seconds: 15),
      ).call({'viajeId': widget.viajeId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_mensajeError(e)), backgroundColor: FretixColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
  }

  Future<void> _finalizarViaje() async {
    if (_finalizando) return;
    final confirmar = await _confirmarAccion(
      '¿Finalizar el viaje?',
      'Confirmá que ya entregaste la carga en destino.',
      'Finalizar',
    );
    if (!confirmar) return;
    setState(() => _finalizando = true);
    try {
      await FretixAuthService.instance.getCallable(
        'finalizarViajeFretix',
        timeout: const Duration(seconds: 15),
      ).call({'viajeId': widget.viajeId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_mensajeError(e)), backgroundColor: FretixColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _finalizando = false);
    }
  }

  Future<void> _cancelarViaje() async {
    if (_cancelando) return;
    final confirmar = await _confirmarAccion(
      '¿Cancelar el viaje?',
      'Esta acción no se puede deshacer.',
      'Cancelar viaje',
    );
    if (!confirmar) return;
    setState(() => _cancelando = true);
    try {
      await FretixAuthService.instance.getCallable(
        'cancelarViajeFretix',
        timeout: const Duration(seconds: 15),
      ).call({'viajeId': widget.viajeId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_mensajeError(e)), backgroundColor: FretixColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _cancelando = false);
    }
  }

  Future<bool> _confirmarAccion(String titulo, String cuerpo, String labelConfirmar) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title:   Text(titulo,  style: const TextStyle(color: Colors.white,   fontWeight: FontWeight.w600)),
        content: Text(cuerpo,  style: const TextStyle(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Volver', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(labelConfirmar, style: const TextStyle(color: FretixColors.danger)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  String _mensajeError(Object e) {
    final msg = e.toString();
    if (msg.contains('ya tenés un viaje activo'))  return 'Ya tenés un viaje activo.';
    if (msg.contains('no está disponible'))        return 'No estás disponible. Activá tu disponibilidad.';
    if (msg.contains('Solo el chofer asignado'))   return 'No podés realizar esta acción en este viaje.';
    if (msg.contains('no se puede cancelar'))      return 'No se puede cancelar un viaje en este estado.';
    return 'Error inesperado. Intentá de nuevo.';
  }

  void _volverAHome() {
    Navigator.pushNamedAndRemoveUntil(context, AppRouter.homeChofer, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('viajes')
              .doc(widget.viajeId)
              .snapshots(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: FretixColors.accent));
            }
            if (snap.hasError || !snap.hasData || !snap.data!.exists) {
              return _ErrorView(onVolver: _volverAHome);
            }

            final data   = snap.data!.data() as Map<String, dynamic>;
            final estado = data['estado'] as String? ?? 'pending';

            if (estado == 'completado' || estado == 'cancelado') {
              _stopTracking();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _volverAHome();
              });
              return _EstadoFinalView(estado: estado);
            }

            final clienteData   = data['clienteData']  as Map<String, dynamic>?;
            final origen        = data['origen']        as Map<String, dynamic>?;
            final destino       = data['destino']       as Map<String, dynamic>?;
            final clienteNombre = clienteData?['displayName'] as String? ?? 'Cliente';
            final clienteTel    = clienteData?['phone']        as String?;
            final origenAddr    = origen?['address']  as String? ?? '—';
            final destinoAddr   = destino?['address'] as String? ?? '—';

            final origenLat = (origen?['lat'] as num?)?.toDouble();
            final origenLng = (origen?['lng'] as num?)?.toDouble();
            final origenLatLng = (origenLat != null && origenLng != null)
                ? LatLng(origenLat, origenLng) : null;

            final destinoLat = (destino?['lat'] as num?)?.toDouble();
            final destinoLng = (destino?['lng'] as num?)?.toDouble();
            final destinoLatLng = (destinoLat != null && destinoLng != null)
                ? LatLng(destinoLat, destinoLng) : null;

            // Punto de referencia del ETA: origen en aceptado, destino en en_curso/en_transito.
            final etaTarget = estado == 'aceptado' ? origenLatLng : destinoLatLng;
            _maybeUpdateEtaTarget(etaTarget);

            final choferLatLng = _currentPosition != null
                ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
                : null;

            return Column(
              children: [
                _Header(estado: estado, viajeId: widget.viajeId),
                if (origenLatLng != null)
                  SizedBox(
                    height: 200,
                    child: _MapaChofer(
                      origenPos:    origenLatLng,
                      choferPos:    choferLatLng,
                      onMapCreated: (ctrl) async {
                        _mapController = ctrl;
                        await ctrl.setMapStyle(_kMapStyleNocturno);
                      },
                    ),
                  ),
                if (_locationDenied) const _UbicacionDenegadaBanner(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        _ClienteCard(nombre: clienteNombre, telefono: clienteTel),
                        const SizedBox(height: 16),
                        _RutaCard(origen: origenAddr, destino: destinoAddr),
                        // ETA del chofer (TAREA C)
                        if (_etaCalculado != null || _etaLoading) ...[
                          const SizedBox(height: 12),
                          _EtaChoferBadge(
                            estado:   estado,
                            eta:      _etaCalculado,
                            loading:  _etaLoading,
                          ),
                        ],
                        const SizedBox(height: 16),
                        _MensajeEstado(estado: estado),
                        const SizedBox(height: 24),
                        _Acciones(
                          estado:       estado,
                          iniciando:    _iniciando,
                          confirmando:  _confirmando,
                          finalizando:  _finalizando,
                          cancelando:   _cancelando,
                          onIniciar:    _iniciarViaje,
                          onConfirmar:  _confirmarCarga,
                          onFinalizar:  _finalizarViaje,
                          onCancelar:   _cancelarViaje,
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Header con estado ─────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.estado, required this.viajeId});
  final String estado;
  final String viajeId;

  static const _etiquetas = {
    'aceptado':    ('Viaje aceptado',  FretixColors.accent),
    'en_curso':    ('En origen',       FretixColors.accent),
    'en_transito': ('En tránsito',     FretixColors.success),
  };

  @override
  Widget build(BuildContext context) {
    final (etiqueta, color) = _etiquetas[estado] ?? ('Viaje', FretixColors.textMuted);

    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      color:   FretixColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FRETIX',
            style: TextStyle(
              color: FretixColors.accent, fontSize: 13,
              fontWeight: FontWeight.w700, letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding:    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:        color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border:       Border.all(color: color.withOpacity(0.4)),
                ),
                child: Text(
                  etiqueta,
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              const Spacer(),
              Text(
                '#${viajeId.substring(0, 6).toUpperCase()}',
                style: const TextStyle(color: FretixColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Mensaje contextual por estado ─────────────────────────────────────────────

class _MensajeEstado extends StatelessWidget {
  const _MensajeEstado({required this.estado});
  final String estado;

  @override
  Widget build(BuildContext context) {
    final String texto;
    switch (estado) {
      case 'aceptado':
        texto = 'Dirigite al punto de origen a buscar la carga.';
      case 'en_curso':
        texto = 'Confirmá cuando hayas cargado en el origen.';
      case 'en_transito':
        texto = 'En camino al destino con la carga.';
      default:
        return const SizedBox.shrink();
    }
    return Text(
      texto,
      style: const TextStyle(
        color: FretixColors.textSecondary, fontSize: 13, height: 1.5,
      ),
    );
  }
}

// ── Badge ETA del chofer ──────────────────────────────────────────────────────

class _EtaChoferBadge extends StatelessWidget {
  const _EtaChoferBadge({
    required this.estado,
    required this.eta,
    required this.loading,
  });
  final String estado;
  final int?   eta;
  final bool   loading;

  @override
  Widget build(BuildContext context) {
    final label = estado == 'aceptado' ? 'ETA al origen' : 'ETA al destino';
    return Container(
      padding:    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule_outlined, color: FretixColors.accent, size: 16),
          const SizedBox(width: 8),
          if (loading)
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(color: FretixColors.accent, strokeWidth: 2),
            )
          else
            Text(
              '$label: $eta min',
              style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13),
            ),
        ],
      ),
    );
  }
}

// ── Tarjeta del cliente ───────────────────────────────────────────────────────

class _ClienteCard extends StatelessWidget {
  const _ClienteCard({required this.nombre, this.telefono});
  final String  nombre;
  final String? telefono;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:    const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            decoration: const BoxDecoration(color: Color(0xFF2A2A2A), shape: BoxShape.circle),
            child: Center(
              child: Text(
                nombre.isNotEmpty ? nombre[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: FretixColors.accent, fontSize: 20, fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cliente', style: TextStyle(color: FretixColors.textMuted, fontSize: 11)),
                const SizedBox(height: 2),
                Text(nombre, style: const TextStyle(
                  color: FretixColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600,
                )),
                if (telefono != null && telefono!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(telefono!, style: const TextStyle(
                    color: FretixColors.textSecondary, fontSize: 13,
                  )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tarjeta de ruta ───────────────────────────────────────────────────────────

class _RutaCard extends StatelessWidget {
  const _RutaCard({required this.origen, required this.destino});
  final String origen;
  final String destino;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:    const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        children: [
          _DireccionRow(icon: Icons.circle, color: FretixColors.accent,
              label: 'Origen',  direccion: origen),
          Padding(
            padding: const EdgeInsets.only(left: 7),
            child: Container(width: 2, height: 20, color: FretixColors.surfaceBorder),
          ),
          _DireccionRow(icon: Icons.location_on_rounded, color: FretixColors.danger,
              label: 'Destino', direccion: destino),
        ],
      ),
    );
  }
}

class _DireccionRow extends StatelessWidget {
  const _DireccionRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.direccion,
  });
  final IconData icon;
  final Color    color;
  final String   label;
  final String   direccion;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: FretixColors.textMuted, fontSize: 11)),
              Text(direccion, style: const TextStyle(color: FretixColors.textPrimary, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Botones de acción (TAREA B) ───────────────────────────────────────────────

class _Acciones extends StatelessWidget {
  const _Acciones({
    required this.estado,
    required this.iniciando,
    required this.confirmando,
    required this.finalizando,
    required this.cancelando,
    required this.onIniciar,
    required this.onConfirmar,
    required this.onFinalizar,
    required this.onCancelar,
  });

  final String       estado;
  final bool         iniciando;
  final bool         confirmando;
  final bool         finalizando;
  final bool         cancelando;
  final VoidCallback onIniciar;
  final VoidCallback onConfirmar;
  final VoidCallback onFinalizar;
  final VoidCallback onCancelar;

  @override
  Widget build(BuildContext context) {
    switch (estado) {
      case 'aceptado':
        return Column(
          children: [
            _BotonPrimario(
              label:   'Llegué al origen',
              loading: iniciando,
              onTap:   onIniciar,
              color:   FretixColors.success,
            ),
            const SizedBox(height: 12),
            _BotonSecundario(
              label:   'Cancelar viaje',
              loading: cancelando,
              onTap:   onCancelar,
            ),
          ],
        );
      case 'en_curso':
        return _BotonPrimario(
          label:   'Confirmar carga recogida',
          loading: confirmando,
          onTap:   onConfirmar,
          color:   FretixColors.accent,
        );
      case 'en_transito':
        return _BotonPrimario(
          label:   'Finalizar viaje',
          loading: finalizando,
          onTap:   onFinalizar,
          color:   FretixColors.accent,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _BotonPrimario extends StatelessWidget {
  const _BotonPrimario({
    required this.label,
    required this.loading,
    required this.onTap,
    required this.color,
  });
  final String       label;
  final bool         loading;
  final VoidCallback onTap;
  final Color        color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width:  double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor:         color,
          foregroundColor:         Colors.black,
          disabledBackgroundColor: color.withOpacity(0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: loading
            ? const SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5),
              )
            : Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _BotonSecundario extends StatelessWidget {
  const _BotonSecundario({required this.label, required this.loading, required this.onTap});
  final String       label;
  final bool         loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width:  double.infinity,
      height: 48,
      child: OutlinedButton(
        onPressed: loading ? null : onTap,
        style: OutlinedButton.styleFrom(
          side:            const BorderSide(color: FretixColors.danger),
          foregroundColor: FretixColors.danger,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: loading
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(color: FretixColors.danger, strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ── Estado final (completado/cancelado) ───────────────────────────────────────

class _EstadoFinalView extends StatelessWidget {
  const _EstadoFinalView({required this.estado});
  final String estado;

  @override
  Widget build(BuildContext context) {
    final completado = estado == 'completado';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            completado ? Icons.check_circle_outline : Icons.cancel_outlined,
            color: completado ? FretixColors.success : FretixColors.danger,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            completado ? '¡Viaje completado!' : 'Viaje cancelado',
            style: TextStyle(
              color: completado ? FretixColors.success : FretixColors.danger,
              fontSize: 20, fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Volviendo al inicio...',
            style: TextStyle(color: FretixColors.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ── Mapa del chofer (origen + posición propia) ────────────────────────────────

class _MapaChofer extends StatelessWidget {
  const _MapaChofer({
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

    return GoogleMap(
      initialCameraPosition:   CameraPosition(target: choferPos ?? origenPos, zoom: 13),
      markers:                 markers,
      onMapCreated:            onMapCreated,
      myLocationButtonEnabled: false,
      zoomControlsEnabled:     false,
      mapToolbarEnabled:       false,
      compassEnabled:          false,
    );
  }
}

// ── Banner de ubicación denegada ──────────────────────────────────────────────

class _UbicacionDenegadaBanner extends StatelessWidget {
  const _UbicacionDenegadaBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      color:   FretixColors.danger.withOpacity(0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: const Row(
        children: [
          Icon(Icons.location_off_outlined, color: FretixColors.danger, size: 15),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Sin acceso a tu ubicación. El cliente no verá tu posición en el mapa.',
              style: TextStyle(color: FretixColors.danger, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Error view ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onVolver});
  final VoidCallback onVolver;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off_rounded, color: FretixColors.textMuted, size: 48),
          const SizedBox(height: 16),
          const Text('No se pudo cargar el viaje',
              style: TextStyle(color: FretixColors.textPrimary, fontSize: 16)),
          const SizedBox(height: 24),
          TextButton(
            onPressed: onVolver,
            child: const Text('Volver al inicio',
                style: TextStyle(color: FretixColors.accent)),
          ),
        ],
      ),
    );
  }
}
