import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../router/app_router.dart';
import '../../services/auth_service.dart';
import '../../theme/fretix_colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PhoneInputScreen
//
// Ingreso del número celular con prefijo +54 (Argentina).
// Validación local de formato antes de disparar el SMS.
// Navega a OtpScreen pasando el número completo como argumento de ruta.
// ─────────────────────────────────────────────────────────────────────────────
class PhoneInputScreen extends StatefulWidget {
  const PhoneInputScreen({super.key});

  @override
  State<PhoneInputScreen> createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends State<PhoneInputScreen>
    with SingleTickerProviderStateMixin {
  final _controller  = TextEditingController();
  final _focusNode   = FocusNode();

  bool   _loading = false;
  String? _error;

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

    // Auto-focus teclado al entrar a la pantalla
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _anim.dispose();
    super.dispose();
  }

  // ── Validación ────────────────────────────────────────────────────────────

  /// Retorna el número en formato E.164 o null si no es válido.
  /// Acepta: "2614783921" → "+542614783921"
  ///         "02614783921" → "+542614783921"  (elimina 0 inicial)
  ///         "+542614783921" → "+542614783921" (ya completo)
  String? _normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');

    if (digits.startsWith('54') && digits.length >= 12) {
      return '+$digits';
    }
    // Quitar el 0 de código de área si lo tiene
    final local = digits.startsWith('0') ? digits.substring(1) : digits;

    // Argentina: código de área (2-4 dígitos) + número. Longitudes típicas:
    // Buenos Aires 11 + 8 = 10 dígitos locales → con 54 = 12
    // Mendoza 261 + 7 = 10 dígitos locales → con 54 = 12
    if (local.length < 8 || local.length > 11) return null;

    return '+54$local';
  }

  String? _validate(String raw) {
    if (raw.trim().isEmpty) return 'Ingresá tu número de celular';
    final normalized = _normalizePhone(raw.trim());
    if (normalized == null) {
      return 'Número inválido. Ejemplo: 2614783921';
    }
    return null;
  }

  // ── Acción ────────────────────────────────────────────────────────────────
  Future<void> _enviarCodigo() async {
    final raw = _controller.text;
    final validationError = _validate(raw);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    final phone = _normalizePhone(raw.trim())!;
    setState(() {
      _loading = true;
      _error   = null;
    });

    await FretixAuthService.instance.verifyPhoneNumber(
      phone: phone,
      onCodeSent: (verificationId) {
        if (!mounted) return;
        setState(() => _loading = false);
        Navigator.pushNamed(
          context,
          AppRouter.otp,
          arguments: OtpArgs(phone: phone, verificationId: verificationId),
        );
      },
      onError: (FirebaseAuthException e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error   = _mensajeError(e.code);
        });
      },
    );
  }

  String _mensajeError(String code) {
    switch (code) {
      case 'invalid-phone-number':
        return 'Número inválido. Revisá el código de área.';
      case 'too-many-requests':
        return 'Demasiados intentos. Esperá unos minutos.';
      case 'quota-exceeded':
        return 'Servicio temporalmente no disponible.';
      default:
        return 'Error inesperado ($code). Intentá de nuevo.';
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FretixColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation:       0,
        leading: IconButton(
          icon:  const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: FretixColors.textSecondary,
          onPressed: () => Navigator.maybePop(context),
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
                _Header(),
                const SizedBox(height: 40),
                _PhoneField(
                  controller: _controller,
                  focusNode:  _focusNode,
                  error:      _error,
                  onSubmit:   _loading ? null : _enviarCodigo,
                  onChanged:  (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
                const SizedBox(height: 12),
                _ErrorLabel(message: _error),
                const Spacer(),
                _BotonContinuar(
                  loading:   _loading,
                  onPressed: _loading ? null : _enviarCodigo,
                ),
                const SizedBox(height: 32),
                _PoliticaPrivacidad(),
                const SizedBox(height: 16),
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
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Tu número\nde celular',
          style: const TextStyle(
            color:      FretixColors.textPrimary,
            fontSize:   32,
            fontWeight: FontWeight.w800,
            height:     1.15,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Te enviaremos un código de verificación\npor SMS.',
          style: TextStyle(
            color:    FretixColors.textSecondary,
            fontSize: 15,
            height:   1.5,
          ),
        ),
      ],
    );
  }
}

class _PhoneField extends StatelessWidget {
  const _PhoneField({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onChanged,
    this.error,
  });

  final TextEditingController                controller;
  final FocusNode                            focusNode;
  final VoidCallback?                        onSubmit;
  final ValueChanged<String>                 onChanged;
  final String?                              error;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Prefijo país
        Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color:        FretixColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: error != null
                  ? FretixColors.danger
                  : FretixColors.surfaceBorder,
            ),
          ),
          alignment: Alignment.center,
          child: const Text(
            '🇦🇷 +54',
            style: TextStyle(
              color:      FretixColors.textPrimary,
              fontSize:   16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Campo de número
        Expanded(
          child: TextFormField(
            controller:   controller,
            focusNode:    focusNode,
            onChanged:    onChanged,
            onFieldSubmitted: (_) => onSubmit?.call(),
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d\s\-\(\)]')),
              LengthLimitingTextInputFormatter(14),
            ],
            style: const TextStyle(
              color:      FretixColors.textPrimary,
              fontSize:   20,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
            decoration: InputDecoration(
              hintText:     '261 478 3921',
              hintStyle: const TextStyle(
                color:      FretixColors.textMuted,
                fontSize:   20,
                fontWeight: FontWeight.w400,
                letterSpacing: 1.5,
              ),
              filled:     true,
              fillColor:  FretixColors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical:   17,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   const BorderSide(color: FretixColors.surfaceBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: error != null
                      ? FretixColors.danger
                      : FretixColors.surfaceBorder,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: error != null
                      ? FretixColors.danger
                      : FretixColors.accent,
                  width: 1.5,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   const BorderSide(color: FretixColors.danger),
              ),
            ),
          ),
        ),
      ],
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
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Text(
                message!,
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

class _BotonContinuar extends StatelessWidget {
  const _BotonContinuar({
    required this.loading,
    required this.onPressed,
  });

  final bool        loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width:  double.infinity,
      height: 56,
      child: ElevatedButton(
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
                  'Continuar',
                  style: TextStyle(
                    fontSize:   17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

class _PoliticaPrivacidad extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      'Al continuar aceptás los Términos de uso y\nPolítica de privacidad de Fretix.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color:    FretixColors.textMuted,
        fontSize: 12,
        height:   1.6,
      ),
    );
  }
}

// ─── Argumento de ruta ────────────────────────────────────────────────────────
class OtpArgs {
  const OtpArgs({required this.phone, required this.verificationId});
  final String phone;
  final String verificationId;
}
