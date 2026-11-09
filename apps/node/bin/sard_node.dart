import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

const _usage = '''
Uso: dart run bin/sard_node.dart --id <A|B|…> --port <n> --data <dir> [--key <texto>] [--web-root <dir>]
  --id        identificador del nodo (obligatorio)
  --port      puerto HTTP (por defecto 8081)
  --data      directorio de datos; el log vive en <dir>/log.db (obligatorio)
  --key       clave de la etiqueta de integridad (por defecto «clave-de-ejemplo»)
  --peers     URLs de los nodos pares separadas por comas, p. ej. http://localhost:8082
  --web-root  directorio con el tablero compilado (apps/dashboard/build/web)
  --llm       «on» para consultar al modelo de lenguaje (usa la variable ANTHROPIC_API_KEY); por defecto apagado.
              Sin clave o sin red el nodo sigue con las reglas. NO verificado contra la API real.
''';

Map<String, String> _parse(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--') || i + 1 >= args.length) {
      stderr.write('Argumento no válido: ${args[i]}\n$_usage');
      exit(64);
    }
    out[args[i].substring(2)] = args[++i];
  }
  return out;
}

Future<void> main(List<String> args) async {
  final o = _parse(args);
  final id = o['id'];
  final data = o['data'];
  if (id == null || data == null) {
    stderr.write(_usage);
    exit(64);
  }
  final port = int.tryParse(o['port'] ?? '8081') ?? 8081;
  Directory(data).createSync(recursive: true);

  final log = EventLog.open(p.join(data, 'log.db'), nodeId: id);
  final key = Uint8List.fromList(utf8.encode(o['key'] ?? 'clave-de-ejemplo'));
  LlmPort? llm;
  if (o['llm'] == 'on') {
    final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      stderr.writeln('--llm on pide la variable ANTHROPIC_API_KEY; sin ella el nodo sigue sólo con reglas.');
    } else {
      llm = ClaudeHttpPort(client: http.Client(), apiKey: apiKey);
    }
  }
  final api = buildHandler(ingest: Ingest(log: log, key: key), log: log, pipeline: PipelineRunner(log, llm: llm, onLlmFallback: (r) => stderr.writeln('[llm] respaldo por reglas: $r')));
  // La auditoría de vínculos va por lotes, fuera de la ruta del ACK (a lo sumo cada 5 s y sólo si hay
  // reportes nuevos); con muchos reportes calcula en otro isolate.
  final audit = AuditLinker(log);
  Timer.periodic(const Duration(seconds: 2), (_) => unawaited(audit.tick()));
  final web = o['web-root'];
  final Handler handler = web == null
      ? api
      : Cascade().add(api).add(createStaticHandler(web, defaultDocument: 'index.html')).handler;

  final peers = (o['peers'] ?? '').split(',').where((u) => u.isNotEmpty).map(Uri.parse).toList();
  if (peers.isNotEmpty) {
    final replicator = PollingReplicator(log: log, peers: peers, client: http.Client());
    var running = false;
    Timer.periodic(const Duration(seconds: 3), (_) async {
      if (running) return; // no solapar sondeos
      running = true;
      try {
        await replicator.pullOnce();
      } finally {
        running = false;
      }
    });
  }

  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('sard_node $id escuchando en :${server.port} (${log.all().length} eventos en el log)');

  Future<void> shutdown(ProcessSignal _) async {
    await server.close(force: true);
    log.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);
}
