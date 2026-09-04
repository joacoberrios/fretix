// ignore_for_file: library_private_types_in_public_api

import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import 'vehiculo_payload.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SubirTarjetaVerdeScreen
//
// Pantalla obligatoria para choferes sin vehículo registrado.
// También accesible desde _SubsanacionBanner para re-subida (subsanación).
//
// Flujo:
//   1. initState consulta /vehiculos/ — modo creación o modo actualización.
//   2. Chofer selecciona categoría y foto.
//   3. Upload a Storage con putData (compatible con Flutter Web).
//   4. Crea o actualiza doc /vehiculos/ con estadoValidacion: 'pendiente_ocr'.
//   5. Llama validarTarjetaVerdeFretix.
//   6. validado → homeChofer / pendiente_revision → dialog → homeChofer.
// ─────────────────────────────────────────────────────────────────────────────

class SubirTarjetaVerdeScreen extends StatefulWidget {
  const SubirTarjetaVerdeScreen({super.key});

  @override
  _SubirTarjetaVerdeScreenState createState() => _SubirTarjetaVerdeScreenState();
}

class _SubirTarjetaVerdeScreenState extends State<SubirTarjetaVerdeScreen> {
  bool    _loadingCheck        = true;
  String? _vehiculoIdExistente;  // null → modo creación, non-null → modo actualización

  String?    _categoria;
  Uint8List? _imageBytes;
  bool       _subiendo = false;
  String?    _error;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _verificarVehiculoExistente();
  }

  /// Busca si el chofer ya tiene un doc /vehiculos/.
  /// Si existe: pre-carga categoría y activa modo actualización.
  Future<void> _verificarVehiculoExistente() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _loadingCheck = false);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('vehiculos')
          .where('choferUid', isEqualTo: uid)
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        final data = snap.docs.first.data();
        setState(() {
          _vehiculoIdExistente = snap.docs.first.id;
          _categoria           = data['categoriaVehiculo'] as String?;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingCheck = false);
    }
  }

  Future<void> _seleccionarImagen(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source:       source,
        imageQuality: 85,
        maxWidth:     1920,
      );
      if (picked == null) return;
      // readAsBytes() devuelve Uint8List — funciona en web y móvil sin dart:io
      final bytes = await picked.readAsBytes();
      setState(() { _imageBytes = bytes; _error = null; });
    } catch (_) {
      setState(() => _error = 'No se pudo acceder a la cámara o galería.');
    }
  }

  Future<void> _subir() async {
    if (_imageBytes == null || _categoria == null) {
      setState(() =>
        _error = 'Seleccioná el tipo de vehículo y una foto de la Tarjeta Verde.');
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() { _subiendo = true; _error = null; });

    try {
      // 1. Upload a Storage — putData es compatible con Flutter Web
      final ts          = DateTime.now().millisecondsSinceEpoch;
      final storagePath = buildStoragePath(uid, ts);
      await FirebaseStorage.instance.ref(storagePath).putData(_imageBytes!);

      // 2. Crear o actualizar doc /vehiculos/
      final db = FirebaseFirestore.instance;
      String vehiculoId;

      if (_vehiculoIdExistente != null) {
        await db.collection('vehiculos').doc(_vehiculoIdExistente).update(
          buildVehiculoUpdatePayload(
            categoria:   _categoria!,
            storagePath: storagePath,
          ),
        );
        vehiculoId = _vehiculoIdExistente!;
      } else {
        final ref = await db.collection('vehiculos').add(
          buildVehiculoPayload(
            uid:         uid,
            categoria:   _categoria!,
            storagePath: storagePath,
          ),
        );
        vehiculoId = ref.id;
      }

      // 3. Llamar CF de validación OCR
      final callable = FretixAuthService.instance.getCallable(
        'validarTarjetaVerdeFretix',
        timeout: const Duration(seconds: 60),
      );
      final result = await callable.call({'vehiculoId': vehiculoId});
      if (!mounted) return;

      final data       = Map<String, dynamic>.from(result.data as Map);
      final estado     = data['estado'] as String?;
      final yaValidado = data['ya_validado'] == true;

      if (estado == 'validado' || yaValidado) {
        Navigator.pushNamedAndRemoveUntil(context, AppRouter.homeChofer, (_) => false);
      } else {
        _mostrarDialogPendiente();
        setState(() => _subiendo = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = 'Ocurrió un error al procesar tu Tarjeta Verde. Intentá de nuevo.';
        _subiendo = false;
      });
    }
  }

  void _mostrarDialogPendiente() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'En revisión',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'No pudimos validar tu Tarjeta Verde automáticamente. '
          'Nuestro equipo la revisará y te notificará cuando esté aprobada. '
          'Mientras tanto podés acceder a la app, pero no recibirás viajes hasta que se complete la validación.',
          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.pushNamedAndRemoveUntil(
                  context, AppRouter.homeChofer, (_) => false);
            },
            child: const Text('Entendido',
                style: TextStyle(color: Color(0xFFD4A373))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingCheck) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
        body: Center(child: CircularProgressIndicator(color: Color(0xFFD4A373))),
      );
    }

    final esResubida = _vehiculoIdExistente != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation:       0,
        iconTheme:       const IconThemeData(color: Colors.white70),
        title: Text(
          esResubida ? 'Corregir Tarjeta Verde' : 'Registrá tu vehículo',
          style: const TextStyle(
              color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              esResubida
                  ? 'Subí una nueva foto de la Tarjeta Verde para corregir la documentación observada.'
                  : 'Para comenzar a operar necesitás registrar tu vehículo. '
                    'Subí una foto clara de la Tarjeta Verde.',
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 24),

            const _SectionLabel('Tipo de vehículo'),
            const SizedBox(height: 8),
            _CategoriaSelector(
              selected:  _categoria,
              onChanged: (v) => setState(() => _categoria = v),
            ),
            const SizedBox(height: 24),

            const _SectionLabel('Foto de la Tarjeta Verde'),
            const SizedBox(height: 8),
            _FotoSelector(
              imageBytes: _imageBytes,
              onCamara:   () => _seleccionarImagen(ImageSource.camera),
              onGaleria:  () => _seleccionarImagen(ImageSource.gallery),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding:    const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:        const Color(0xFFB00020).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13),
                ),
              ),
            ],

            const SizedBox(height: 32),

            SizedBox(
              width:  double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _subiendo ? null : _subir,
                style: ElevatedButton.styleFrom(
                  backgroundColor:         const Color(0xFFD4A373),
                  disabledBackgroundColor: const Color(0xFF3A3A3A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _subiendo
                    ? const SizedBox(
                        width:  22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.black, strokeWidth: 2.5),
                      )
                    : const Text(
                        'Enviar para validación',
                        style: TextStyle(
                          color:      Colors.black,
                          fontSize:   15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ── Etiqueta de sección ───────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          color: Colors.white54, fontSize: 12, letterSpacing: 0.8),
    );
  }
}

