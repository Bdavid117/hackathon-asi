import 'dart:math';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

/// Estado de una trama en la bandeja de salida (PDF §5.4).
enum OutboxState { queued, sending, sent, confirmed, expired }

/// Lo que el ciudadano captura. Una revisión vuelve a enviar **todos** los campos.
class NewReport {
  const NewReport({
    required this.incidentType,
    required this.flags,
    required this.peopleBucket,
    required this.batteryQ,
    required this.locQuality,
    this.lat,
    this.lon,
    this.text,
  });

  final int incidentType;
  final int flags;
  final int peopleBucket;
  final int batteryQ;
  final LocQuality locQuality;
  final double? lat;
  final double? lon;
  final String? text;
}

class OutboxEntry {
  const OutboxEntry({
    required this.frameSeq,
    required this.reportKey,
    required this.rev,
    required this.prioHint,
    required this.state,
    required this.attempts,
    required this.nextTryAt,
    required this.frame,
    required this.createdAt,
  });

  final int frameSeq;
  final String reportKey;
  final int rev;
  final int prioHint;
  final OutboxState state;
  final int attempts;
  final DateTime? nextTryAt;
  final Uint8List frame;
  final DateTime createdAt;
}

/// Bandeja de salida durable (SQLite, WAL, `synchronous=FULL`).
///
/// Una entrada sólo se devuelve después de que su transacción haya confirmado: lo que la
/// pantalla muestre como «Guardado» ya está en disco.
class Outbox {
  Outbox._(this._db, this._key, this.deviceId);

