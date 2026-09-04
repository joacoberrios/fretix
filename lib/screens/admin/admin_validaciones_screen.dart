// ignore_for_file: library_private_types_in_public_api

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AdminValidacionesScreen
//
// Lista vehículos en estado 'pendiente_revision' — el operador puede:
//   - Ver la imagen de la Tarjeta Verde (si está en Storage)
//   - Ingresar PBT y Tara manualmente
//   - Marcar como 'validado' (con los valores ingresados)
//   - Marcar como 'pendiente_subsanacion' (con motivo para el chofer)
//
// Acceso: solo desde _AdminGuard (custom claim role='admin').
// Los reads a /vehiculos están cubiertos por firestore.rules isAdmin().
// ─────────────────────────────────────────────────────────────────────────────

class AdminValidacionesScreen extends StatelessWidget {
  const AdminValidacionesScreen({super.key});

  static final _db = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white70),
        title: const Text(
          'Validaciones pendientes',
          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _db
            .collection('vehiculos')
            .where('estadoValidacion', isEqualTo: 'pendiente_revision')
            .orderBy('createdAt')
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFD4A373)),
            );
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                'Error al cargar: ${snap.error}',
                style: const TextStyle(color: Colors.redAccent),
              ),
            );
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final doc  = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              return _VehiculoCard(vehiculoId: doc.id, data: data);
            },
          );
        },
      ),
    );
  }
}

// ─── Tarjeta de cada vehículo pendiente ──────────────────────────────────────

class _VehiculoCard extends StatefulWidget {
  const _VehiculoCard({required this.vehiculoId, required this.data});
  final String              vehiculoId;
  final Map<String, dynamic> data;

  @override
  _VehiculoCardState createState() => _VehiculoCardState();
}

class _VehiculoCardState extends State<_VehiculoCard> {
  final _pbtCtrl  = TextEditingController();
  final _taraCtrl = TextEditingController();
  final _motivoCtrl = TextEditingController();

  bool   _loading      = false;
  String? _imageUrl;
  bool   _imagenCargando = false;

  @override
  void initState() {
    super.initState();
    // Pre-cargar valores extraídos por OCR si existen
    final pbt  = widget.data['pbtExtraido'];
    final tara = widget.data['taraExtraida'];
    if (pbt  != null) _pbtCtrl.text  = pbt.toString();
    if (tara != null) _taraCtrl.text = tara.toString();
    _cargarImagenUrl();
  }

  @override
  void dispose() {
    _pbtCtrl.dispose();
    _taraCtrl.dispose();
    _motivoCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarImagenUrl() async {
    final path = widget.data['tarjetaVerdeStoragePath'] as String?;
    if (path == null) return;
    setState(() => _imagenCargando = true);
    try {
      final url = await FirebaseStorage.instance.ref(path).getDownloadURL();
      if (mounted) setState(() { _imageUrl = url; _imagenCargando = false; });
    } catch (_) {
      if (mounted) setState(() => _imagenCargando = false);
    }
  }

  Future<void> _validar(BuildContext ctx) async {
    final pbt  = double.tryParse(_pbtCtrl.text.trim().replaceAll(',', '.'));
    final tara = double.tryParse(_taraCtrl.text.trim().replaceAll(',', '.'));
    if (pbt == null || tara == null || pbt <= tara) {
      _mostrarError(ctx, 'PBT y Tara inválidos. PBT debe ser mayor que Tara.');
      return;
    }
    final messenger = ScaffoldMessenger.of(ctx);
    setState(() => _loading = true);
    try {
      final adminUid = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance.collection('vehiculos').doc(widget.vehiculoId).update({
        'estadoValidacion': 'validado',
        'capacidadMaxKg':   (pbt - tara).round(),
        'pbtExtraido':      pbt,
        'taraExtraida':     tara,
        'validadoEn':       FieldValue.serverTimestamp(),
        'validadoPor':      adminUid,
      });
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Vehículo validado correctamente'),
            backgroundColor: Color(0xFF2D6A4F),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error al validar: $e'), backgroundColor: const Color(0xFFB00020)),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _subsanar(BuildContext ctx) async {
    final motivo = _motivoCtrl.text.trim();
    if (motivo.isEmpty) {
      _mostrarError(ctx, 'Ingresá el motivo para el chofer.');
      return;
    }
    final messenger = ScaffoldMessenger.of(ctx);
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance.collection('vehiculos').doc(widget.vehiculoId).update({
        'estadoValidacion': 'pendiente_subsanacion',
        'motivoSubsanacion': motivo,
      });
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Vehículo enviado a subsanación'),
            backgroundColor: Color(0xFF8B4513),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFB00020)),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _mostrarError(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFFB00020)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoria  = widget.data['categoriaVehiculo'] as String? ?? '—';
    final choferUid  = widget.data['choferUid'] as String? ?? '—';
    final pbtOcr     = widget.data['pbtExtraido'];
    final taraOcr    = widget.data['taraExtraida'];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Encabezado
          Row(
            children: [
              const Icon(Icons.local_shipping_outlined, color: Color(0xFFD4A373), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  categoria.replaceAll('_', ' ').toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4A373).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Revisión pendiente',
                  style: TextStyle(color: Color(0xFFD4A373), fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Chofer: $choferUid',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            'ID vehículo: ${widget.vehiculoId}',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),

          // Imagen Tarjeta Verde
          const SizedBox(height: 12),
          _buildImagen(),

          // Valores extraídos por OCR (solo lectura, referencia)
          if (pbtOcr != null || taraOcr != null) ...[
            const SizedBox(height: 10),
            Text(
              'OCR extrajo — PBT: ${pbtOcr ?? "—"} kg · Tara: ${taraOcr ?? "—"} kg',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],

          // Inputs manuales PBT / Tara
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _inputField(
                  controller: _pbtCtrl,
                  label: 'PBT (kg)',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _inputField(
                  controller: _taraCtrl,
                  label: 'Tara (kg)',
                ),
              ),
            ],
          ),

          // Campo motivo subsanación
          const SizedBox(height: 10),
          _inputField(
            controller: _motivoCtrl,
            label: 'Motivo subsanación (si aplica)',
          ),

          // Botones
          const SizedBox(height: 14),
          _loading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: Color(0xFFD4A373),
                    strokeWidth: 2,
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: 'Validar',
                        color: const Color(0xFF2D6A4F),
                        onPressed: () => _validar(context),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        label: 'Subsanar',
                        color: const Color(0xFF8B4513),
                        onPressed: () => _subsanar(context),
                      ),
                    ),
                  ],
                ),
        ],
      ),
    );
  }

  Widget _buildImagen() {
    if (_imagenCargando) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator(color: Color(0xFFD4A373), strokeWidth: 2)),
      );
    }
    if (_imageUrl == null) {
      return Container(
        height: 80,
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Text('Sin imagen', style: TextStyle(color: Colors.white30, fontSize: 12)),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        _imageUrl!,
        height: 180,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox(
          height: 80,
          child: Center(
            child: Text('Error al cargar imagen', style: TextStyle(color: Colors.red)),
          ),
        ),
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF111111),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFD4A373)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });
  final String label;
  final Color  color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Empty state ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: Color(0xFF2D6A4F), size: 48),
          SizedBox(height: 16),
          Text(
            'Sin validaciones pendientes',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 6),
          Text(
            'Todos los vehículos están al día.',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
