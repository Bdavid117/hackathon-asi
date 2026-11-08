import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Un nodo SARD real arrancado como proceso (`dart run apps/node/bin/sard_node.dart`).
///
/// Sirve para las pruebas de resiliencia: [kill9] lo mata sin avisarle, igual que un corte.
class NodeProcess {
  NodeProcess._(this.id, this.port, this._launcher, this._log);

  final String id;
  final int port;
  final Process _launcher;
  final IOSink _log;

  Uri get url => Uri.parse('http://localhost:$port');

  /// Arranca el nodo y espera (hasta 60 s) a que responda `/api/health`.
  static Future<NodeProcess> start({
    required String id,
    required int port,
    required String dataDir,
    List<String> peers = const [],
    String? nodeDir,
  }) async {
    final dir = nodeDir ?? _defaultNodeDir();
    if (await _answersHealth(port)) {
      throw StateError('el puerto $port ya está en uso por algo que responde /api/health: no se arranca ni se mata nada');
    }
    Directory(dataDir).createSync(recursive: true);
    final log = File('$dataDir/node-$id.out').openWrite(mode: FileMode.append);
    final p = await Process.start(
      'dart',
      [
        'run', 'bin/sard_node.dart', '--id', id, '--port', '$port', '--data', dataDir,
        if (peers.isNotEmpty) ...['--peers', peers.join(',')],
      ],
      workingDirectory: dir,
    );
    p.stdout.listen(log.add);
    p.stderr.listen(log.add);
    final node = NodeProcess._(id, port, p, log);

    final client = http.Client();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        try {
          final r = await client.get(node.url.resolve('/api/health')).timeout(const Duration(seconds: 1));
          if (r.statusCode == 200) return node;
        } on Exception {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    } finally {
      client.close();
    }
    node.kill9();
    throw StateError('el nodo $id no respondió en 60 s (log: $dataDir/node-$id.out)');
  }

  static Future<bool> _answersHealth(int port) async {
    final client = http.Client();
    try {
      await client.get(Uri.parse('http://localhost:$port/api/health')).timeout(const Duration(milliseconds: 500));
      return true;
    } on Exception {
      return false;
    } finally {
      client.close();
    }
  }

  /// Busca `apps/node/bin/sard_node.dart` subiendo desde el script en ejecución y desde el
  /// directorio actual (sirve tanto con `dart run packages/sim/bin/...` como con `dart test`).
  static String _defaultNodeDir() {
    for (final start in [File.fromUri(Platform.script).parent, Directory.current]) {
      var d = start.absolute;
      while (true) {
        if (File('${d.path}/apps/node/bin/sard_node.dart').existsSync()) return '${d.path}/apps/node';
        final up = d.parent;
        if (up.path == d.path) break;
        d = up;
      }
    }
    throw StateError('no se encontró apps/node/bin/sard_node.dart');
  }

  /// PIDs que escuchan en el puerto del nodo **y** cuyo comando es un `sard_node`: nunca se
  /// toca un proceso ajeno que casualmente use el mismo puerto.
  List<int> _listeningPids() {
    final r = Process.runSync('lsof', ['-ti', 'tcp:$port', '-sTCP:LISTEN']);
    final pids = '${r.stdout}'.split('\n').map((s) => int.tryParse(s.trim())).whereType<int>();
    return [
      for (final pid in pids)
        if ('${Process.runSync('ps', ['-o', 'command=', '-p', '$pid']).stdout}'.contains('sard_node')) pid,
    ];
  }

  /// `kill -9` del servidor y de su lanzador, sin darles opción a cerrar nada.
  void kill9() {
    for (final pid in _listeningPids()) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    _launcher.kill(ProcessSignal.sigkill);
  }

  /// Apaga el nodo con SIGTERM y, si no acaba en 3 s, con `kill -9`.
  Future<void> stop() async {
    for (final pid in _listeningPids()) {
      Process.killPid(pid, ProcessSignal.sigterm);
    }
    _launcher.kill();
    await _launcher.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      kill9();
      return -1;
    });
    await _log.close();
  }
}
