import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

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
            return _ChoferAsignadoView(
              nombre:     nombre,
              photoURL:   photoURL,
              categoria:  categoria,
              etaMin:     duracion?.round(),
              cancelando: cancelando,
              onCancelar: onCancelar,
            );

          case 'en_curso':
            final choferData = data['choferData'] as Map<String, dynamic>?;
            final nombre     = choferData?['displayName'] as String? ?? 'Tu chofer';
            return _EnCursoView(nombre: nombre);

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

class _ChoferAsignadoView extends StatelessWidget {
  const _ChoferAsignadoView({
    required this.nombre,
    this.photoURL,
    this.categoria,
    this.etaMin,
    required this.cancelando,
    required this.onCancelar,
  });

  final String  nombre;
  final String? photoURL;
  final String? categoria;
  final int?    etaMin;
  final bool         cancelando;
  final VoidCallback onCancelar;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
          if (categoria != null) ...[
            const SizedBox(height: 4),
            Text(
              _etiquetaCategoria(categoria!),
              style: const TextStyle(color: FretixColors.textMuted, fontSize: 13),
            ),
          ],
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
            onPressed: cancelando ? null : onCancelar,
            child: cancelando
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
        ],
      ),
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

class _EnCursoView extends StatelessWidget {
  const _EnCursoView({required this.nombre});
  final String nombre;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
            '$nombre está llevando tu carga',
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
