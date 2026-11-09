import 'package:flutter/material.dart';

/// Paleta del tablero: la misma familia que la app móvil (oscura: se lee durante horas en una sala de
/// operaciones y no deslumbra). El color de urgencia nunca va solo: siempre lo acompaña el texto P1–P4.
abstract final class DashColors {
  static const Color bg = Color(0xFF12161C);
  static const Color sos = Color(0xFFD23B2E);
  static const Color surface = Color(0xFF1B222B);
  static const Color surfaceHigh = Color(0xFF263241);
  static const Color border = Color(0xFF3F4C5E);
  static const Color text = Color(0xFFEEF1F5);
  static const Color muted = Color(0xFFA9B4C2);
  static const Color ok = Color(0xFF4CC38A);
  static const Color warn = Color(0xFFF2B544);
  static const Color warnBg = Color(0xFF3A2F12);
  static const Color danger = Color(0xFFE0584B);
  static const Color dangerBg = Color(0xFF3B1B19);

  static Color urgency(String u) => switch (u) {
    'P1' => const Color(0xFFD23B2E),
    'P2' => const Color(0xFFF2B544),
    'P3' => const Color(0xFF4FA3D1),
    _ => const Color(0xFF7C8896),
  };

  /// Color del texto sobre el color de urgencia (contraste suficiente en los cuatro).
  static Color onUrgency(String u) => u == 'P2' ? const Color(0xFF1B1405) : Colors.white;
}

/// Cifras que no «bailan» al cambiar: los contadores se actualizan solos cada pocos segundos.
const List<FontFeature> kTabular = [FontFeature.tabularFigures()];

ThemeData dashTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: DashColors.bg,
    colorScheme: const ColorScheme.dark(primary: DashColors.ok, surface: DashColors.surface, onSurface: DashColors.text, error: DashColors.danger),
    appBarTheme: const AppBarTheme(
      backgroundColor: DashColors.bg,
      foregroundColor: DashColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: .5, color: DashColors.text),
    ),
    textTheme: base.textTheme.apply(bodyColor: DashColors.text, displayColor: DashColors.text),
    dividerColor: DashColors.border,
    dialogTheme: const DialogThemeData(backgroundColor: DashColors.surface),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DashColors.surfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashColors.border)),
    ),
  );
}
