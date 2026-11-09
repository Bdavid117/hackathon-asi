import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Un hecho inmutable. `id` = `<origen>:<seq con 6 dígitos>`.
class Event {
  const Event({
    required this.id,
    required this.origin,
    required this.seq,
    required this.type,
    this.reportKey,
    this.rev,
    required this.hlc,
    this.body = const {},
    this.inputs = const [],
  });

  factory Event.fromJson(Map<String, Object?> j) => Event(
        id: j['id']! as String,
        origin: j['origin']! as String,
        seq: j['seq']! as int,
        type: j['type']! as String,
        reportKey: j['reportKey'] as String?,
        rev: j['rev'] as int?,
        hlc: j['hlc']! as String,
        body: (j['body']! as Map).cast<String, Object?>(),
        inputs: (j['inputs']! as List).cast<String>(),
      );

  final String id;
  final String origin;
  final int seq;
  final String type;
  final String? reportKey;
  final int? rev;

  /// En B1 sólo se usa como marca de tiempo: `<ms>-<seq>-<origen>`.
  final String hlc;
  final Map<String, Object?> body;
  final List<String> inputs;

  Map<String, Object?> toJson() => {
        'id': id,
        'origin': origin,
        'seq': seq,
        'type': type,
        'reportKey': reportKey,
        'rev': rev,
        'hlc': hlc,
        'body': body,
        'inputs': inputs,
      };
}

/// Un evento por escribir con [EventLog.appendAll].
class NewEvent {
  const NewEvent(this.type, this.body, {this.reportKey, this.rev, this.inputs = const [], this.chainPrevious = false});

  final String type;
  final Map<String, Object?> body;
  final String? reportKey;
  final int? rev;
  final List<String> inputs;

  /// Añade a `inputs` el id del evento anterior del mismo lote.
  final bool chainPrevious;
}

/// Log de eventos que sólo crece (SQLite en WAL, `synchronous=FULL`).
///
/// Cada nodo numera sus propios eventos; los de otros nodos llegan con
/// [appendReplicated]. Nada se modifica ni se borra: la tabla lo impide con *triggers*.
class EventLog {
  EventLog._(this._db, this.nodeId, this._clock);

