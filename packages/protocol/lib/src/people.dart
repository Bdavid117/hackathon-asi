/// Cuántas personas afectadas indica quien reporta. Es una **escala**, no un número exacto: en una
/// emergencia nadie cuenta con precisión y un rango se contesta con un toque.
///
/// El código viaja en los 3 bits `peopleBucket` de la trama (0..7); aquí se usan 0..5. Los códigos
/// 6 y 7 quedan reservados: una versión futura podría definirlos, y por eso [fromCode] los lee como
/// «no indicado» en lugar de fallar. Los códigos son parte del formato en el cable: no se reordenan.
enum PeopleBucket {
  unknown(0, 'No indicado'),
  one(1, '1'),
  twoToFive(2, '2–5'),
  sixToTwenty(3, '6–20'),
  twentyOneToHundred(4, '21–100'),
  overHundred(5, 'Más de 100');

  const PeopleBucket(this.code, this.label);

  /// Valor que viaja en la trama.
  final int code;

  /// Texto para la persona (la app) y para el coordinador (el tablero).
  final String label;

  /// El cajón de un código recibido. Lo desconocido (reservado, fuera de rango, ausente) es
  /// «no indicado»: ni rompe ni inventa una cifra.
  static PeopleBucket fromCode(int? code) {
    for (final b in values) {
      if (b.code == code) return b;
    }
    return unknown;
  }

  /// El cajón de una cantidad conocida. Cero o negativo no es una cantidad: «no indicado».
  static PeopleBucket fromCount(int n) {
    if (n <= 0) return unknown;
    if (n == 1) return one;
    if (n <= 5) return twoToFive;
    if (n <= 20) return sixToTwenty;
    if (n <= 100) return twentyOneToHundred;
    return overHundred;
  }
}
