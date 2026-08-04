import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';
import 'phone_input_screen.dart' show OtpArgs;

// ─────────────────────────────────────────────────────────────────────────────
// OtpScreen
//
// 6 campos individuales con auto-focus en cascada.
// Countdown de 60s con reenvío de SMS.
// Navega a RoleSelectionScreen si es usuario nuevo,
// o directamente al home del rol si ya tiene onboarding completado.
// ─────────────────────────────────────────────────────────────────────────────
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen>
    with SingleTickerProviderStateMixin {
  // 6 controllers + 6 focusNodes, uno por dígito
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focusNodes  = List.generate(6, (_) => FocusNode());

  bool    _loading         = false;
  String? _error;
  bool    _puedeReenviar   = false;
  int     _segundosRestantes = 60;

  Timer? _timer;

  late OtpArgs _args;
  bool _argsLoaded = false;

  late final AnimationController _anim;
  late final Animation<double>   _fadeIn;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _fadeIn = CurvedAnimation(parent: _anim, curve: Curves.easeOut);

    _iniciarCountdown();

    // Foco en el primer campo cuando el frame esté listo
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNodes[0].requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_argsLoaded) {
      _args       = ModalRoute.of(context)!.settings.arguments as OtpArgs;
      _argsLoaded = true;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) c.dispose();
    for (final f in _focusNodes)  f.dispose();
    _timer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  // ── Countdown ─────────────────────────────────────────────────────────────
  void _iniciarCountdown() {
    _puedeReenviar    = false;
    _segundosRestantes = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _segundosRestantes--;
        if (_segundosRestantes <= 0) {
          _puedeReenviar = true;
          t.cancel();
        }
      });
    });
  }

  // ── Reenvío de SMS ────────────────────────────────────────────────────────
  Future<void> _reenviarCodigo() async {
    setState(() { _error = null; _puedeReenviar = false; });
    _limpiarCampos();

    await FretixAuthService.instance.verifyPhoneNumber(
      phone: _args.phone,
      onCodeSent: (newVerificationId) {
        if (!mounted) return;
        // Reemplazar los args con el nuevo verificationId
        _args = OtpArgs(
          phone:          _args.phone,
          verificationId: newVerificationId,
        );
        _iniciarCountdown();
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _error         = _mensajeError(e.code);
          _puedeReenviar = true;
        });
      },
    );
  }

  // ── Manejo de campos OTP ──────────────────────────────────────────────────
  void _onDigitChanged(int index, String value) {
    if (_error != null) setState(() => _error = null);

    if (value.length == 1) {
      // Avanzar al siguiente campo
      if (index < 5) {
        _focusNodes[index + 1].requestFocus();
      } else {
        // Último dígito ingresado → verificar automáticamente
        _focusNodes[index].unfocus();
        _verificarCodigo();
      }
    }
  }

  void _onKeyDown(int index, KeyEvent event) {
    // Retroceder al campo anterior al pulsar Backspace con campo vacío
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _focusNodes[index - 1].requestFocus();
      // Limpiar el campo anterior para permitir reingreso
      _controllers[index - 1].clear();
    }
  }

  void _limpiarCampos() {
    for (final c in _controllers) c.clear();
    _focusNodes[0].requestFocus();
  }

  String get _codigoCompleto =>
      _controllers.map((c) => c.text).join();

  // ── Verificación ──────────────────────────────────────────────────────────
  Future<void> _verificarCodigo() async {
    final code = _codigoCompleto;
    if (code.length < 6) {
      setState(() => _error = 'Ingresá los 6 dígitos del código');
      return;
    }

    setState(() {
      _loading = true;
      _error   = null;
    });

    try {
      final credential = await FretixAuthService.instance.signInWithCode(
        verificationId: _args.verificationId,
        smsCode:        code,
      );

      if (!mounted) return;

      // Usuario nuevo → onboarding de selección de rol
      // Usuario existente → cada caso según su rol guardado en Firestore
      // (la Cloud Function se encarga de redirigir al home correcto)
      if (credential.additionalUserInfo?.isNewUser ?? false) {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRouter.roleSelection,
          (_) => false,
        );
      } else {
        // Usuario existente: leer rol desde Firestore para navegar al home correcto.
        String targetRoute = AppRouter.roleSelection;
        try {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(credential.user!.uid)
              .get();
          final role = doc.data()?['role'] as String?;
          if (role == 'chofer') {
            targetRoute = AppRouter.homeChofer;
          } else if (role == 'cliente' || role == 'empresa') {
            targetRoute = AppRouter.homeCliente;
          }
        } catch (_) {
          // Sin datos en Firestore → volver al onboarding
        }
        if (!mounted) return;
        Navigator.pushNamedAndRemoveUntil(context, targetRoute, (_) => false);
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = _mensajeError(e.code);
      });
      _limpiarCampos();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = 'Error inesperado. Intentá de nuevo.';
      });
    }
  }

  String _mensajeError(String code) {
    switch (code) {
      case 'invalid-verification-code':
        return 'Código incorrecto. Revisá los 6 dígitos.';
      case 'session-expired':
        return 'El código expiró. Pedí uno nuevo.';
      case 'too-many-requests':
        return 'Demasiados intentos. Esperá unos minutos.';
      default:
        return 'Error ($code). Pedí un nuevo código.';
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_argsLoaded) return const SizedBox.shrink();

    // Número parcialmente oculto: "+54 261 ***3921"
    final phoneDisplay = _args.phone.replaceRange(
      _args.phone.length - 6,
      _args.phone.length - 2,
      '***',
    );

    return Scaffold(
      backgroundColor: FretixColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation:       0,
        leading: IconButton(
          icon:  const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: FretixColors.textSecondary,
          onPressed: () {
            _timer?.cancel();
            Navigator.maybePop(context);
          },
        ),
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeIn,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                _Header(phoneDisplay: phoneDisplay),
                const SizedBox(height: 40),
                _OtpFields(
                  controllers: _controllers,
                  focusNodes:  _focusNodes,
                  onChanged:   _onDigitChanged,
                  onKeyDown:   _onKeyDown,
                  hasError:    _error != null,
                  enabled:     !_loading,
                ),
                const SizedBox(height: 12),
                _ErrorLabel(message: _error),
                const SizedBox(height: 32),
                _ReenviarRow(
                  puedeReenviar:    _puedeReenviar,
                  segundosRestantes: _segundosRestantes,
                  onReenviar:       _reenviarCodigo,
                ),
                const Spacer(),
                _BotonVerificar(
                  loading:   _loading,
                  onPressed: _loading ? null : _verificarCodigo,
                ),
                const SizedBox(height: 36),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Subwidgets ───────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.phoneDisplay});
  final String phoneDisplay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Ingresá el\ncódigo',
          style: TextStyle(
            color:      FretixColors.textPrimary,
            fontSize:   32,
            fontWeight: FontWeight.w800,
            height:     1.15,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Te enviamos un SMS al\n$phoneDisplay',
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

class _OtpFields extends StatelessWidget {
  const _OtpFields({
    required this.controllers,
    required this.focusNodes,
    required this.onChanged,
    required this.onKeyDown,
    required this.hasError,
    required this.enabled,
  });

  final List<TextEditingController>  controllers;
  final List<FocusNode>              focusNodes;
  final void Function(int, String)   onChanged;
  final void Function(int, KeyEvent) onKeyDown;
  final bool                         hasError;
  final bool                         enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(6, (i) {
        return KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (event) => onKeyDown(i, event),
          child: SizedBox(
            width:  50,
            height: 62,
            child:  TextFormField(
              controller:      controllers[i],
              focusNode:       focusNodes[i],
              enabled:         enabled,
              keyboardType:    TextInputType.number,
              textAlign:       TextAlign.center,
              maxLength:       1,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                color:      FretixColors.textPrimary,
                fontSize:   24,
                fontWeight: FontWeight.w700,
              ),
              decoration: InputDecoration(
                counterText: '',
                filled:      true,
                fillColor:   FretixColors.surface,
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:   const BorderSide(color: FretixColors.surfaceBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: hasError
                        ? FretixColors.danger
                        : FretixColors.surfaceBorder,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color:  hasError ? FretixColors.danger : FretixColors.accent,
                    width:  2,
                  ),
                ),
              ),
              onChanged: (v) => onChanged(i, v),
            ),
          ),
        );
      }),
    );
  }
}

