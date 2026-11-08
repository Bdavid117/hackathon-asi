import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Inserta ids consecutivos, cada uno en su propia transacción, e imprime
/// `committed <id>` SÓLO después del COMMIT. Se ejecuta hasta que lo matan.
void main(List<String> args) {
  final db = sqlite3.open(args.first);
  db.execute('PRAGMA journal_mode=WAL');
  db.execute('PRAGMA synchronous=FULL');
  db.execute('CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY)');
  var id = db.select('SELECT COALESCE(MAX(id), 0) AS m FROM t').first['m'] as int;
  while (true) {
    id++;
    db.execute('BEGIN');
    db.execute('INSERT INTO t(id) VALUES (?)', [id]);
    db.execute('COMMIT');
    stdout.writeln('committed $id');
  }
}
