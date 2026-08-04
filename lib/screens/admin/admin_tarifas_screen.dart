// lib/screens/admin/admin_tarifas_screen.dart
//
// Módulo 5 — Admin Panel: vista de SOLO LECTURA de /config/tarifas y /config/app.
// No escribe a Firestore. El acceso a esta ruta debe restringirse a usuarios
// con custom claim `role == 'admin'` (enforcement en el router, no en esta pantalla).
//
// Escritura de tarifas → PENDIENTE DE APROBACIÓN CPO (ver OVERNIGHT_LOG.md, Tarea 3).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/fretix_colors.dart';

class AdminTarifasScreen extends StatelessWidget {
  const AdminTarifasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      appBar: AppBar(
        backgroundColor: FretixColors.surface,
        title: const Text(
          'Admin — Tarifas y Config',
          style: TextStyle(color: FretixColors.textPrimary, fontSize: 16),
        ),
        iconTheme: const IconThemeData(color: FretixColors.textPrimary),
        actions: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Chip(
              label: Text('Solo lectura', style: TextStyle(fontSize: 11)),
              backgroundColor: FretixColors.surfaceBorder,
              labelStyle: TextStyle(color: FretixColors.textSecondary),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _TarifasCard(),
          SizedBox(height: 16),
          _AppConfigCard(),
        ],
      ),
    );
  }
}

// ── Tarifas ──────────────────────────────────────────────────────────────────

class _TarifasCard extends StatelessWidget {
  const _TarifasCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('tarifas')
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _LoadingCard(label: 'Tarifas');
        }
        if (snap.hasError) {
          return _ErrorCard(label: 'Tarifas', error: snap.error.toString());
        }
        if (!snap.hasData || !snap.data!.exists) {
          return const _ErrorCard(label: 'Tarifas', error: '/config/tarifas no existe. Ejecutar seed.');
        }

        final data = snap.data!.data() as Map<String, dynamic>;
        final categorias = ['mini', 'plus', 'max', 'heavy'];

        return _SectionCard(
          title: 'Tarifas por Categoría',
          subtitle: 'Fuente: /config/tarifas',
          child: Column(
            children: categorias.map((cat) {
              final c = data[cat] as Map<String, dynamic>?;
              if (c == null) return const SizedBox.shrink();
              return _TarifaRow(categoria: cat, config: c);
            }).toList(),
          ),
        );
      },
    );
  }
}

class _TarifaRow extends StatelessWidget {
  const _TarifaRow({required this.categoria, required this.config});

  final String categoria;
  final Map<String, dynamic> config;

  static const _labels = {
    'mini':  ('Flete Mini',   Icons.directions_car_outlined),
    'plus':  ('Flete Plus',   Icons.airport_shuttle_outlined),
    'max':   ('Flete Max',    Icons.local_shipping_outlined),
    'heavy': ('Carga Pesada', Icons.construction_outlined),
  };

  String _ars(num? v) =>
      v == null ? '—' : NumberFormat.currency(locale: 'es_AR', symbol: '\$', decimalDigits: 0).format(v);

  @override
  Widget build(BuildContext context) {
    final (label, icon) = _labels[categoria] ?? (categoria, Icons.help_outline);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FretixColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: FretixColors.accent),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(
              color: FretixColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 14,
            )),
          ]),
          const SizedBox(height: 8),
          _Grid([
            ('Base',        _ars(config['base'] as num?)),
            ('Por km',      _ars(config['perKm'] as num?)),
            ('Por minuto',  _ars(config['perMin'] as num?)),
            ('Espera libre','${config['esperaGratisMin'] ?? '—'} min'),
          ]),
        ],
      ),
    );
  }
}

// ── App Config ────────────────────────────────────────────────────────────────

class _AppConfigCard extends StatelessWidget {
  const _AppConfigCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('app')
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _LoadingCard(label: 'Config App');
        }
        if (snap.hasError) {
          return _ErrorCard(label: 'Config App', error: snap.error.toString());
        }
        if (!snap.hasData || !snap.data!.exists) {
          return const _ErrorCard(label: 'Config App', error: '/config/app no existe.');
        }

        final d = snap.data!.data() as Map<String, dynamic>;
        final comision  = ((d['comisionPlatforma'] as num?) ?? 0.15) * 100;
        final helperFee = (d['helperFee'] as num?) ?? 0;
        final factor    = d['factorCorreccionMdz'] ?? 1.35;
        final radio     = d['radioMatcheoKm'] ?? 5;

        return _SectionCard(
          title: 'Configuración de la App',
          subtitle: 'Fuente: /config/app',
          child: _Grid([
            ('Comisión plataforma', '${comision.toStringAsFixed(0)}%'),
            ('Helper fee',          '\$${NumberFormat('#,###').format(helperFee)}'),
            ('Factor corrección Mdz','×$factor'),
            ('Radio matcheo',       '$radio km'),
          ]),
        );
      },
    );
  }
}

// ── Componentes genéricos ─────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FretixColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(
            color: FretixColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700,
          )),
          Text(subtitle, style: const TextStyle(color: FretixColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid(this.items);

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: items.map((item) {
        final (label, value) = item;
        return SizedBox(
          width: 145,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: FretixColors.textSecondary, fontSize: 11)),
              Text(value, style: const TextStyle(
                color: FretixColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600,
              )),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: FretixColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: FretixColors.surfaceBorder),
      ),
      child: Row(children: [
        const SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: FretixColors.accent),
        ),
        const SizedBox(width: 12),
        Text('Cargando $label...', style: const TextStyle(color: FretixColors.textSecondary)),
      ]),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.label, required this.error});
  final String label;
  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FretixColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: FretixColors.danger.withAlpha(80)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_outlined, color: FretixColors.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Error cargando $label',
                style: const TextStyle(color: FretixColors.danger, fontWeight: FontWeight.w600, fontSize: 13)),
              Text(error, style: const TextStyle(color: FretixColors.textSecondary, fontSize: 12)),
            ],
          )),
        ],
      ),
    );
  }
}
