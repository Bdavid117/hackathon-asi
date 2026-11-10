import 'dart:convert';
import 'dart:io';

/// Una partida del gasto de API.
class LedgerEntry {
  const LedgerEntry({required this.run, required this.date, required this.usd, required this.note, this.estimated = false});

  final String run;
  final String date;

  /// Dólares. Negativo sólo en un ajuste a la consola.
  final double usd;
  final String note;

  /// La cifra es una estimación (no la midió el programa).
  final bool estimated;

  Map<String, Object?> toJson() => {'run': run, 'date': date, 'usd': usd, 'note': note, 'estimated': estimated};
}

/// El REGISTRO de gasto de la API de Anthropic: lo que se ha gastado según el propio programa (la consola de Anthropic manda), con un
/// tope total y una reserva. FALLA CERRADO: un archivo ausente o corrupto no se toma por «0 gastado», y [guard] se niega a lanzar una
/// corrida si lo gastado más su tope pasa del límite menos la reserva. Nunca guarda nada que parezca una clave.
class ApiLedger {
  ApiLedger._(this.path, this.entries);

  final String path;
  final List<LedgerEntry> entries;

  static ApiLedger load(String path) {
    final f = File(path);
    if (!f.existsSync()) throw StateError('no existe el registro de gasto ($path): sin él no se gasta (no se asume 0)');
    final Object? raw;
    try {
      raw = jsonDecode(f.readAsStringSync());
    } on FormatException catch (e) {
      throw StateError('el registro de gasto ($path) está corrupto: ${e.message}');
    }
    final list = raw is Map ? raw['entries'] : null;
    if (list is! List) throw StateError('el registro de gasto ($path) no tiene «entries»');
    final out = <LedgerEntry>[];
    for (final e in list) {
      if (e is! Map || e['run'] is! String || e['usd'] is! num || !(e['usd']! as num).isFinite) throw StateError('el registro de gasto ($path) tiene una partida inválida: $e');
      final usd = (e['usd']! as num).toDouble();
      if (usd < 0 && e['run'] != 'ajuste a la consola') throw StateError('el registro de gasto ($path) tiene un importe negativo que no es un ajuste: $e');
      out.add(LedgerEntry(run: e['run']! as String, date: e['date'] is String ? e['date']! as String : '?', usd: usd, note: e['note'] is String ? e['note']! as String : '', estimated: e['estimated'] == true));
    }
    return ApiLedger._(path, out);
  }

  double get spentUsd => entries.fold(0.0, (a, e) => a + e.usd);

  /// Se niega (StateError) si `gastado + runCapUsd > totalCapUsd − reserveUsd`. El tope por corrida no es estrictamente duro (una
  /// llamada en vuelo puede pasarlo un poco): por eso hay reserva.
  void guard({required double runCapUsd, double totalCapUsd = 50, double reserveUsd = 10}) {
    if (!(runCapUsd > 0) || !runCapUsd.isFinite) throw ArgumentError.value(runCapUsd, 'runCapUsd', 'el tope de la corrida debe ser positivo');
    final limit = totalCapUsd - reserveUsd;
    if (spentUsd + runCapUsd > limit + 1e-9) {
      throw StateError(
        'no se lanza: ya gastado ${spentUsd.toStringAsFixed(2)} + tope de la corrida ${runCapUsd.toStringAsFixed(2)} pasa de ${limit.toStringAsFixed(2)} '
        '(límite total ${totalCapUsd.toStringAsFixed(2)} menos reserva ${reserveUsd.toStringAsFixed(2)}). La consola de Anthropic manda: compruébala.',
      );
    }
  }

  static final RegExp _looksLikeSecret = RegExp(r'sk-[A-Za-z0-9_-]{16,}|Bearer\s+\S{16,}|[A-Za-z0-9_-]{40,}');

  void record({required String run, required double usd, required String note, bool estimated = false, DateTime? at}) {
    if (!usd.isFinite || usd < 0) throw ArgumentError.value(usd, 'usd', 'un gasto es un importe finito y no negativo (para corregir a la baja, reconcileTo)');
    _add(run, usd, note, estimated, at);
  }

  /// Ajusta el total al que dice la consola con una partida «ajuste a la consola» (puede ser negativa).
  void reconcileTo({required double consoleUsd, required String note, DateTime? at}) {
    if (!consoleUsd.isFinite || consoleUsd < 0) throw ArgumentError.value(consoleUsd, 'consoleUsd', 'la cifra de la consola debe ser finita y no negativa');
    _add('ajuste a la consola', consoleUsd - spentUsd, note, false, at);
  }

  void _add(String run, double usd, String note, bool estimated, DateTime? at) {
    if (_looksLikeSecret.hasMatch(run) || _looksLikeSecret.hasMatch(note)) throw ArgumentError('el registro de gasto no guarda nada que parezca una clave');
    final d = (at ?? DateTime.now()).toIso8601String().substring(0, 10);
    entries.add(LedgerEntry(run: run, date: d, usd: usd, note: note, estimated: estimated));
  }

  /// Ejecuta una corrida de PAGO bajo el registro: [guard] antes (si se niega, [body] ni se llama); después anota el gasto REAL
  /// ([costOf]) y guarda; y si [body] falla anota el TOPE entero como estimación conservadora (no se sabe cuánto alcanzó a gastar) y
  /// relanza el error: el registro nunca queda por debajo de la realidad.
  Future<T> spend<T>({
    required String run,
    required double capUsd,
    required Future<T> Function() body,
    required double Function(T result) costOf,
    required String Function(T result) noteOf,
    double totalCapUsd = 50,
    double reserveUsd = 10,
  }) async {
    guard(runCapUsd: capUsd, totalCapUsd: totalCapUsd, reserveUsd: reserveUsd);
    final T result;
    try {
      result = await body();
    } on Object {
      record(run: run, usd: capUsd, note: 'la corrida falló: se anota el tope entero como estimación conservadora; comprueba la consola', estimated: true);
      save();
      rethrow;
    }
    // Lo gastado se anota SIEMPRE: un defecto al armar la partida (una nota que parece una clave, un importe inválido) no puede dejar
    // el registro por debajo de la realidad después de haber pagado.
    var usd = capUsd;
    var estimated = true;
    var note = 'el importe de la corrida no era válido: se anota el tope entero como estimación conservadora; comprueba la consola';
    try {
      final cost = costOf(result);
      if (cost.isFinite && cost >= 0) {
        usd = cost;
        estimated = false;
        try {
          note = noteOf(result);
          if (_looksLikeSecret.hasMatch(note)) note = '(nota omitida: parecía una clave)';
        } on Object {
          note = '(nota omitida: no se pudo armar)';
        }
      }
    } on Object {
      // se queda con el tope como estimación
    }
    record(run: run, usd: usd, note: note, estimated: estimated);
    save();
    return result;
  }

  /// Escribe el archivo de forma atómica (temporal + renombrado).
  void save() {
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
      'nota': 'Gasto de la API de Anthropic según el propio programa; la consola de Anthropic manda. Sólo importes, fechas y notas: jamás claves.',
      'entries': [for (final e in entries) e.toJson()],
    })}\n');
    tmp.renameSync(path);
  }
}
