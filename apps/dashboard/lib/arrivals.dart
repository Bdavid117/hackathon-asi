import 'models.dart';

/// Cuántas novedades hay y cuántas son P1, para decirlo en una línea.
class ArrivalsSummary {
  const ArrivalsSummary(this.count, this.p1);

  final int count;
  final int p1;

  /// «3 novedades (2 P1)»; vacío si no hay ninguna.
  String get label => count == 0 ? '' : '$count ${count == 1 ? 'novedad' : 'novedades'}${p1 == 0 ? '' : ' ($p1 P1)'}';
}

/// Novedades: lo que el NODO recibió después de que la persona lo viera por última vez.
///
/// Se compara la hora de recepción del propio nodo (`receivedAt`), nunca los identificadores —que cambian cuando
/// dos incidentes se funden y darían falsas «novedades»— ni el reloj de este navegador. La primera lectura (y la
/// primera después de cambiar de vista) fija la marca y no avisa de nada: lo que ya estaba no es nuevo. Las novedades
/// se acumulan hasta que alguien las ve; nada se reordena ni se mueve: sólo se avisa.
class Arrivals {
  bool _initialized = false;
  int _ack = 0;

  static int _latest(List<IncidentRow> rows) {
    var m = 0;
    for (final r in rows) {
      final t = r.receivedAt;
      if (t != null && t > m) m = t;
    }
    return m;
  }

  /// Se llama con cada lectura; sólo la primera tras abrir o tras [reset] hace algo (fija la marca).
  void observe(List<IncidentRow> rows) {
    if (_initialized) return;
    _initialized = true;
    _ack = _latest(rows);
  }

  /// La persona ya vio todo lo que hay.
  void acknowledge(List<IncidentRow> rows) {
    _initialized = true;
    final t = _latest(rows);
    if (t > _ack) _ack = t;
  }

  /// Cambió la vista (otro modo o filtro del nodo): la próxima lectura no avisa de nada.
  void reset() {
    _initialized = false;
    _ack = 0;
  }

  /// Lo que llegó después de la marca, lo más urgente primero (a igual urgencia, lo más reciente).
  List<IncidentRow> news(List<IncidentRow> rows) {
    final out = [for (final r in rows) if (r.receivedAt != null && r.receivedAt! > _ack) r];
    out.sort((a, b) {
      final u = kUrgencies.indexOf(a.urgency).compareTo(kUrgencies.indexOf(b.urgency));
      return u != 0 ? u : b.receivedAt!.compareTo(a.receivedAt!);
    });
    return out;
  }

  ArrivalsSummary summary(List<IncidentRow> rows) {
    final n = news(rows);
    return ArrivalsSummary(n.length, n.where((r) => r.urgency == 'P1').length);
  }
}
