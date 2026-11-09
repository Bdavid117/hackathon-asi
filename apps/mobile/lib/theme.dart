import 'package:flutter/material.dart';

/// Paleta de SARD. Oscura a propósito: ahorra batería en pantallas OLED y no deslumbra de noche.
/// Los colores de estado llevan significado (verde = ya salió, ámbar = espera, rojo = SOS) y nunca
/// van solos: cada uno va con un icono y un texto.
///
/// Contrastes medidos contra su fondo (WCAG): texto 15:1 sobre `bg`; apagado 7:1 sobre
/// `surface`; verde 7,5:1 y ámbar 9:1 sobre `surface`; blanco sobre `sos` 4,9:1.
abstract final class SardColors {
  static const Color bg = Color(0xFF12161C);
  static const Color surface = Color(0xFF1B222B);
  static const Color surfaceHigh = Color(0xFF263241);
  static const Color border = Color(0xFF3F4C5E);
  static const Color text = Color(0xFFEEF1F5);
  static const Color muted = Color(0xFFA9B4C2);
  static const Color sos = Color(0xFFD23B2E);
  static const Color ok = Color(0xFF4CC38A);
  static const Color wait = Color(0xFFF2B544);
}

ThemeData sardTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: SardColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: SardColors.ok,
      surface: SardColors.surface,
      onSurface: SardColors.text,
      error: SardColors.sos,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: SardColors.bg,
      foregroundColor: SardColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
        color: SardColors.text,
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: SardColors.text,
      displayColor: SardColors.text,
    ),
  );
}
