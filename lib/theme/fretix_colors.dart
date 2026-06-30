import 'package:flutter/material.dart';

/// Tokens de color de diseño de Fretix.
/// Fuente única de verdad — nunca usar Color(0x...) inline en los widgets.
abstract class FretixColors {
  static const background    = Color(0xFF0D0D0D);
  static const surface       = Color(0xFF1A1A1A);
  static const surfaceBorder = Color(0xFF2A2A2A);
  static const accent        = Color(0xFFD4A373); // Cobre Fretix Premium — migrado 2026-06-30
  static const accentDark    = Color(0xFFB8885A); // oscurecido para mantener relación con accent
  static const success       = Color(0xFF22C55E);
  static const danger        = Color(0xFFEF4444);
  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF888888);
  static const textMuted     = Color(0xFF444444);
  static const countdown     = Color(0xFFEF4444);
}
