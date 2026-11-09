import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'approvals.dart';
import 'event_log.dart';
import 'ingest.dart';
import 'node_health.dart';
import 'pipeline.dart';
import 'queue_service.dart';

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
Response _projectionResponse(Request req, QueueRead r, bool cors, String body) {
  final etag = 'W/"${r.epoch}.${r.version}:${req.url.path}?${req.url.query}"';
  final headers = _freshHeaders(r, cors, etag);
  if (req.headers['if-none-match'] == etag) return Response(304, headers: {...headers}..remove('content-type'));
  return Response.ok(body, headers: headers);
}

Handler buildHandler({required Ingest ingest, required EventLog log, PipelineRunner? pipeline, QueueService? queue, NodeHealth? health, bool cors = false}) {
  final queueService = queue ?? QueueService(log);
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
        a = parseApprovalRequest(jsonDecode(utf8.decode(chunks.takeBytes())));
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
    ..get('/api/queue', (Request req) async {
      final r = await queueService.read();
      return _projectionResponse(req, r, cors, r.json);
    })
    ..get('/api/incidents', (Request req) async {
      final q = req.url.queryParameters;
      final int offset, limit;
      final bool? bare;
      try {
        offset = q.containsKey('offset') ? int.parse(q['offset']!) : 0;
        limit = q.containsKey('limit') ? int.parse(q['limit']!) : 200;
        bare = switch (q['bare']) { null => null, 'true' => true, 'false' => false, _ => throw const FormatException('bare debe ser true o false') };
      } on FormatException catch (e) {
        return Response(400, body: 'parámetros inválidos: ${e.message}');
      }
      final r = await queueService.read();
      final String body;
      try {
        body = r.incidentsPage(view: q['view'] ?? 'short', urgency: q['urgency'], bare: bare, offset: offset, limit: limit);
      } on ArgumentError catch (e) {
        return Response(400, body: 'parámetros inválidos: ${e.message}');
      }
      return _projectionResponse(req, r, cors, body);
    })
    ..get('/api/incidents/<id>', (Request req, String id) async {
      final r = await queueService.read();
      final detail = r.detailOf(Uri.decodeComponent(id));
      if (detail == null) return Response(404, body: 'incidente desconocido (puede haberse fusionado o dividido: vuelve a pedir la lista)');
      return _projectionResponse(req, r, cors, detail);
    })
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
  return router.call;
}
