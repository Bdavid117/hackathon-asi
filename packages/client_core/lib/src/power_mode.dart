/// Cuánto debe hacer la app según la batería que queda (PDF §5.6).
enum PowerMode {
  /// Batería ≥ 20 %: todo activo.
  normal,

  /// Batería < 20 % (el umbral del enunciado): refresco más lento y aviso al usuario.
  saver,

  /// Batería < 5 %: sólo el botón SOS y su envío.
  sosOnly,
}

/// Modo de energía para un porcentaje. Un porcentaje desconocido (`null`) cuenta como
/// [PowerMode.normal]: no se recorta la función por no saber.
PowerMode powerModeFor(int? percent) {
  if (percent == null) return PowerMode.normal;
  if (percent < 5) return PowerMode.sosOnly;
  if (percent < 20) return PowerMode.saver;
  return PowerMode.normal;
}

/// Batería cuantizada a 4 bits (0..15) para la trama. Si no se conoce, se envía [unknown]
/// (el valor marcador del PDF), nunca un número inventado.
int batteryQFromPercent(int? percent, {int unknown = 15}) {
  if (percent == null) return unknown;
  return (percent.clamp(0, 100) * 15 / 100).round();
}
