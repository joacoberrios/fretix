import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'fretix_colors.dart';

abstract class FretixTheme {
  static ThemeData dark() {
    return ThemeData(
      useMaterial3:     true,
      brightness:       Brightness.dark,
      scaffoldBackgroundColor: FretixColors.background,
      colorScheme: const ColorScheme.dark(
        primary:    FretixColors.accent,
        secondary:  FretixColors.accent,
        surface:    FretixColors.surface,
        error:      FretixColors.danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor:  FretixColors.background,
        foregroundColor:  FretixColors.textPrimary,
        elevation:        0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor:           Colors.transparent,
          statusBarIconBrightness:  Brightness.light,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: FretixColors.accent,
          foregroundColor: Colors.black,
          elevation:       0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled:    true,
        fillColor: FretixColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: FretixColors.surfaceBorder),
        ),
      ),
      fontFamily: 'Inter',   // Agregar Inter en pubspec.yaml → google_fonts o assets
    );
  }
}
