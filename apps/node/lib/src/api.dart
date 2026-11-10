import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'access.dart';
import 'approvals.dart';
import 'dispatch.dart';
import 'event_log.dart';
import 'ingest.dart';
import 'node_health.dart';
import 'pipeline.dart';
import 'queue_service.dart';
import 'resource_book.dart';

/// Cabeceras CORS **sólo para desarrollo** (`--cors on`). Por omisión NO se envían: el tablero se sirve
/// del mismo origen que la API, y con un comodín cualquier página abierta en el navegador del
/// coordinador podría leer la cola (textos y ubicaciones de ciudadanos).
const Map<String, String> _devCors = {'access-control-allow-origin': '*'};

/// Una trama de un reporte con texto mide como mucho unos 200 bytes; 1 KiB deja margen.
const int kMaxFrameBytes = 1024;

/// Tope de eventos por página de replicación.
const int kMaxEventsPage = 1000;

Response _json(Object? body, {int status = 200, bool cors = false}) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8', if (cors) ..._devCors},
    );

/// API HTTP del nodo.
///
/// - `POST /frame`: cuerpo = bytes de una trama; 200 + ACK, o 400 si se rechaza.
/// - `GET /api/queue`: cola priorizada.
/// - `GET /api/events?origin=&after=&limit=`: eventos para replicación.
/// - `GET /api/health`: identidad del nodo y vector de versiones.
///
/// Si se da [pipeline], cada trama recién guardada pasa por los agentes de reglas.
/// Cabeceras de una lectura de la proyección: JSON + frescura honesta (si es una versión anterior del
/// log se dice, y cuánto) + `ETag` (la versión calculada y la consulta exacta).
Map<String, String> _freshHeaders(QueueRead r, bool cors, String etag) => {
  'content-type': 'application/json; charset=utf-8',
  if (cors) ..._devCors,
  'x-queue-stale': '${r.stale}',
  'x-queue-age-ms': '${r.ageMs}',
  'etag': etag,
  if (cors) 'access-control-expose-headers': 'x-queue-stale, x-queue-age-ms, etag',
};

/// La respuesta de una lectura de la proyección. Si el cliente ya tiene esta versión (`If-None-Match`
/// igual al ETag) se responde **304 sin cuerpo**: un tablero que sondea sin cambios no vuelve a bajar
/// megabytes. La frescura se declara igual en los dos casos. Un ETag ajeno o basura se ignora.
/// [stamp] es lo que, además de la versión de la proyección, hace distinta una respuesta: el detalle lleva la historia, que sale de
/// eventos (vínculos, normalizaciones) que NO mueven la versión de la cola; sin él se serviría un `304` con la historia vieja.
Response _projectionResponse(Request req, QueueRead r, bool cors, String body, {String stamp = ''}) {
  final etag = 'W/"${r.epoch}.${r.version}$stamp:${req.url.path}?${req.url.query}"';
  final headers = _freshHeaders(r, cors, etag);
  if (req.headers['if-none-match'] == etag) return Response(304, headers: {...headers}..remove('content-type'));
  return Response.ok(body, headers: headers);
}

