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
  --cors      «on» sólo en DESARROLLO (tablero en otro origen). Por omisión no hay CORS: una página ajena no puede leer la cola.
  --resources archivo JSON con los recursos declarados (ver config/recursos.json); sin él el agente 6 propone la acción pero no recursos.
  --llm-url   URL base del modelo (sólo PRUEBAS y demostración: un servidor falso; por omisión la API real).
  --llm-model modelo que se consulta (por omisión claude-sonnet-5-5).
  --llm-effort cuánto razona el modelo: low (por omisión: es con lo que se midió T06 y cabe holgado en el plazo de 8 s),
              medium, high… o «default» para el de la API (en Sonnet 5.5 es high, más lento y caro; no medido).
  --takeover  segundos que espera cada nodo del relevo antes de hacer el trabajo caro (modelo, auditoría) de un
              reporte que no es suyo según el reparto por rendezvous (por omisión 10).
  --coordinator-token  código de acceso del COORDINADOR (también SARD_COORDINATOR_TOKEN; mínimo 8 caracteres): lo
              exigen el tablero (lectura) y la aprobación; el tablero lo pide al abrirse. NO es identidad: un código
              compartido no dice quién aprobó. Sin él, cualquiera con acceso a la red lee y aprueba.
  --coordinator-codes  códigos de VARIOS coordinadores que IDENTIFICAN a cada uno (también SARD_COORDINATOR_CODES):
              "Ana Gómez=codigo-de-ana,Luis Torres=codigo-de-luis". Cada código tiene al menos 8 caracteres, es distinto de los
              demás y del de la réplica. Aprobar, registrar un informe y declarar un recurso se hace SIEMPRE a nombre del dueño del
              código: el de Luis no puede firmar como Ana en este nodo. No se combina con --coordinator-token. Es «identificado por
              código», no «autenticado»: sin TLS el código viaja en claro, no hay límite de intentos, y los nodos pares replican
              el evento sin volver a comprobar el nombre.
  --peer-token  código de la RÉPLICA entre nodos (también SARD_PEER_TOKEN; mínimo 8): protege /api/events, que entrega
              los reportes crudos con su ubicación. Todos los nodos del grupo deben usar el mismo. Sin él, /api/events
              queda abierto aunque haya código de coordinador.
  --llm       «on» para consultar al modelo de lenguaje (usa la variable ANTHROPIC_API_KEY); por defecto apagado.
              Sin clave o sin red el nodo sigue con las reglas. Verificado contra la API real (docs/resultados/modelo-real.md).
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

/// Un nodo superviviente no muere por un error inesperado en una tarea de fondo: se registra con claridad y
/// sigue sirviendo. (Medido: sin esto, agotar los descriptores de archivo mataba el proceso entero.)
void main(List<String> args) {
  runZonedGuarded(
    () => _run(args),
    (error, stack) => stderr.writeln('[nodo] error NO controlado en una tarea de fondo; el nodo sigue: $error\n$stack'),
  );
}

