import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/user_role.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// RoleSelectionScreen — Onboarding en 3 pasos
//
// Paso 1 → Intención macro: enviar / ofrecer
// Paso 2 → Sub-rol según intención
// Paso 3 → Formulario de perfil (+ datos fiscales si es empresa)
//
// Animaciones:
//   • PageView con fade+slide entre pasos
//   • AnimatedSize para expandir el bloque de datos fiscales
//   • AnimatedSwitcher en el botón de acción
// ─────────────────────────────────────────────────────────────────────────────

enum _Intencion { enviar, ofrecer }

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen>
    with TickerProviderStateMixin {
  // ── Estado del flujo ──────────────────────────────────────────────────────
  int            _paso          = 1;           // 1 / 2 / 3
  _Intencion?    _intencion;
  FretixUserRole? _rolElegido;
  String?        _categoriaVehiculo;

  // ── Controllers del formulario (Paso 3) ───────────────────────────────────
  final _formKey          = GlobalKey<FormState>();
  final _nombreCtrl       = TextEditingController();
  final _emailCtrl        = TextEditingController();
  final _razonSocialCtrl  = TextEditingController();
  final _cuitCtrl         = TextEditingController();
  final _nombreComercCtrl = TextEditingController();

  // ── Estado de la acción final ─────────────────────────────────────────────
  bool    _procesando = false;
  String? _errorMsg;

  // ── Animaciones de transición entre pasos ─────────────────────────────────
  late final AnimationController _stepAnim;
  late final Animation<double>   _stepFade;
  late final Animation<Offset>   _stepSlide;

  @override
  void initState() {
    super.initState();
    _stepAnim = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 380),
    )..forward();

    _stepFade  = CurvedAnimation(parent: _stepAnim, curve: Curves.easeOut);
    _stepSlide = Tween<Offset>(
      begin: const Offset(0.06, 0),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _stepAnim, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _stepAnim.dispose();
    _nombreCtrl.dispose();
    _emailCtrl.dispose();
    _razonSocialCtrl.dispose();
    _cuitCtrl.dispose();
    _nombreComercCtrl.dispose();
    super.dispose();
  }

  // ── Navegación interna ────────────────────────────────────────────────────
  void _irAPaso(int paso) {
    setState(() => _paso = paso);
    _stepAnim.forward(from: 0);
  }

  void _elegirIntencion(_Intencion i) {
    _intencion  = i;
    _rolElegido = null;
    _irAPaso(2);
  }

  void _elegirRol(FretixUserRole rol) {
    _rolElegido = rol;
    _categoriaVehiculo = null; // reset al cambiar de rol
    _irAPaso(3);
    // Auto-focus al campo nombre en el siguiente frame
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FocusScope.of(context).requestFocus(_nombreFocus),
    );
  }

  final _nombreFocus = FocusNode();

  bool get _esEmpresa => _rolElegido?.requiereDatosFiscales ?? false;

  // ── Validación y envío ────────────────────────────────────────────────────
  Future<void> _confirmar() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_rolElegido!.esTransportista && _categoriaVehiculo == null) {
      setState(() => _errorMsg = 'Elegí la categoría de tu vehículo.');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _procesando = true;
      _errorMsg   = null;
    });

    try {
      await FretixAuthService.instance.ejecutarOnboardingBackend(
        nombre:            _nombreCtrl.text.trim(),
        email:             _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        rol:               _rolElegido!,
        razonSocial:       _esEmpresa ? _razonSocialCtrl.text.trim() : null,
        cuit:              _esEmpresa ? _cuitCtrl.text.trim()        : null,
        nombreComercial:   _esEmpresa && _nombreComercCtrl.text.trim().isNotEmpty
                               ? _nombreComercCtrl.text.trim()
                               : null,
        categoriaVehiculo: _categoriaVehiculo,
      );
      // La navegación la hace el service via fretixNavigatorKey
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _procesando = false;
        _errorMsg   = _mensajeError(e.code);
      });
    } catch (_) {
      setState(() {
        _procesando = false;
        _errorMsg   = 'Error inesperado. Intentá de nuevo.';
      });
    }
  }

  String _mensajeError(String? code) {
    switch (code) {
      case 'already-exists':       return 'Tu cuenta ya fue configurada. Iniciá sesión.';
      case 'invalid-argument':     return 'Datos inválidos. Revisá el formulario.';
      case 'unauthenticated':      return 'Sesión expirada. Volvé a ingresar.';
      case 'resource-exhausted':   return 'Servicio ocupado. Intentá en unos segundos.';
      default:                     return 'Error del servidor ($code). Intentá de nuevo.';
    }
  }

  // ── Retroceso entre pasos ─────────────────────────────────────────────────
  void _retroceder() {
    if (_paso == 3) { _irAPaso(2); return; }
    if (_paso == 2) { _intencion = null; _irAPaso(1); return; }
  }

  bool get _puedeRetroceder => _paso > 1;

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              paso:            _paso,
              puedeRetroceder: _puedeRetroceder,
              onBack:          _retroceder,
            ),
            _PasoIndicador(paso: _paso),
            Expanded(
              child: SlideTransition(
                position: _stepSlide,
                child: FadeTransition(
                  opacity: _stepFade,
                  child: _buildContenidoPaso(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContenidoPaso() {
    switch (_paso) {
      case 1:
        return _Paso1(onElegir: _elegirIntencion);
      case 2:
        return _Paso2(intencion: _intencion!, onElegir: _elegirRol);
      case 3:
        return _Paso3(
          formKey:              _formKey,
          rol:                  _rolElegido!,
          nombreCtrl:           _nombreCtrl,
          nombreFocus:          _nombreFocus,
          emailCtrl:            _emailCtrl,
          razonSocialCtrl:      _razonSocialCtrl,
          cuitCtrl:             _cuitCtrl,
          nombreComercCtrl:     _nombreComercCtrl,
          esEmpresa:            _esEmpresa,
          categoriaVehiculo:    _categoriaVehiculo,
          onCategoriaChanged:   (cat) => setState(() => _categoriaVehiculo = cat),
          procesando:           _procesando,
          errorMsg:             _errorMsg,
          onConfirmar:          _confirmar,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Top bar con botón "atrás" y logo
// ═════════════════════════════════════════════════════════════════════════════
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.paso,
    required this.puedeRetroceder,
    required this.onBack,
  });
  final int          paso;
  final bool         puedeRetroceder;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 24, 0),
      child: Row(
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity:  puedeRetroceder ? 1.0 : 0.0,
            child: IconButton(
              icon:      const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              color:     FretixColors.textSecondary,
              onPressed: puedeRetroceder ? onBack : null,
            ),
          ),
          const Spacer(),
          // Wordmark / logo
          const Text(
            'FRETIX',
            style: TextStyle(
              color:          FretixColors.accent,
              fontSize:       18,
              fontWeight:     FontWeight.w900,
              letterSpacing:  3,
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Indicador de progreso de 3 pasos (líneas)
// ═════════════════════════════════════════════════════════════════════════════
class _PasoIndicador extends StatelessWidget {
  const _PasoIndicador({required this.paso});
  final int paso;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: List.generate(3, (i) {
          final activo   = i + 1 <= paso;
          final esCurrent = i + 1 == paso;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height:   3,
              margin:   EdgeInsets.only(right: i < 2 ? 6 : 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: activo
                    ? (esCurrent ? FretixColors.accent : FretixColors.accent.withOpacity(0.45))
                    : FretixColors.surfaceBorder,
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// PASO 1 — Intención macro
// ═════════════════════════════════════════════════════════════════════════════
class _Paso1 extends StatelessWidget {
  const _Paso1({required this.onElegir});
  final void Function(_Intencion) onElegir;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StepHeader(
            titulo:     '¿Qué querés\nhacer con Fretix?',
            subtitulo:  'Elegí tu perfil para personalizar la experiencia.',
          ),
          const SizedBox(height: 40),
          _MacroCard(
            icono:       Icons.local_shipping_rounded,
            titulo:      'Quiero realizar\nenvíos',
            descripcion: 'Pedí camiones, utilitarios\ny más para tus cargas.',
            onTap:       () => onElegir(_Intencion.enviar),
          ),
          const SizedBox(height: 14),
          _MacroCard(
            icono:       Icons.directions_car_filled_rounded,
            titulo:      'Quiero ofrecer mi\nvehículo o flota',
            descripcion: 'Generá ingresos con tu\ncamión, furgón o flota.',
            onTap:       () => onElegir(_Intencion.ofrecer),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// PASO 2 — Sub-rol
// ═════════════════════════════════════════════════════════════════════════════
class _Paso2 extends StatelessWidget {
  const _Paso2({required this.intencion, required this.onElegir});
  final _Intencion                   intencion;
  final void Function(FretixUserRole) onElegir;

  @override
  Widget build(BuildContext context) {
    final esEnviar = intencion == _Intencion.enviar;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepHeader(
            titulo:    esEnviar ? '¿Cómo vas\na enviar?' : '¿Cómo vas\na ofrecer?',
            subtitulo: esEnviar
                ? 'Elegí si enviás como persona o empresa.'
                : 'Elegí tu modalidad de trabajo.',
          ),
          const SizedBox(height: 40),
          if (esEnviar) ...[
            _SubRolCard(
              icono:       Icons.person_rounded,
              titulo:      'Particular',
              descripcion: 'Uso personal, sin CUIT\nni datos fiscales.',
              rol:         FretixUserRole.clienteParticular,
              onTap:       onElegir,
            ),
            const SizedBox(height: 14),
            _SubRolCard(
              icono:       Icons.business_rounded,
              titulo:      'Empresa',
              descripcion: 'Gestión de envíos con\nrazón social y CUIT.',
              rol:         FretixUserRole.clienteEmpresaMaestro,
              onTap:       onElegir,
              badge:       'B2B',
            ),
          ] else ...[
            _SubRolCard(
              icono:       Icons.emoji_people_rounded,
              titulo:      'Chofer Independiente',
              descripcion: 'Trabajás por tu cuenta\ncon tu propio vehículo.',
              rol:         FretixUserRole.choferIndependiente,
              onTap:       onElegir,
            ),
            const SizedBox(height: 14),
            _SubRolCard(
              icono:       Icons.corporate_fare_rounded,
              titulo:      'Empresa de Transporte',
              descripcion: 'Gestionás una flota y\nconductores a cargo.',
              rol:         FretixUserRole.empresaTransporteMaestro,
              onTap:       onElegir,
              badge:       'FLOTA',
            ),
          ],
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// PASO 3 — Formulario de perfil
// ═════════════════════════════════════════════════════════════════════════════
class _Paso3 extends StatelessWidget {
  const _Paso3({
    required this.formKey,
    required this.rol,
    required this.nombreCtrl,
    required this.nombreFocus,
    required this.emailCtrl,
    required this.razonSocialCtrl,
    required this.cuitCtrl,
    required this.nombreComercCtrl,
    required this.esEmpresa,
    required this.categoriaVehiculo,
    required this.onCategoriaChanged,
    required this.procesando,
    required this.errorMsg,
    required this.onConfirmar,
  });

  final GlobalKey<FormState>   formKey;
  final FretixUserRole         rol;
  final TextEditingController  nombreCtrl;
  final FocusNode              nombreFocus;
  final TextEditingController  emailCtrl;
  final TextEditingController  razonSocialCtrl;
  final TextEditingController  cuitCtrl;
  final TextEditingController  nombreComercCtrl;
  final bool                   esEmpresa;
  final String?                categoriaVehiculo;
  final ValueChanged<String>   onCategoriaChanged;
  final bool                   procesando;
  final String?                errorMsg;
  final VoidCallback           onConfirmar;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StepHeader(
              titulo:    'Completá\ntu perfil',
              subtitulo: 'Estos datos aparecerán en tus viajes.',
            ),
            // Chip de rol elegido
            const SizedBox(height: 16),
            _RolChip(rol: rol),
            const SizedBox(height: 32),

            // ── Nombre o Apellido y Nombre ─────────────────────────────────
            _FretixInput(
              controller:  nombreCtrl,
              focusNode:   nombreFocus,
              label:       esEmpresa ? 'Nombre del contacto' : 'Nombre completo',
              hint:        'Ej: Juan Pérez',
              prefixIcon:  Icons.person_outline_rounded,
              textCapitalization: TextCapitalization.words,
              validator:   (v) {
                if (v == null || v.trim().length < 3) {
                  return 'Ingresá al menos 3 caracteres';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),

            // ── Email (opcional) ───────────────────────────────────────────
            _FretixInput(
              controller:  emailCtrl,
              label:       'Email (opcional)',
              hint:        'tu@email.com',
              prefixIcon:  Icons.mail_outline_rounded,
              keyboardType: TextInputType.emailAddress,
              validator:   (v) {
                if (v == null || v.trim().isEmpty) return null;
                final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v.trim());
                return ok ? null : 'Email inválido';
              },
            ),
            const SizedBox(height: 6),

            // ── Categoría de vehículo (solo transportistas) ───────────────
            if (rol.esTransportista) ...[
              const SizedBox(height: 14),
              _DivisorSeccion(label: 'Categoría de vehículo'),
              const SizedBox(height: 14),
              _CategoriaVehiculoSelector(
                selected:  categoriaVehiculo,
                onChanged: onCategoriaChanged,
              ),
            ],

            // ── Bloque fiscal (expandible) ─────────────────────────────────
            AnimatedSize(
              duration: const Duration(milliseconds: 320),
              curve:    Curves.easeInOutCubic,
              child: esEmpresa
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _DivisorSeccion(
                            label: 'Datos de la empresa',
                          ),
                          const SizedBox(height: 14),
                          _FretixInput(
                            controller:  razonSocialCtrl,
                            label:       'Razón Social',
                            hint:        'Ej: Transportes García S.R.L.',
                            prefixIcon:  Icons.business_outlined,
                            textCapitalization: TextCapitalization.words,
                            validator:   (v) {
                              if (v == null || v.trim().length < 3) {
                                return 'Ingresá la razón social';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),
                          _FretixInput(
                            controller:   cuitCtrl,
                            label:        'CUIT',
                            hint:         '20-12345678-9',
                            prefixIcon:   Icons.tag_rounded,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[\d\-]')),
                              LengthLimitingTextInputFormatter(13),
                            ],
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Ingresá el CUIT';
                              }
                              final digits = v.replaceAll('-', '');
                              if (digits.length != 11) {
                                return 'El CUIT debe tener 11 dígitos';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),
                          _FretixInput(
                            controller:  nombreComercCtrl,
                            label:       'Nombre comercial (opcional)',
                            hint:        'Ej: García Logística',
                            prefixIcon:  Icons.storefront_outlined,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 32),

            // ── Error backend ──────────────────────────────────────────────
            if (errorMsg != null) ...[
              _ErrorBanner(message: errorMsg!),
              const SizedBox(height: 20),
            ],

            // ── Botón Confirmar ────────────────────────────────────────────
            _BotonConfirmar(
              procesando: procesando,
              onPressed:  procesando ? null : onConfirmar,
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'Podés modificar estos datos desde tu perfil.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:    FretixColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Componentes reutilizables
// ═════════════════════════════════════════════════════════════════════════════

// ── Header de paso ────────────────────────────────────────────────────────────
class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.titulo, required this.subtitulo});
  final String titulo;
  final String subtitulo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titulo,
          style: const TextStyle(
            color:      FretixColors.textPrimary,
            fontSize:   30,
            fontWeight: FontWeight.w800,
            height:     1.18,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          subtitulo,
          style: const TextStyle(
            color:    FretixColors.textSecondary,
            fontSize: 15,
            height:   1.5,
          ),
        ),
      ],
    );
  }
}

// ── Tarjeta macro (Paso 1) ────────────────────────────────────────────────────
class _MacroCard extends StatefulWidget {
  const _MacroCard({
    required this.icono,
    required this.titulo,
    required this.descripcion,
    required this.onTap,
  });

  final IconData     icono;
  final String       titulo;
  final String       descripcion;
  final VoidCallback onTap;

  @override
  State<_MacroCard> createState() => _MacroCardState();
}

class _MacroCardState extends State<_MacroCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        transform: Matrix4.identity()
          ..scale(_pressed ? 0.975 : 1.0),
        transformAlignment: Alignment.center,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color:        _pressed
              ? FretixColors.surface.withOpacity(0.8)
              : FretixColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _pressed
                ? FretixColors.accent.withOpacity(0.6)
                : FretixColors.surfaceBorder,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width:  52,
              height: 52,
              decoration: BoxDecoration(
                color:        FretixColors.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                widget.icono,
                color: FretixColors.accent,
                size:  26,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.titulo,
                    style: const TextStyle(
                      color:      FretixColors.textPrimary,
                      fontSize:   16,
                      fontWeight: FontWeight.w700,
                      height:     1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.descripcion,
                    style: const TextStyle(
                      color:    FretixColors.textSecondary,
                      fontSize: 13,
                      height:   1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size:  14,
              color: FretixColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tarjeta sub-rol (Paso 2) ──────────────────────────────────────────────────
class _SubRolCard extends StatefulWidget {
  const _SubRolCard({
    required this.icono,
    required this.titulo,
    required this.descripcion,
    required this.rol,
    required this.onTap,
    this.badge,
  });

  final IconData                     icono;
  final String                       titulo;
  final String                       descripcion;
  final FretixUserRole               rol;
  final void Function(FretixUserRole) onTap;
  final String?                      badge;

  @override
  State<_SubRolCard> createState() => _SubRolCardState();
}

class _SubRolCardState extends State<_SubRolCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { setState(() => _pressed = false); widget.onTap(widget.rol); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        transform: Matrix4.identity()..scale(_pressed ? 0.975 : 1.0),
        transformAlignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        decoration: BoxDecoration(
          color:        _pressed
              ? FretixColors.surface.withOpacity(0.8)
              : FretixColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _pressed
                ? FretixColors.accent.withOpacity(0.6)
                : FretixColors.surfaceBorder,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width:  46,
              height: 46,
              decoration: BoxDecoration(
                color:        FretixColors.accent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(widget.icono, color: FretixColors.accent, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        widget.titulo,
                        style: const TextStyle(
                          color:      FretixColors.textPrimary,
                          fontSize:   15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color:        FretixColors.accent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            widget.badge!,
                            style: const TextStyle(
                              color:      FretixColors.accent,
                              fontSize:   10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.descripcion,
                    style: const TextStyle(
                      color:    FretixColors.textSecondary,
                      fontSize: 12.5,
                      height:   1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size:  13,
              color: FretixColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Chip del rol elegido (Paso 3 header) ─────────────────────────────────────
class _RolChip extends StatelessWidget {
  const _RolChip({required this.rol});
  final FretixUserRole rol;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color:        FretixColors.accent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: FretixColors.accent.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            color: FretixColors.accent,
            size:  15,
          ),
          const SizedBox(width: 7),
          Text(
            rol.label,
            style: const TextStyle(
              color:      FretixColors.accent,
              fontSize:   13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Divisor con etiqueta de sección ──────────────────────────────────────────
class _DivisorSeccion extends StatelessWidget {
  const _DivisorSeccion({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color:      FretixColors.textSecondary,
            fontSize:   12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Divider(color: FretixColors.surfaceBorder, thickness: 1),
        ),
      ],
    );
  }
}

// ── Input estilizado ─────────────────────────────────────────────────────────
class _FretixInput extends StatelessWidget {
  const _FretixInput({
    required this.controller,
    required this.label,
    required this.hint,
    required this.prefixIcon,
    this.focusNode,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.validator,
  });

  final TextEditingController          controller;
  final FocusNode?                     focusNode;
  final String                         label;
  final String                         hint;
  final IconData                       prefixIcon;
  final TextInputType?                 keyboardType;
  final TextCapitalization             textCapitalization;
  final List<TextInputFormatter>?      inputFormatters;
  final String? Function(String?)?     validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller:         controller,
      focusNode:          focusNode,
      keyboardType:       keyboardType,
      textCapitalization: textCapitalization,
      inputFormatters:    inputFormatters,
      validator:          validator,
      autovalidateMode:   AutovalidateMode.onUserInteraction,
      style: const TextStyle(
        color:      FretixColors.textPrimary,
        fontSize:   15,
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText:  hint,
        labelStyle: const TextStyle(
          color:    FretixColors.textSecondary,
          fontSize: 13.5,
        ),
        hintStyle: const TextStyle(
          color:    FretixColors.textMuted,
          fontSize: 15,
        ),
        prefixIcon: Icon(
          prefixIcon,
          color: FretixColors.textSecondary,
          size:  20,
        ),
        filled:    true,
        fillColor: FretixColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical:   16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: FretixColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: FretixColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(
            color: FretixColors.accent,
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   const BorderSide(color: FretixColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: FretixColors.danger,
            width: 1.5,
          ),
        ),
        errorStyle: const TextStyle(
          color:    FretixColors.danger,
          fontSize: 12,
        ),
      ),
    );
  }
}

// ── Banner de error backend ───────────────────────────────────────────────────
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        FretixColors.danger.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: FretixColors.danger.withOpacity(0.4),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: FretixColors.danger,
            size:  18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color:    FretixColors.danger,
                fontSize: 13,
                height:   1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Selector de categoría de vehículo ─────────────────────────────────────────
class _CategoriaVehiculoSelector extends StatelessWidget {
  const _CategoriaVehiculoSelector({
    required this.selected,
    required this.onChanged,
  });

  final String?           selected;
  final ValueChanged<String> onChanged;

  static const _cats = [
    (id: 'mini',  label: 'Mini',   icon: Icons.directions_car_outlined),
    (id: 'plus',  label: 'Plus',   icon: Icons.airport_shuttle_outlined),
    (id: 'max',   label: 'Max',    icon: Icons.local_shipping_outlined),
    (id: 'heavy', label: 'Pesado', icon: Icons.construction_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount:   2,
      shrinkWrap:       true,
      physics:          const NeverScrollableScrollPhysics(),
      mainAxisSpacing:  10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.4,
      children: _cats.map((cat) {
        final isSelected = selected == cat.id;
        return GestureDetector(
          onTap: () => onChanged(cat.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              color: isSelected
                  ? FretixColors.accent.withOpacity(0.12)
                  : const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? FretixColors.accent : const Color(0xFF2A2A2A),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  cat.icon,
                  size:  20,
                  color: isSelected ? FretixColors.accent : FretixColors.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  cat.label,
                  style: TextStyle(
                    color:      isSelected ? FretixColors.accent : FretixColors.textMuted,
                    fontSize:   14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Botón Confirmar ───────────────────────────────────────────────────────────
class _BotonConfirmar extends StatelessWidget {
  const _BotonConfirmar({required this.procesando, required this.onPressed});
  final bool          procesando;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width:  double.infinity,
      height: 56,
      child:  ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: FretixColors.accent,
          foregroundColor: Colors.black,
          disabledBackgroundColor: FretixColors.accent.withOpacity(0.45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: procesando
              ? const SizedBox(
                  key:    ValueKey('loader'),
                  width:  22,
                  height: 22,
                  child:  CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color:       Colors.black,
                  ),
                )
              : const Row(
                  key:               ValueKey('label'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Crear mi cuenta',
                      style: TextStyle(
                        fontSize:   17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(width: 8),
                    Icon(Icons.rocket_launch_rounded, size: 18),
                  ],
                ),
        ),
      ),
    );
  }
}
