import 'package:sqlite3/sqlite3.dart';

/// Reabre la base tras el kill -9 e imprime `count=<n> max=<m>`.
void main(List<String> args) {
  final db = sqlite3.open(args.first);
  final row = db.select('SELECT COUNT(*) AS c, COALESCE(MAX(id), 0) AS m FROM t').first;
  print('count=${row['c']} max=${row['m']}');
}