/// El guardián de acceso. DENEGADO POR OMISIÓN: todo lo que cuelgue de `/api/` exige código salvo `/api/health`; una ruta nueva no
/// queda abierta por olvido. `/frame` (los ciudadanos no tienen código) y el tablero estático siguen abiertos.
///
///  · La réplica (`/api/events`, los reportes crudos con ubicación) pide SÓLO el código de PARES (si no hay, queda abierta).
///  · Lo demás pide el código del coordinador: con [codes] cada uno identifica a una persona (y su nombre viaja en el contexto
///    de la petición); con [coordinatorToken], un código compartido que NO identifica. No son intercambiables.
///
/// Con sólo [codes] (sin token de coordinador ni de pares) el guardián TAMBIÉN actúa: los códigos cuentan como protección.
Handler _guarded(Handler inner, {String? coordinatorToken, String? peerToken, Map<String, String> codes = const {}}) {
  if (coordinatorToken == null && peerToken == null && codes.isEmpty) return inner;
  Response denied() => Response(
    401,
    body: 'se exige el código de acceso (cabecera Authorization: Bearer …)',
    headers: {'www-authenticate': 'Bearer realm="sard"', 'content-type': 'text/plain; charset=utf-8'},
  );
  return (Request req) {
    final path = req.url.path;
    if (path == 'frame' || path == 'api/health' || !path.startsWith('api/')) return inner(req);
    final auth = req.headers['authorization'];
    if (path == 'api/events') {
      if (peerToken != null && !bearerMatches(auth, peerToken)) return denied();
      return inner(req);
    }
    if (codes.isNotEmpty) {
      final who = identifyBearer(auth, codes);
      if (who == null) return denied();
      return inner(req.change(context: {kWhoContext: who}));
    }
    if (coordinatorToken != null && !bearerMatches(auth, coordinatorToken)) return denied();
    return inner(req);
  };
}

/// El nombre de quien presentó su código (lo deja el guardián en el contexto), o `null` si no hay identidad.
String? _who(Request req) => req.context[kWhoContext] as String?;

