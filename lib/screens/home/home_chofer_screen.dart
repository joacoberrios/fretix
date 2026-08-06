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
  bool _disponible            = false;
  bool _loadingDisponibilidad = true;
  bool _toggling              = false;

  @override
  void initState() {
    super.initState();
    _cargarDisponibilidad();
  }

  Future<void> _cargarDisponibilidad() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _loadingDisponibilidad = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final valor = doc.data()?['disponibleParaViajes'] as bool? ?? false;
      setState(() {
        _disponible             = valor;
        _loadingDisponibilidad  = false;
      });
    } catch (_) {
      setState(() => _loadingDisponibilidad = false);
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
                    const SizedBox(height: 32),
                    _SectionTitle('Resumen del día'),
                    const SizedBox(height: 16),
                    _StatsRow(),
                    const SizedBox(height: 32),
                    _SectionTitle('Historial de viajes'),
                    const SizedBox(height: 16),
                    _EmptyState(
                      icon: Icons.route_outlined,
                      message: 'Activá tu disponibilidad\npara empezar a recibir pedidos.',
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