Future<void> _run(List<String> args) async {
  final o = _parse(args);
  final id = o['id'];
  final data = o['data'];
  if (id == null || data == null) {
    stderr.write(_usage);
    exit(64);
  }
  final port = int.tryParse(o['port'] ?? '8081') ?? 8081;
  // Los códigos pueden venir de una variable de entorno para no dejarlos a la vista en `ps`.
  String? secret(String flag, String env) {
    final v = o[flag] ?? Platform.environment[env];
    if (v == null) return null;
    if (v.length < 8) {
      stderr.writeln('--$flag: el código debe tener al menos 8 caracteres.');
      exit(64);
    }
    return v;
  }

  final coordinatorToken = secret('coordinator-token', 'SARD_COORDINATOR_TOKEN');
  final peerToken = secret('peer-token', 'SARD_PEER_TOKEN');
  var coordinatorCodes = const <String, String>{};
  final rawCodes = o['coordinator-codes'] ?? Platform.environment['SARD_COORDINATOR_CODES'];
  if (rawCodes != null) {
    if (coordinatorToken != null) {
      stderr.writeln('--coordinator-codes no se combina con --coordinator-token: quien tuviera el código compartido firmaría con cualquier nombre.');
      exit(64);
    }
    try {
      coordinatorCodes = parseCoordinatorCodes(rawCodes, peerToken: peerToken);
    } on FormatException catch (e) {
      stderr.writeln(e.message);
      exit(64);
    }
  }
  if (coordinatorToken != null && coordinatorToken == peerToken) {
    stderr.writeln('El código del coordinador y el de la réplica deben ser distintos: quien copia el log no debe poder aprobar.');
    exit(64);
  }
  Directory(data).createSync(recursive: true);

  final log = EventLog.open(p.join(data, 'log.db'), nodeId: id);
  final key = Uint8List.fromList(utf8.encode(o['key'] ?? 'clave-de-ejemplo'));
  LlmPort? llm;
  if (o['llm'] == 'on') {
    final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      stderr.writeln('--llm on pide la variable ANTHROPIC_API_KEY; sin ella el nodo sigue sólo con reglas.');
    } else {
      final effort = o['llm-effort'] ?? 'low';
      llm = ClaudeHttpPort(
        client: http.Client(),
        apiKey: apiKey,
        model: o['llm-model'] ?? 'claude-sonnet-5-5',
        effort: effort == 'default' ? null : effort,
        baseUrl: o['llm-url'] == null ? null : Uri.parse(o['llm-url']!),
      );
    }
  }
  var resources = <Resource>[];
  final resourcesPath = o['resources'];
  if (resourcesPath != null) {
    try {
      resources = parseResources(File(resourcesPath).readAsStringSync());
    } on FileSystemException catch (e) {
      stderr.writeln('No se pudo leer --resources: ${e.message} (${e.path})');
      exit(64);
    } on FormatException catch (e) {
      stderr.writeln('Archivo de recursos inválido: ${e.message}');
      exit(64);
    }
  }
  final peers = (o['peers'] ?? '').split(',').where((u) => u.isNotEmpty).map(Uri.parse).toList();
  final health = NodeHealth(nodeId: id, peers: peers);
  // El trabajo caro (modelo, auditoría) se reparte entre los nodos vivos; lo esencial no depende de esto.
  final ownership = OwnershipPolicy(selfId: id, liveNodes: health.liveNodeIds, takeoverAfter: Duration(seconds: int.tryParse(o['takeover'] ?? '10') ?? 10));
  final pipeline = PipelineRunner(log, llm: llm, ownership: ownership, onLlmFallback: (r) => stderr.writeln('[llm] respaldo por reglas: $r'));
  final api = buildHandler(
    ingest: Ingest(log: log, key: key),
    log: log,
    cors: o['cors'] == 'on',
    health: health,
    queue: QueueService(log, resources: resources),
    pipeline: pipeline,
    coordinatorToken: coordinatorToken,
    peerToken: peerToken,
    coordinatorCodes: coordinatorCodes,
  );
  // La auditoría de vínculos va por lotes, fuera de la ruta del ACK (a lo sumo cada 5 s y sólo si hay
  // reportes nuevos); con muchos reportes calcula en otro isolate.
  final audit = AuditLinker(log, ownership: ownership, onError: (e, st) => stderr.writeln('[auditoría] el lote falló y se reintentará: $e'));
  Timer.periodic(const Duration(seconds: 2), (_) => unawaited(audit.tick()));
  final web = o['web-root'];
  final Handler handler = web == null
      ? api
      : Cascade().add(api).add(createStaticHandler(web, defaultDocument: 'index.html')).handler;

  if (peers.isNotEmpty) {
    final replicator = PollingReplicator(log: log, peers: peers, client: http.Client(), health: health, peerToken: peerToken, onReplicated: (events) {
      for (final e in events) {
        pipeline.onReplicated(e);
      }
    });
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
  stdout.writeln('sard_node $id escuchando en :${server.port} (${log.count()} eventos en el log, ${resources.length} recursos declarados)');
  if (coordinatorToken == null && coordinatorCodes.isEmpty) {
    stdout.writeln('AVISO: sin --coordinator-token cualquiera con acceso a la red lee la cola (ubicaciones), puede registrar aprobaciones y puede registrar informes de despachador (p. ej. un P1 inventado).');
  }
  if (peerToken == null) {
    stdout.writeln('AVISO: sin --peer-token /api/events queda abierto: entrega los reportes crudos con su ubicación.');
  }
  if (coordinatorCodes.isNotEmpty) {
    // SÓLO los nombres: nunca los códigos.
    stdout.writeln('Coordinadores identificados por código: ${coordinatorCodes.keys.join(', ')}. Aprobar, informar y declarar recursos se registra a su nombre EN ESTE nodo; sin TLS el código viaja en claro, no hay límite de intentos y los pares replican el evento sin volver a comprobar el nombre.');
  }
  if (coordinatorToken != null || peerToken != null || coordinatorCodes.isNotEmpty) {
    stdout.writeln('Códigos de acceso activos (coordinador: ${coordinatorToken != null || coordinatorCodes.isNotEmpty ? 'sí' : 'no'}, réplica: ${peerToken != null ? 'sí' : 'no'}).${coordinatorToken != null ? ' Un código compartido NO identifica a quien aprueba (para eso, --coordinator-codes).' : ''}');
  }

  Future<void> shutdown(ProcessSignal _) async {
    await server.close(force: true);
    log.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);
}
