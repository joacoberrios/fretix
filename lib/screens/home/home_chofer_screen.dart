import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

class HomeChoferScreen extends StatefulWidget {
  const HomeChoferScreen({super.key});

  @override
  State<HomeChoferScreen> createState() => _HomeChoferScreenState();
}

class _HomeChoferScreenState extends State<HomeChoferScreen> {
  bool    _disponible            = false;
  bool    _loadingDisponibilidad = true;
  bool    _toggling              = false;
  String? _categoriaVehiculo;

  // Estado del vehículo registrado del chofer (Tarjeta Verde)
  String? _estadoValidacion;   // null = sin vehículo registrado
  String? _motivoSubsanacion;  // solo presente si estadoValidacion == 'pendiente_subsanacion'

  // Tracks in-progress accept calls per viajeId to prevent double-tap.
  final Set<String> _aceptando = {};

  @override
  void initState() {
    super.initState();
    _cargarPerfil();
  }

  Future<void> _cargarPerfil() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _loadingDisponibilidad = false);
      return;
    }
    try {
      // Leer perfil del chofer y su vehículo en paralelo
      final results = await Future.wait([
        FirebaseFirestore.instance.collection('users').doc(uid).get(),
        FirebaseFirestore.instance
            .collection('vehiculos')
            .where('choferUid', isEqualTo: uid)
            .limit(1)
            .get(),
      ]);

      final userDoc     = results[0] as DocumentSnapshot;
      final vehiculoSnap = (results[1] as QuerySnapshot).docs;
      final userData    = userDoc.data() as Map<String, dynamic>?;
      final vehiculoData = vehiculoSnap.isNotEmpty
          ? vehiculoSnap.first.data() as Map<String, dynamic>
          : null;

      setState(() {
        _disponible            = userData?['disponibleParaViajes'] as bool? ?? false;
        _categoriaVehiculo     = userData?['categoriaVehiculo']   as String?;
        _estadoValidacion      = vehiculoData?['estadoValidacion'] as String?;
        _motivoSubsanacion     = vehiculoData?['motivoSubsanacion'] as String?;
        _loadingDisponibilidad = false;
      });
    } catch (_) {
      setState(() => _loadingDisponibilidad = false);
    }
  }

  Future<void> _aceptarViaje(String viajeId) async {
    if (_aceptando.contains(viajeId)) return;
    setState(() => _aceptando.add(viajeId));
    try {
      final callable = FretixAuthService.instance.getCallable(
        'aceptarViajeFretix',
        timeout: const Duration(seconds: 15),
      );
      await callable.call({'viajeId': viajeId});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:         Text('¡Viaje aceptado! Dirigite al punto de origen.'),
        backgroundColor: FretixColors.success,
      ));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('ya fue aceptado')
          ? 'Este viaje ya fue tomado por otro chofer.'
          : 'No se pudo aceptar el viaje. Intentá de nuevo.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:         Text(msg),
        backgroundColor: FretixColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _aceptando.remove(viajeId));
    }
  }

  Future<void> _onToggle(bool v) async {
    if (_toggling) return;
    setState(() { _disponible = v; _toggling = true; });

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() { _disponible = !v; _toggling = false; });
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'disponibleParaViajes': v});
      setState(() => _toggling = false);
    } catch (_) {
      if (!mounted) return;
      setState(() { _disponible = !v; _toggling = false; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No se pudo actualizar tu disponibilidad. Intentá de nuevo.'),
        backgroundColor: FretixColors.danger,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';

    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TopBar(phone: phone),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 24),
                    _DisponibilidadCard(
                      disponible: _disponible,
                      onToggle: (_loadingDisponibilidad || _toggling) ? null : _onToggle,
                    ),
                    if (_estadoValidacion == 'pendiente_subsanacion')
                      _SubsanacionBanner(motivo: _motivoSubsanacion),
                    const SizedBox(height: 32),
                    _SectionTitle('Resumen del día'),
                    const SizedBox(height: 16),
                    _StatsRow(),
                    const SizedBox(height: 32),
                    _SectionTitle('Viajes disponibles'),
                    const SizedBox(height: 16),
                    _ViajesDisponiblesSection(
                      disponible:        _disponible,
                      categoriaVehiculo: _categoriaVehiculo,
                      estadoValidacion:  _estadoValidacion,
                      loading:           _loadingDisponibilidad,
                      aceptando:         _aceptando,
                      onAceptar:         _aceptarViaje,
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Top bar ───────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({required this.phone});
  final String phone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FRETIX',
                  style: TextStyle(
                    color:        FretixColors.accent,
                    fontSize:     13,
                    fontWeight:   FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  phone,
                  style: const TextStyle(
                    color:    FretixColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon:      const Icon(Icons.logout_rounded, color: FretixColors.textSecondary),
            tooltip:   'Cerrar sesión',
            onPressed: () => FretixAuthService.instance.signOut(),
          ),
        ],
      ),
    );
  }
}