  /// Abre (o crea) la bandeja. Devuelve a `queued` toda entrada que encuentre en `sending`:
  /// un cierre brusco con una trama en vuelo no puede dejar un reporte varado.
  static Outbox open(String path, {required Uint8List key}) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v)');
    db.execute('CREATE TABLE IF NOT EXISTS report(report_id TEXT PRIMARY KEY, rev INTEGER NOT NULL, created_at INTEGER NOT NULL)');
    db.execute('''
      CREATE TABLE IF NOT EXISTS outbox(
        frame_seq INTEGER PRIMARY KEY,
        report_id TEXT NOT NULL,
        rev INTEGER NOT NULL,
        prio_hint INTEGER NOT NULL,
        state TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_try_at INTEGER,
        ttl_at INTEGER,
        last_error TEXT,
        frame BLOB NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE (report_id, rev)
      )''');
    db.execute('CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(state, next_try_at)');

    Uint8List id;
    final row = db.select("SELECT v FROM meta WHERE k = 'device_id'");
    if (row.isEmpty) {
      final rng = Random.secure();
      id = Uint8List.fromList([for (var i = 0; i < 8; i++) rng.nextInt(256)]);
      db.execute("INSERT INTO meta(k, v) VALUES ('device_id', ?)", [id]);
      db.execute("INSERT INTO meta(k, v) VALUES ('next_seq', 1)");
    } else {
      id = Uint8List.fromList(row.first['v'] as List<int>);
    }
    db.execute("UPDATE outbox SET state = 'queued' WHERE state = 'sending'");
    return Outbox._(db, key, id);
  }

  final Database _db;
  final Uint8List _key;

  /// Lo que lleva una trama de esta bandeja (indicadores, ubicación, revisión), para mostrárselo
  /// a la persona. Verifica la etiqueta con la clave de la bandeja.
  ReportFrame reportOf(OutboxEntry e) => decodeReportFrame(e.frame, _key);

  /// Identificador aleatorio de 8 bytes de esta instalación.
  final Uint8List deviceId;

  String get _deviceHex => deviceIdToHex(deviceId);

  T _tx<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Encola un reporte nuevo (revisión 0).
  OutboxEntry enqueueSos(NewReport r, {required DateTime now}) =>
      _tx(() => _insert(r, now: now, rev: 0, refSeq: null));

  /// Encola una revisión de un reporte ya existente de este dispositivo.
  OutboxEntry enqueueRevision(String reportKey, NewReport r, {required DateTime now}) => _tx(() {
        final dash = reportKey.lastIndexOf('-');
        final ref = dash < 0 ? null : int.tryParse(reportKey.substring(dash + 1));
        if (ref == null || reportKey.substring(0, dash) != _deviceHex) {
          throw ArgumentError.value(reportKey, 'reportKey', 'no es un reporte de este dispositivo');
        }
        final row = _db.select('SELECT rev FROM report WHERE report_id = ?', [reportKey]);
        if (row.isEmpty) throw ArgumentError.value(reportKey, 'reportKey', 'reporte desconocido');
        final next = (row.first['rev'] as int) + 1;
        if (next > 255) throw StateError('un reporte admite como máximo 255 revisiones');
        return _insert(r, now: now, rev: next, refSeq: ref);
      });

  OutboxEntry _insert(NewReport r, {required DateTime now, required int rev, required int? refSeq}) {
    final seq = _db.select("SELECT v FROM meta WHERE k = 'next_seq'").first['v'] as int;
    final reportKey = rev == 0 ? '$_deviceHex-$seq' : '$_deviceHex-$refSeq';
    final prio = prioHintFromFlags(r.flags);
    final frame = encodeReportFrame(
      ReportFrame(
        deviceId: deviceId,
        seq: seq,
        rev: rev,
        refSeq: refSeq,
        prioHint: prio,
        incidentType: r.incidentType,
        flags: r.flags,
        peopleBucket: r.peopleBucket,
        locQuality: r.locQuality,
        lat: r.lat,
        lon: r.lon,
        // Un reloj absurdo (reiniciado a 1970, desfasado) no puede impedir guardar un SOS: se acota.
        capturedAt: (now.millisecondsSinceEpoch ~/ 1000).clamp(0, 4294967295),
        batteryQ: r.batteryQ,
        text: r.text,
      ),
      _key,
    );
    final ms = now.millisecondsSinceEpoch;
    _db.execute(
      "INSERT INTO outbox(frame_seq, report_id, rev, prio_hint, state, attempts, frame, created_at) VALUES (?, ?, ?, ?, 'queued', 0, ?, ?)",
      [seq, reportKey, rev, prio, frame, ms],
    );
    if (rev == 0) {
      _db.execute('INSERT INTO report(report_id, rev, created_at) VALUES (?, 0, ?)', [reportKey, ms]);
    } else {
      _db.execute('UPDATE report SET rev = ? WHERE report_id = ?', [rev, reportKey]);
    }
    _db.execute("UPDATE meta SET v = ? WHERE k = 'next_seq'", [seq + 1]);
    return _entry(_db.select('SELECT * FROM outbox WHERE frame_seq = ?', [seq]).first);
  }

  OutboxEntry _entry(Row r) => OutboxEntry(
        frameSeq: r['frame_seq'] as int,
        reportKey: r['report_id'] as String,
        rev: r['rev'] as int,
        prioHint: r['prio_hint'] as int,
        state: OutboxState.values.byName(r['state'] as String),
        attempts: r['attempts'] as int,
        nextTryAt: r['next_try_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['next_try_at'] as int),
        frame: Uint8List.fromList(r['frame'] as List<int>),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  /// Entradas listas para enviar: `queued` cuyo `nextTryAt` ya venció.
  ///
  /// Orden: prioridad efectiva (la del reporte menos un nivel por cada [agingStep] que lleva
  /// esperando, con suelo en P2: sólo un P1 de origen es P1), luego antigüedad. **Cuota anti-inanición:** cada [quotaEvery]
  /// posiciones del lote (la 5.ª, la 10.ª…) se reservan para los pendientes más antiguos que
  /// aún no estén en él, de modo que la urgencia nunca deja morir a los casos leves.
  List<OutboxEntry> due(
    DateTime now, {
    int limit = 8,
    Duration agingStep = const Duration(minutes: 10),
    int quotaEvery = 5,
  }) {
    final ready = _db
        .select(
          "SELECT * FROM outbox WHERE state = 'queued' AND (next_try_at IS NULL OR next_try_at <= ?)",
          [now.millisecondsSinceEpoch],
        )
        .map(_entry)
        .toList();
    int effective(OutboxEntry e) {
      final waited = now.difference(e.createdAt).inMicroseconds;
      final levels = waited <= 0 ? 0 : waited ~/ agingStep.inMicroseconds;
      // Esperar sube la prioridad pero nunca por encima de P2: un caso leve muy antiguo no
      // adelanta a un P1 (la cuota ya garantiza que no muera de inanición).
      return e.prioHint == 0 ? 0 : max(1, e.prioHint - levels);
    }

    ready.sort((a, b) {
      final p = effective(a).compareTo(effective(b));
      if (p != 0) return p;
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.frameSeq.compareTo(b.frameSeq);
    });
    final batch = ready.take(limit).toList();
    if (quotaEvery > 0) {
      final oldest = [...ready]..sort((a, b) {
          final c = a.createdAt.compareTo(b.createdAt);
          return c != 0 ? c : a.frameSeq.compareTo(b.frameSeq);
        });
      final included = {for (final e in batch) e.frameSeq};
      for (var pos = quotaEvery; pos <= limit && pos <= batch.length; pos += quotaEvery) {
        // Si el que ocupa la posición ya es de los más antiguos, no hace falta tocarla.
        final candidate = oldest.where((e) => !included.contains(e.frameSeq)).firstOrNull;
        if (candidate == null) break;
        included.remove(batch[pos - 1].frameSeq);
        batch[pos - 1] = candidate;
        included.add(candidate.frameSeq);
      }
    }
    return batch;
  }

  void markSending(int frameSeq) =>
      _db.execute("UPDATE outbox SET state = 'sending' WHERE frame_seq = ? AND state = 'queued'", [frameSeq]);

  /// El intento falló: cuenta el intento y reprograma el siguiente.
  void markFailed(int frameSeq, {required DateTime nextTryAt}) => _db.execute(
        "UPDATE outbox SET state = 'queued', attempts = attempts + 1, next_try_at = ? WHERE frame_seq = ? AND state IN ('queued', 'sending')",
        [nextTryAt.millisecondsSinceEpoch, frameSeq],
      );

  /// Reaparece la señal: lo que esperaba un reintento vuelve a estar vencido. No cambia los
  /// intentos contados, así que si la señal resulta mala el *backoff* vuelve a crecer.
  void releaseBackoff() => _db.execute("UPDATE outbox SET next_try_at = NULL WHERE state = 'queued'");

  /// Pasa a `sent` toda entrada de este dispositivo que el ACK cubre.
  void applyAck(Ack ack) {
    if (deviceIdToHex(ack.deviceId) != _deviceHex) return;
    final low = ack.ackSeq > 32 ? ack.ackSeq - 32 : 1;
    final candidates = _db.select(
      "SELECT frame_seq FROM outbox WHERE frame_seq BETWEEN ? AND ? AND state IN ('queued', 'sending')",
      [low, ack.ackSeq],
    );
    for (final c in candidates) {
      final seq = c['frame_seq'] as int;
      if (ack.covers(seq)) _db.execute("UPDATE outbox SET state = 'sent' WHERE frame_seq = ?", [seq]);
    }
  }

  List<OutboxEntry> all() => _db.select('SELECT * FROM outbox ORDER BY frame_seq').map(_entry).toList();

  void close() => _db.close();
}