class _ErrorLabel extends StatelessWidget {
  const _ErrorLabel({this.message});
  final String? message;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: message != null
          ? Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color:    FretixColors.danger,
                  fontSize: 13,
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _ReenviarRow extends StatelessWidget {
  const _ReenviarRow({
    required this.puedeReenviar,
    required this.segundosRestantes,
    required this.onReenviar,
  });

  final bool          puedeReenviar;
  final int           segundosRestantes;
  final VoidCallback  onReenviar;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          '¿No llegó? ',
          style: TextStyle(color: FretixColors.textSecondary, fontSize: 14),
        ),
        if (puedeReenviar)
          GestureDetector(
            onTap: onReenviar,
            // SizedBox 44px garantiza touch target mínimo (a11y).
            child: const SizedBox(
              height: 44,
              child: Center(
                child: Text(
                  'Reenviar SMS',
                  style: TextStyle(
                    color:      FretixColors.accent,
                    fontSize:   14,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: FretixColors.accent,
                  ),
                ),
              ),
            ),
          )
        else
          Text(
            'Reenviar en ${segundosRestantes}s',
            style: const TextStyle(
              color:    FretixColors.countdown,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

class _BotonVerificar extends StatelessWidget {
  const _BotonVerificar({required this.loading, required this.onPressed});
  final bool          loading;
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
          disabledBackgroundColor: FretixColors.accent.withOpacity(0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: loading
              ? const SizedBox(
                  key:    ValueKey('loader'),
                  width:  22,
                  height: 22,
                  child:  CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color:       Colors.black,
                  ),
                )
              : const Text(
                  key:  ValueKey('label'),
                  'Verificar código',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
        ),
      ),
    );
  }
}