// ── Disponibilidad card ───────────────────────────────────────────────────────

class _DisponibilidadCard extends StatelessWidget {
  const _DisponibilidadCard({required this.disponible, required this.onToggle});
  final bool                disponible;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final color = disponible ? FretixColors.success : FretixColors.textMuted;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: disponible
              ? FretixColors.success.withOpacity(0.4)
              : FretixColors.surfaceBorder,
        ),
      ),
      child: Row(
        children: [
          Container(
            width:  48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              disponible ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: color,
              size:  24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  disponible ? 'Disponible' : 'No disponible',
                  style: TextStyle(
                    color:      disponible ? FretixColors.success : FretixColors.textPrimary,
                    fontSize:   16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  disponible
                      ? 'Estás recibiendo pedidos'
                      : 'Activá para recibir pedidos',
                  style: const TextStyle(
                    color:    FretixColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value:              disponible,
            onChanged:          onToggle,
            activeColor:        FretixColors.success,
            inactiveThumbColor: FretixColors.textMuted,
            inactiveTrackColor: FretixColors.surfaceBorder,
          ),
        ],
      ),
    );
  }
}

// ── Stats row ─────────────────────────────────────────────────────────────────

class _StatsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        Expanded(child: _StatCard(label: 'Viajes hoy',   value: '0',  icon: Icons.route_rounded)),
        SizedBox(width: 12),
        Expanded(child: _StatCard(label: 'Ganado hoy',   value: r'$0', icon: Icons.attach_money_rounded)),
        SizedBox(width: 12),
        Expanded(child: _StatCard(label: 'Calificación', value: '—',  icon: Icons.star_rounded)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.icon});
  final String   label;
  final String   value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: FretixColors.accent, size: 20),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color:      FretixColors.textPrimary,
              fontSize:   18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color:    FretixColors.textSecondary,
              fontSize: 11,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Banner de subsanación pendiente ──────────────────────────────────────────

class _SubsanacionBanner extends StatelessWidget {
  const _SubsanacionBanner({this.motivo});
  final String? motivo;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF3D1A00),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD4631A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFD4631A), size: 20),
              SizedBox(width: 8),
              Text(
                'Tarjeta Verde pendiente de corrección',
                style: TextStyle(
                  color: Color(0xFFD4631A),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (motivo != null && motivo!.isNotEmpty) ...[
            Text(
              motivo!,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 8),
          ],
          const Text(
            'Mientras no corrijas la documentación no podés recibir viajes. '
            'Tomá una nueva foto de tu Tarjeta Verde y volvé a enviarla.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ── Section title ─────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color:      FretixColors.textPrimary,
        fontSize:   18,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

// ── Viajes disponibles section ────────────────────────────────────────────────

class _ViajesDisponiblesSection extends StatelessWidget {
  const _ViajesDisponiblesSection({
    required this.disponible,
    required this.categoriaVehiculo,
    required this.estadoValidacion,
    required this.loading,
    required this.aceptando,
    required this.onAceptar,
  });

  final bool          disponible;
  final String?       categoriaVehiculo;
  final String?       estadoValidacion;
  final bool          loading;
  final Set<String>   aceptando;
  final void Function(String viajeId) onAceptar;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child:   CircularProgressIndicator(color: FretixColors.accent),
        ),
      );
    }

    // Guard: vehículo registrado pero aún no validado (pendiente_ocr,
    // pendiente_revision o pendiente_subsanacion). La subsanación ya
    // muestra su propio banner arriba; aquí bloqueamos el stream también.
    if (estadoValidacion != null && estadoValidacion != 'validado') {
      return const _EmptyState(
        icon:    Icons.verified_outlined,
        message: 'Tu vehículo está en proceso de validación.\nCuando se apruebe podrás recibir pedidos.',
      );
    }

    if (categoriaVehiculo == null) {
      return const _EmptyState(
        icon:    Icons.directions_car_outlined,
        message: 'Tu cuenta no tiene una categoría de vehículo configurada.\nComunicate con soporte para actualizarla.',
      );
    }

    if (!disponible) {
      return const _EmptyState(
        icon:    Icons.route_outlined,
        message: 'Activá tu disponibilidad\npara empezar a recibir pedidos.',
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('viajes')
          .where('estado',    isEqualTo: 'pending')
          .where('categoria', isEqualTo: categoriaVehiculo)
          .orderBy('creadoEn', descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child:   CircularProgressIndicator(color: FretixColors.accent),
            ),
          );
        }
        if (snap.hasError) {
          return const _EmptyState(
            icon:    Icons.wifi_off_rounded,
            message: 'Error al cargar viajes. Verificá tu conexión.',
          );
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const _EmptyState(
            icon:    Icons.search_off_rounded,
            message: 'No hay viajes disponibles ahora.\nQuedá disponible para recibirlos.',
          );
        }
        return ListView.separated(
          shrinkWrap:       true,
          physics:          const NeverScrollableScrollPhysics(),
          itemCount:        docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final data    = docs[i].data() as Map<String, dynamic>;
            final viajeId = docs[i].id;
            return _ViajeCard(
              viajeId:   viajeId,
              data:      data,
              aceptando: aceptando.contains(viajeId),
              onAceptar: () => onAceptar(viajeId),
            );
          },
        );
      },
    );
  }
}