Handler buildHandler({
  required Ingest ingest,
  required EventLog log,
  PipelineRunner? pipeline,
  QueueService? queue,
  NodeHealth? health,

  /// Registro de informes de despachador (`POST /api/dispatch`). Por omisión se crea uno sobre [log].
  Dispatch? dispatch,
  bool cors = false,

  /// Código de acceso del coordinador (`--coordinator-token`): lo que ve y decide. NO es identidad.
  String? coordinatorToken,

  /// Código de la réplica entre nodos (`--peer-token`): protege `/api/events`.
  String? peerToken,

  /// Códigos de los coordinadores (`--coordinator-codes`): nombre → código. A diferencia del token compartido, el código IDENTIFICA a
  /// quien firma: aprobar, registrar un informe o declarar un recurso se hace siempre a nombre del dueño del código.
  Map<String, String> coordinatorCodes = const {},
}) {
  if (coordinatorToken != null && coordinatorCodes.isNotEmpty) {
    throw ArgumentError('coordinatorToken y coordinatorCodes no se combinan: quien tuviera el token compartido firmaría con cualquier nombre.');
  }
  if (peerToken != null && coordinatorCodes.containsValue(peerToken)) {
    throw ArgumentError('un código de coordinador no puede ser igual al de la réplica.');
  }
  final queueService = queue ?? QueueService(log);
  final dispatcher = dispatch ?? Dispatch(log);
  final router = Router()
    ..post('/frame', (Request req) async {
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        chunks.add(chunk);
        if (chunks.length > kMaxFrameBytes) return Response(413, body: 'trama demasiado grande');
      }
      final bytes = chunks.takeBytes();
      final result = ingest.handleFrame(bytes);
      if (result.outcome == IngestOutcome.stored) pipeline?.run(result.event!);
      if (result.outcome == IngestOutcome.rejected) {
        return Response(400, body: 'trama rechazada');
      }
      return Response.ok(result.ack, headers: {'content-type': 'application/octet-stream'});
    })
    ..post('/api/approval', (Request req) async {
      // Un formulario de otra página llega como texto o «form-urlencoded» y no exige comprobación
      // previa; JSON sí. Exigirlo es lo que impide que una página ajena lance una aprobación.
      final mime = (req.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (mime != 'application/json') return Response(415, body: 'se exige content-type: application/json');
      final declared = int.tryParse(req.headers['content-length'] ?? '');
      if (declared != null && declared > kMaxApprovalBytes) return Response(413, body: 'cuerpo demasiado grande');
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        chunks.add(chunk);
        if (chunks.length > kMaxApprovalBytes) return Response(413, body: 'cuerpo demasiado grande');
      }
      final ApprovalRequest a;
      try {
        final bound = bindIdentity(_who(req), jsonDecode(utf8.decode(chunks.takeBytes())));
        if (bound.mismatch != null) return Response(403, body: bound.mismatch);
        a = parseApprovalRequest(bound.body);
      } on FormatException catch (e) {
        return Response(400, body: e.message);
      }
      for (final id in a.supersedes) {
        final target = log.eventById(id);
        if (target == null || (target.type != 'approval.granted' && target.type != 'approval.denied')) {
          return Response(400, body: 'supersedes: «$id» no es una decisión registrada');
        }
      }
      // SIEMPRE se guarda (sin 409): la cola puede ir unos segundos atrás y un nodo aislado puede no
      // ver aún a los miembros. Lo vigente o caducado se deriva al leer.
      final e = log.append(
        a.granted ? 'approval.granted' : 'approval.denied',
        {'recommendationId': a.recommendationId, 'incidentId': a.incidentId, 'members': a.members, 'note': a.note, 'who': a.who},
        reportKey: a.incidentId,
        inputs: a.supersedes,
      );
      return _json({'id': e.id}, cors: cors);
    })
    ..post('/api/dispatch', (Request req) async {
      // Igual que la aprobación: sólo JSON (un formulario de otra página llega como texto y no exige comprobación
      // previa), con tope de tamaño, y la autorización —si hay código— ya se comprobó antes de llegar aquí.
      final mime = (req.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (mime != 'application/json') return Response(415, body: 'se exige content-type: application/json');
      final declared = int.tryParse(req.headers['content-length'] ?? '');
      if (declared != null && declared > kMaxDispatchBytes) return Response(413, body: 'cuerpo demasiado grande');
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        chunks.add(chunk);
        if (chunks.length > kMaxDispatchBytes) return Response(413, body: 'cuerpo demasiado grande');
      }
      final DispatchRequest d;
      try {
        final bound = bindIdentity(_who(req), jsonDecode(utf8.decode(chunks.takeBytes())));
        if (bound.mismatch != null) return Response(403, body: bound.mismatch);
        d = parseDispatchRequest(bound.body);
      } on FormatException catch (e) {
        return Response(400, body: e.message);
      }
      final DispatchResult r;
      try {
        r = dispatcher.register(d);
      } on DispatchConflict catch (e) {
        return Response(409, body: e.toString());
      }
      // Los agentes de reglas corren sobre lo recién guardado (un reintento no los repite).
      if (!r.duplicate) pipeline?.run(r.event);
      return _json({'id': r.event.id, 'reportKey': r.event.reportKey, 'duplicate': r.duplicate}, cors: cors);
    })
    // Quién es el dueño del código presentado (o null si no hay identidad). Nunca por caché ni etiqueta: una identidad cambia con el código.
    ..get('/api/whoami', (Request req) => Response.ok(jsonEncode({'who': _who(req)}), headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', if (cors) ..._devCors}))
    ..get('/api/resources', (Request req) => _json({'resources': [for (final e in queueService.effectiveResources()) e.toJson()]}, cors: cors))
    ..post('/api/resources', (Request req) async {
      // Igual que la aprobación y el despachador: sólo JSON, con tope de tamaño; el código del coordinador (si hay) ya se comprobó.
      final mime = (req.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (mime != 'application/json') return Response(415, body: 'se exige content-type: application/json');
      final declared = int.tryParse(req.headers['content-length'] ?? '');
      if (declared != null && declared > kMaxResourceBytes) return Response(413, body: 'cuerpo demasiado grande');
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        chunks.add(chunk);
        if (chunks.length > kMaxResourceBytes) return Response(413, body: 'cuerpo demasiado grande');
      }
      final ResourceDeclareRequest d;
      try {
        final bound = bindIdentity(_who(req), jsonDecode(utf8.decode(chunks.takeBytes())));
        if (bound.mismatch != null) return Response(403, body: bound.mismatch);
        d = parseResourceDeclaration(bound.body);
      } on FormatException catch (e) {
        return Response(400, body: e.message);
      }
      // Sólo se reemplazan declaraciones REALES de ESTA unidad (no una aprobación, ni la de otra unidad, ni algo inventado).
      for (final id in d.supersedes) {
        final target = log.eventById(id);
        final targetId = target?.body['resource'] is Map ? (target!.body['resource']! as Map)['id'] : null;
        if (target == null || target.type != 'resource.declared' || targetId != d.resource.id) {
          return Response(400, body: 'supersedes: «$id» no es una declaración de ${d.resource.id}');
        }
      }
      final e = log.append('resource.declared', {'resource': d.resource.toJson(), 'declared_by': d.who}, reportKey: 'res-${d.resource.id}', inputs: d.supersedes);
      return _json({'id': e.id}, cors: cors);
    })
    ..get('/api/queue', (Request req) async {
      final r = await queueService.read();
      return _projectionResponse(req, r, cors, r.json);
    })
    ..get('/api/incidents', (Request req) async {
      final q = req.url.queryParameters;
      final int offset, limit;
      final bool? bare, pending;
      try {
        offset = q.containsKey('offset') ? int.parse(q['offset']!) : 0;
        limit = q.containsKey('limit') ? int.parse(q['limit']!) : 200;
        bare = switch (q['bare']) { null => null, 'true' => true, 'false' => false, _ => throw const FormatException('bare debe ser true o false') };
        pending = switch (q['pending']) { null => null, 'true' => true, 'false' => false, _ => throw const FormatException('pending debe ser true o false') };
      } on FormatException catch (e) {
        return Response(400, body: 'parámetros inválidos: ${e.message}');
      }
      final r = await queueService.read();
      final String body;
      try {
        body = r.incidentsPage(view: q['view'] ?? 'short', urgency: q['urgency'], bare: bare, pending: pending, offset: offset, limit: limit);
      } on ArgumentError catch (e) {
        return Response(400, body: 'parámetros inválidos: ${e.message}');
      }
      return _projectionResponse(req, r, cors, body);
    })
    ..get('/api/incidents/<id>', (Request req, String id) async {
      final r = await queueService.read();
      final detail = queueService.detailWithHistory(r, Uri.decodeComponent(id));
      if (detail == null) return Response(404, body: 'incidente desconocido (puede haberse fusionado o dividido: vuelve a pedir la lista)');
      return _projectionResponse(req, r, cors, detail, stamp: '+${log.count()}');
    })
    // Zonas que reportaron y callaron (la ausencia de reportes NO es seguridad). Aparte de la cola y del resumen: no entra en la huella.
    ..get('/api/coverage', (Request req) async => _json(queueService.coverageOf(await queueService.read()), cors: cors))
    ..get('/api/nodes', (Request req) => _json(health?.snapshot(log) ?? NodeHealth(nodeId: log.nodeId, peers: const []).snapshot(log), cors: cors))
    ..get('/api/events', (Request req) {
      final q = req.url.queryParameters;
      final origin = q['origin'];
      final after = int.tryParse(q['after'] ?? '0');
      final limit = int.tryParse(q['limit'] ?? '500');
      if (origin == null || origin.isEmpty || after == null || limit == null) {
        return Response(400, body: 'parámetros: origin (obligatorio), after, limit');
      }
      return _json([for (final e in log.readAfter(origin, after, limit: limit.clamp(1, kMaxEventsPage))) e.toJson()], cors: cors);
    })
    ..get('/api/health', (Request req) => _json({
          'node': log.nodeId,
          'events': log.count(),
          'versionVector': log.versionVector(),
          if (pipeline?.llmStats != null) 'llm': pipeline!.llmStats!.toJson(),
          if (pipeline != null) 'budget': pipeline.budget.toJson(),
        }, cors: cors));
  return _guarded(router.call, coordinatorToken: coordinatorToken, peerToken: peerToken, codes: coordinatorCodes);
}