// ── Selector de categoría ─────────────────────────────────────────────────────

class _CategoriaSelector extends StatelessWidget {
  const _CategoriaSelector({required this.selected, required this.onChanged});
  final String?               selected;
  final ValueChanged<String?> onChanged;

  static const _opciones = [
    ('utilitario',        'Utilitario (furgón, kangoo)'),
    ('pickup',            'Pickup'),
    ('pickup_estructura', 'Pickup con estructura'),
    ('camion_liviano',    'Camión liviano'),
    ('camion_frio',       'Camión frío'),
    ('camion_mediano',    'Camión mediano'),
    ('camion_mudanza',    'Camión mudanza'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:        const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value:      selected,
          isExpanded: true,
          padding:    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          hint: const Text(
            'Seleccioná el tipo',
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
          dropdownColor:    const Color(0xFF1A1A1A),
          iconEnabledColor: const Color(0xFFD4A373),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          items: _opciones
              .map((o) => DropdownMenuItem(value: o.$1, child: Text(o.$2)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ── Selector de foto ──────────────────────────────────────────────────────────

class _FotoSelector extends StatelessWidget {
  const _FotoSelector({
    required this.imageBytes,
    required this.onCamara,
    required this.onGaleria,
  });
  final Uint8List?   imageBytes;
  final VoidCallback onCamara;
  final VoidCallback onGaleria;

  @override
  Widget build(BuildContext context) {
    final botones = Row(
      children: [
        Expanded(
          child: _SourceButton(
            icon:  Icons.camera_alt_outlined,
            label: imageBytes != null ? 'Retomar foto' : 'Usar cámara',
            onTap: onCamara,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SourceButton(
            icon:  Icons.photo_library_outlined,
            label: 'De galería',
            onTap: onGaleria,
          ),
        ),
      ],
    );

    if (imageBytes == null) return botones;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          // Image.memory — funciona en web y móvil sin dart:io
          child: Image.memory(
            imageBytes!,
            height: 200,
            width:  double.infinity,
            fit:    BoxFit.cover,
          ),
        ),
        const SizedBox(height: 10),
        botones,
      ],
    );
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton(
      {required this.icon, required this.label, required this.onTap});
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:    const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color:        const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: const Color(0xFF2A2A2A)),
        ),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xFFD4A373), size: 24),
            const SizedBox(height: 6),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
