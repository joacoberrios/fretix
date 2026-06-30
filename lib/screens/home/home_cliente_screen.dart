import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

class HomeClienteScreen extends StatelessWidget {
  const HomeClienteScreen({super.key});

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
                    const SizedBox(height: 32),
                    _SectionTitle('¿Qué querés mover?'),
                    const SizedBox(height: 16),
                    _VehicleGrid(),
                    const SizedBox(height: 32),
                    _SectionTitle('Mis envíos'),
                    const SizedBox(height: 16),
                    _EmptyState(
                      icon: Icons.local_shipping_outlined,
                      message: 'Todavía no tenés envíos.\nCreá tu primer pedido.',
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
            _PedirFleteButton(),
          ],
        ),
      ),
    );
  }
}

// ── Top bar ────────────────────────────────────────────────────────────────────

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
                    color: FretixColors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  phone,
                  style: const TextStyle(
                    color: FretixColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: FretixColors.textSecondary),
            tooltip: 'Cerrar sesión',
            onPressed: () => FretixAuthService.instance.signOut(),
          ),
        ],
      ),
    );
  }
}

// ── Section title ──────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: FretixColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

// ── Vehicle grid ───────────────────────────────────────────────────────────────

class _VehicleGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const vehicles = [
      (_VehicleItem(icon: Icons.local_shipping_rounded,  label: 'Camión')),
      (_VehicleItem(icon: Icons.airport_shuttle_rounded, label: 'Furgón')),
      (_VehicleItem(icon: Icons.directions_car_rounded,  label: 'Utilitario')),
      (_VehicleItem(icon: Icons.two_wheeler_rounded,     label: 'Moto')),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: vehicles,
    );
  }
}

class _VehicleItem extends StatelessWidget {
  const _VehicleItem({required this.icon, required this.label});
  final IconData icon;
  final String   label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FretixColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: FretixColors.accent, size: 28),
              Text(
                label,
                style: const TextStyle(
                  color: FretixColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Empty state ────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String   message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: FretixColors.surface,
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
              color: FretixColors.textSecondary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ── CTA button ─────────────────────────────────────────────────────────────────

class _PedirFleteButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.add_rounded, size: 20),
          label: const Text(
            'Pedir flete',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          onPressed: () => Navigator.of(context).pushNamed(AppRouter.cotizacion),
        ),
      ),
    );
  }
}