  /// Abre (o crea) el log en [path]. `':memory:'` abre una base en memoria.
  static EventLog open(String path, {required String nodeId, DateTime Function()? clock}) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('''
      CREATE TABLE IF NOT EXISTS events(
        origin TEXT NOT NULL,
        seq INTEGER NOT NULL,
        type TEXT NOT NULL,
        report_key TEXT,
        rev INTEGER,
        hlc TEXT NOT NULL,
        body TEXT NOT NULL,
        inputs TEXT NOT NULL,
        PRIMARY KEY (origin, seq)
      )''');
    db.execute('CREATE INDEX IF NOT EXISTS events_report ON events(report_key, rev)');
    db.execute('CREATE INDEX IF NOT EXISTS events_type ON events(type)');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
      BEGIN SELECT RAISE(ABORT, 'events es append-only'); END''');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
      BEGIN SELECT RAISE(ABORT, 'events es append-only'); END''');
    return EventLog._(db, nodeId, clock ?? DateTime.now);
  }

  final Database _db;
  final String nodeId;
  final DateTime Function() _clock;

  static String idOf(String origin, int seq) => '$origin:${seq.toString().padLeft(6, '0')}';

  /// Añade un evento propio. Está confirmado en disco cuando la función retorna.
  Event append(
    String type,
    Map<String, Object?> body, {
    String? reportKey,
    int? rev,
    List<String> inputs = const [],
  }) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final next = _db.select('SELECT COALESCE(MAX(seq), 0) + 1 AS n FROM events WHERE origin = ?', [nodeId]).first['n'] as int;
      final e = Event(
        id: idOf(nodeId, next),
        origin: nodeId,
        seq: next,
        type: type,
        reportKey: reportKey,
        rev: rev,
        hlc: '${_clock().millisecondsSinceEpoch}-$next-$nodeId',
        body: body,
        inputs: inputs,
      );
      _insert(e);
      _db.execute('COMMIT');
      return e;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Escribe varios eventos propios en **una sola transacción** (un solo `fsync`): o quedan todos o
  /// ninguno, con ids consecutivos. Un evento con `chainPrevious` apunta al anterior del lote.
  List<Event> appendAll(List<NewEvent> specs) {
    if (specs.isEmpty) return const [];
    _db.execute('BEGIN IMMEDIATE');
    try {
      var next = _db.select('SELECT COALESCE(MAX(seq), 0) + 1 AS n FROM events WHERE origin = ?', [nodeId]).first['n'] as int;
      final out = <Event>[];
      for (final sp in specs) {
        final e = Event(
          id: idOf(nodeId, next),
          origin: nodeId,
          seq: next,
          type: sp.type,
          reportKey: sp.reportKey,
          rev: sp.rev,
          hlc: '${_clock().millisecondsSinceEpoch}-$next-$nodeId',
          body: sp.body,
          inputs: [...sp.inputs, if (sp.chainPrevious && out.isNotEmpty) out.last.id],
        );
        _insert(e);
        out.add(e);
        next++;
      }
      _db.execute('COMMIT');
      return out;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Aplica un evento recibido de un par. Devuelve `true` sólo si es nuevo.
  ///
  /// Un evento con el origen de este nodo que no esté ya en el log no puede venir de
  /// otro sitio: lanza [StateError].
  bool appendReplicated(Event e) {
    if (has(e.id)) return false;
    if (e.origin == nodeId) {
      throw StateError('evento ${e.id} con el origen de este nodo y desconocido');
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      _insert(e, ignoreDuplicates: true);
      final added = _db.updatedRows > 0;
      _db.execute('COMMIT');
      return added;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _insert(Event e, {bool ignoreDuplicates = false}) {
    _db.execute(
      'INSERT ${ignoreDuplicates ? 'OR IGNORE ' : ''}INTO events(origin, seq, type, report_key, rev, hlc, body, inputs) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [e.origin, e.seq, e.type, e.reportKey, e.rev, e.hlc, jsonEncode(e.body), jsonEncode(e.inputs)],
    );
  }

  bool has(String eventId) {
    final i = eventId.lastIndexOf(':');
    if (i < 0) return false;
    final seq = int.tryParse(eventId.substring(i + 1));
    if (seq == null) return false;
    return _db.select('SELECT 1 FROM events WHERE origin = ? AND seq = ?', [eventId.substring(0, i), seq]).isNotEmpty;
  }

  Event _row(Row r) => Event(
        id: idOf(r['origin'] as String, r['seq'] as int),
        origin: r['origin'] as String,
        seq: r['seq'] as int,
        type: r['type'] as String,
        reportKey: r['report_key'] as String?,
        rev: r['rev'] as int?,
        hlc: r['hlc'] as String,
        body: (jsonDecode(r['body'] as String) as Map).cast<String, Object?>(),
        inputs: (jsonDecode(r['inputs'] as String) as List).cast<String>(),
      );

  /// El evento de [type] para ([reportKey], [rev]), o `null` si no existe.
  Event? find(String type, String reportKey, int rev) {
    final rows = _db.select(
      'SELECT * FROM events WHERE type = ? AND report_key = ? AND rev = ? ORDER BY rowid LIMIT 1',
      [type, reportKey, rev],
    );
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// Eventos de [origin] con `seq > afterSeq`, en orden.
  List<Event> readAfter(String origin, int afterSeq, {int limit = 500}) => _db
      .select('SELECT * FROM events WHERE origin = ? AND seq > ? ORDER BY seq LIMIT ?', [origin, afterSeq, limit])
      .map(_row)
      .toList();

  /// Todos los eventos, en el orden en que entraron en este log.
  List<Event> all() => _db.select('SELECT * FROM events ORDER BY rowid').map(_row).toList();

  /// Los eventos de un tipo, en orden de llegada (sin leer todo el log).
  List<Event> allOfType(String type) => _db.select('SELECT * FROM events WHERE type = ? ORDER BY rowid', [type]).map(_row).toList();

  /// Cuántos eventos hay de estos tipos (sin cargarlos).
  int countOfTypes(List<String> types) {
    if (types.isEmpty) return 0;
    final marks = List.filled(types.length, '?').join(',');
    return _db.select('SELECT COUNT(*) AS c FROM events WHERE type IN ($marks)', types).first['c'] as int;
  }

  /// Número de eventos del log (sin cargarlos).
  int count() => _db.select('SELECT COUNT(*) AS c FROM events').first['c'] as int;

  /// Por origen, el mayor `seq` tal que todos los anteriores también están.
  Map<String, int> versionVector() {
    final out = <String, int>{};
    for (final r in _db.select('SELECT origin, COUNT(*) AS c, MAX(seq) AS m FROM events GROUP BY origin')) {
      final origin = r['origin'] as String;
      if (r['c'] == r['m']) {
        out[origin] = r['m'] as int;
        continue;
      }
      var expected = 1;
      for (final s in _db.select('SELECT seq FROM events WHERE origin = ? ORDER BY seq', [origin])) {
        if (s['seq'] != expected) break;
        expected++;
      }
      out[origin] = expected - 1;
    }
    return out;
  }

  void close() => _db.close();
}
