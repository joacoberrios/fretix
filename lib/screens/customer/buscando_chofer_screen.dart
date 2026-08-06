import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../theme/fretix_colors.dart';

class BuscandoChoferScreen extends StatefulWidget {
  const BuscandoChoferScreen({super.key, this.viajeId});

  final String? viajeId;

  @override
  State<BuscandoChoferScreen> createState() => _BuscandoChoferScreenState();
}

class _BuscandoChoferScreenState extends State<BuscandoChoferScreen> {
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
                  : _ViajeWatcher(viajeId: widget.viajeId!),
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
  const _ViajeWatcher({required this.viajeId});

  final String viajeId;

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

        if (estado == 'aceptado') {
          final choferData = data['choferData'] as Map<String, dynamic>?;
          final nombre     = choferData?['displayName'] as String? ?? 'Tu chofer';
          final photoURL   = choferData?['photoURL']    as String?;
          final duracion   = (data['cotizacion'] as Map<String, dynamic>?)?['duracionMin'] as num?;

          return _ChoferAsignadoView(
            nombre:   nombre,
            photoURL: photoURL,
            etaMin:   duracion?.round(),
          );
        }

        // estado == 'pending' o cualquier otro → spinner de búsqueda
        return const _SearchingState();
      },
    );
  }
}

// ── Chofer asignado ───────────────────────────────────────────────────────────

class _ChoferAsignadoView extends StatelessWidget {
  const _ChoferAsignadoView({
    required this.nombre,
    this.photoURL,
    this.etaMin,
  });

  final String  nombre;
  final String? photoURL;
  final int?    etaMin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Avatar
          Container(
            width:  96,
            height: 96,
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
            nombre,
            style: const TextStyle(
              color:      FretixColors.textPrimary,
              fontSize:   18,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (etaMin != null) ...[
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
                  Text(
                    'ETA estimada: $etaMin min',
                    style: const TextStyle(color: FretixColors.textSecondary, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Quedá en el punto de origen para que el chofer pueda encontrarte.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:  FretixColors.textSecondary,
                fontSize: 13,
                height:   1.6,
              ),
            ),
          ),
        ],
      ),
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
