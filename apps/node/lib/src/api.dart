import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'event_log.dart';
import 'ingest.dart';
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
Handler buildHandler({required Ingest ingest, required EventLog log, PipelineRunner? pipeline, QueueService? queue, bool cors = false}) {
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
    ..get('/api/queue', (Request req) async {
      final r = await queueService.read();
      return Response.ok(
        r.json,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          if (cors) ..._devCors,
          // frescura honesta: si es una versión anterior del log, se dice y se dice cuánto
          'x-queue-stale': '${r.stale}',
          'x-queue-age-ms': '${r.ageMs}',
          if (cors) 'access-control-expose-headers': 'x-queue-stale, x-queue-age-ms',
        },
      );
    })
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