// ── Viaje card ────────────────────────────────────────────────────────────────

class _ViajeCard extends StatelessWidget {
  const _ViajeCard({
    required this.viajeId,
    required this.data,
    required this.aceptando,
    required this.onAceptar,
  });

  final String               viajeId;
  final Map<String, dynamic> data;
  final bool                 aceptando;
  final VoidCallback         onAceptar;

  @override
  Widget build(BuildContext context) {
    final origen     = data['origen']     as Map<String, dynamic>?;
    final destino    = data['destino']    as Map<String, dynamic>?;
    final cotizacion = data['cotizacion'] as Map<String, dynamic>?;
    final total      = cotizacion?['total']       as num?;
    final distKm     = cotizacion?['distanciaKm'] as num?;
    final durMin     = cotizacion?['duracionMin']  as num?;

    final origenAddr  = origen?['address']  as String? ?? '—';
    final destinoAddr = destino?['address'] as String? ?? '—';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.circle, color: FretixColors.accent, size: 10),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  origenAddr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: FretixColors.textPrimary, fontSize: 13),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Container(width: 2, height: 12, color: FretixColors.surfaceBorder),
          ),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, color: FretixColors.textMuted, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  destinoAddr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: FretixColors.textSecondary, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (distKm != null) ...[
                const Icon(Icons.straighten_rounded, color: FretixColors.textMuted, size: 14),
                const SizedBox(width: 4),
                Text(
                  '${distKm.toStringAsFixed(1)} km',
                  style: const TextStyle(color: FretixColors.textMuted, fontSize: 12),
                ),
                const SizedBox(width: 12),
              ],
              if (durMin != null) ...[
                const Icon(Icons.schedule_outlined, color: FretixColors.textMuted, size: 14),
                const SizedBox(width: 4),
                Text(
                  '${durMin.round()} min',
                  style: const TextStyle(color: FretixColors.textMuted, fontSize: 12),
                ),
                const SizedBox(width: 12),
              ],
              const Spacer(),
              if (total != null)
                Text(
                  '\$${total.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color:      FretixColors.accent,
                    fontSize:   16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              const SizedBox(width: 12),
              SizedBox(
                height: 36,
                child: ElevatedButton(
                  onPressed: aceptando ? null : onAceptar,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:        FretixColors.accent,
                    foregroundColor:        Colors.black,
                    disabledBackgroundColor: FretixColors.accent.withOpacity(0.45),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: aceptando
                      ? const SizedBox(
                          width:  16,
                          height: 16,
                          child:  CircularProgressIndicator(
                            strokeWidth: 2,
                            color:       Colors.black,
                          ),
                        )
                      : const Text(
                          'Aceptar',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String   message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color:        FretixColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: FretixColors.textMuted, size: 40),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color:    FretixColors.textSecondary,
              fontSize: 14,
              height:   1.5,
            ),
          ),
        ],
      ),
    );
  }
}
