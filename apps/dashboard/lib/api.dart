import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// El nodo respondió con un estado de error.
class ApiException implements Exception {
  const ApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'ApiException($status): $message';
}

/// El nodo exige un código de acceso (HTTP 401): falta o ya no vale. No es un fallo del nodo.
class AccessDenied implements Exception {
  const AccessDenied();

  @override
  String toString() => 'AccessDenied';
}

/// El incidente pedido ya no existe en la vista actual (pudo fusionarse con otro o dividirse): se vuelve
/// a pedir la lista, no es un fallo del nodo.
class IncidentGone implements Exception {
  const IncidentGone(this.id);
  final String id;

  @override
  String toString() => 'IncidentGone($id)';
}

/// Lo que el tablero necesita del nodo. Una interfaz para poder probar la pantalla sin red.
abstract class DashboardApi {
  /// Código de acceso del coordinador (`--coordinator-token` del nodo), que se envía como
  /// `Authorization: Bearer`. Vive sólo en memoria: no se guarda en el navegador. NO es identidad.
  set accessCode(String? code);

  Future<IncidentsPage> incidents({String view = 'short', String? urgency, bool? bare, bool? pending, int offset = 0, int limit = 200});
  Future<IncidentDetail> detail(String id);
  Future<NodesStatus> nodes();

  /// Registra una decisión humana sobre la versión [recommendationId] de la recomendación. Lanza si el
  /// nodo no la acepta o no responde: la decisión **no** se da por registrada.
  Future<void> decide({
    required String recommendationId,
    required String incidentId,
    required List<String> members,
    required bool granted,
    required String who,
    String note = '',
    List<String> supersedes = const [],
  });

  /// Registra un informe de despachador (radio, teléfono o en persona). Es información de segunda mano y no lleva
  /// ubicación. [id] lo genera quien llama: reintentar con el mismo [id] y el mismo contenido no duplica el informe.
  /// Lanza si el nodo no lo acepta o no responde: el informe **no** se da por registrado.
  Future<void> dispatch({
    required String id,
    required String text,
    required String medium,
    required String who,
    String? origin,
    List<String> flags = const [],
    int people = 0,
  });
}

class _Cached {
  _Cached(this.etag, this.page);
  final String etag;
  final IncidentsPage page;
}

/// El cliente real. Usa `ETag`/`If-None-Match`: si la vista no cambió el nodo responde 304 sin cuerpo y
/// se reutiliza la página ya leída (con la **frescura de ahora**, que el nodo declara también en el 304).
class HttpDashboardApi implements DashboardApi {
  HttpDashboardApi(this._client, this._base, {this.timeout = const Duration(seconds: 5)});

  final http.Client _client;
  final Uri _base;
  final Duration timeout;
  final Map<String, _Cached> _cache = {};
  String? _code;

  @override
  set accessCode(String? code) => _code = code;

  /// Cabeceras de toda petición: el código (si hay) y las propias de la llamada. Nunca va en la dirección.
  Map<String, String> _h([Map<String, String> extra = const {}]) => {...extra, if (_code != null) 'authorization': 'Bearer $_code'};

  /// Un 401 es «falta el código o ya no vale»: se olvida lo leído (era de alguien con acceso) y se avisa.
  Never _denied() {
    _cache.clear();
    throw const AccessDenied();
  }

  static bool _stale(http.BaseResponse r) => r.headers['x-queue-stale'] == 'true';
  static int _age(http.BaseResponse r) => int.tryParse(r.headers['x-queue-age-ms'] ?? '') ?? 0;

  Map<String, Object?> _decode(http.Response r) {
    final body = jsonDecode(utf8.decode(r.bodyBytes));
    if (body is! Map) throw const FormatException('el nodo no devolvió un objeto');
    return body.cast<String, Object?>();
  }

  @override
  Future<IncidentsPage> incidents({String view = 'short', String? urgency, bool? bare, bool? pending, int offset = 0, int limit = 200}) async {
    final query = <String, String>{
      if (view != 'short') 'view': view,
      'urgency': ?urgency,
      if (bare != null) 'bare': '$bare',
      if (pending != null) 'pending': '$pending',
      if (offset != 0) 'offset': '$offset',
      if (view != 'short' && limit != 200) 'limit': '$limit',
    };
    final uri = _base.resolve('/api/incidents').replace(queryParameters: query.isEmpty ? null : query);
    final key = uri.toString();
    final cached = _cache[key];
    final r = await _client.get(uri, headers: _h({'if-none-match': ?cached?.etag})).timeout(timeout);
    if (r.statusCode == 401) _denied();
    if (r.statusCode == 304) {
      if (cached == null) {
        _cache.remove(key);
        return incidents(view: view, urgency: urgency, bare: bare, offset: offset, limit: limit);
      }
      return cached.page.withFreshness(stale: _stale(r), ageMs: _age(r));
    }
    if (r.statusCode != 200) throw ApiException(r.statusCode, r.body);
    final page = IncidentsPage.fromJson(_decode(r), stale: _stale(r), ageMs: _age(r));
    final etag = r.headers['etag'];
    if (etag != null) _cache[key] = _Cached(etag, page);
    return page;
  }

  @override
  Future<IncidentDetail> detail(String id) async {
    final r = await _client.get(_base.resolve('/api/incidents/${Uri.encodeComponent(id)}'), headers: _h()).timeout(timeout);
    if (r.statusCode == 401) _denied();
    if (r.statusCode == 404) throw IncidentGone(id);
    if (r.statusCode != 200) throw ApiException(r.statusCode, r.body);
    return IncidentDetail.fromJson(_decode(r), stale: _stale(r), ageMs: _age(r));
  }

  @override
  Future<NodesStatus> nodes() async {
    final r = await _client.get(_base.resolve('/api/nodes'), headers: _h()).timeout(timeout);
    if (r.statusCode == 401) _denied();
    if (r.statusCode != 200) throw ApiException(r.statusCode, r.body);
    return NodesStatus.fromJson(_decode(r));
  }

  @override
  Future<void> decide({
    required String recommendationId,
    required String incidentId,
    required List<String> members,
    required bool granted,
    required String who,
    String note = '',
    List<String> supersedes = const [],
  }) async {
    final r = await _client
        .post(
          _base.resolve('/api/approval'),
          headers: _h({'content-type': 'application/json'}),
          body: jsonEncode({
            'recommendationId': recommendationId,
            'incidentId': incidentId,
            'members': members,
            'decision': granted ? 'granted' : 'denied',
            'note': note,
            'who': who,
            'supersedes': supersedes,
          }),
        )
        .timeout(timeout);
    if (r.statusCode == 401) _denied();
    if (r.statusCode != 200) throw ApiException(r.statusCode, utf8.decode(r.bodyBytes));
  }

  @override
  Future<void> dispatch({
    required String id,
    required String text,
    required String medium,
    required String who,
    String? origin,
    List<String> flags = const [],
    int people = 0,
  }) async {
    final cleanOrigin = origin?.trim();
    final r = await _client
        .post(
          _base.resolve('/api/dispatch'),
          headers: _h({'content-type': 'application/json'}),
          body: jsonEncode({
            'id': id,
            'text': text,
            'medium': medium,
            if (cleanOrigin != null && cleanOrigin.isNotEmpty) 'origin': cleanOrigin,
            'who': who,
            'flags': flags,
            'people': people,
          }),
        )
        .timeout(timeout);
    if (r.statusCode == 401) _denied();
    // Un cuerpo de error que no sea UTF-8 (un proxy intermedio) no debe volver el rechazo en otra excepción.
    if (r.statusCode != 200) throw ApiException(r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true));
  }
}
