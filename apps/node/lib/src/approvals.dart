import 'event_log.dart';

/// Estado de la aprobación de la **versión vigente** de la recomendación de un incidente.
enum ApprovalStatus { pendiente, aprobada, denegada, caduca }

/// Una decisión humana registrada (evento `approval.granted` o `approval.denied`).
class ApprovalDecision {
  const ApprovalDecision({
    required this.eventId,
    required this.recommendationId,
    required this.incidentId,
    required this.members,
    required this.granted,
    required this.note,
    required this.who,
    required this.atMs,
    required this.supersedes,
  });

  final String eventId;

  /// La versión de la recomendación que la persona VIO al decidir.
  final String recommendationId;
  final String incidentId;

  /// Reportes del incidente cuando se decidió (enlaza la decisión si el incidente se fusiona después).
  final List<String> members;
  final bool granted;
  final String note;

  /// Texto libre, sin autenticar (limitación declarada).
  final String who;

  /// Marca de tiempo del evento (no es un orden entre nodos).
  final int atMs;

  /// Decisiones anteriores que ésta sustituye de forma explícita.
  final List<String> supersedes;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'recommendationId': recommendationId,
    'incidentId': incidentId,
    'decision': granted ? 'granted' : 'denied',
    'note': note,
    'who': who,
    'at': atMs,
    'supersedes': supersedes,
  };
}

/// Lo que se muestra de la aprobación de un incidente.
class ApprovalState {
  const ApprovalState({required this.status, required this.discrepancy, required this.current, required this.stale});

  final ApprovalStatus status;

  /// Hay decisiones contradictorias de la versión vigente que nadie ha resuelto explícitamente.
  final bool discrepancy;

  /// Decisiones de la versión vigente que no han sido sustituidas.
  final List<ApprovalDecision> current;

  /// Decisiones de versiones anteriores del incidente (su recomendación cambió).
  final List<ApprovalDecision> stale;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'discrepancy': discrepancy,
    'current': [for (final d in current) d.toJson()],
    'stale': [for (final d in stale) d.toJson()],
  };
}

/// Lee las decisiones de una lista de eventos. Tolerante: un cuerpo mal formado se omite.
List<ApprovalDecision> readApprovals(Iterable<Event> events) {
  final out = <ApprovalDecision>[];
  for (final e in events) {
    if (e.type != 'approval.granted' && e.type != 'approval.denied') continue;
    final b = e.body;
    final rec = b['recommendationId'], incident = b['incidentId'], who = b['who'];
    if (rec is! String || incident is! String || who is! String) continue;
    final members = b['members'];
    final note = b['note'];
    out.add(
      ApprovalDecision(
        eventId: e.id,
        recommendationId: rec,
        incidentId: incident,
        members: members is List ? [for (final m in members) if (m is String) m] : const [],
        granted: e.type == 'approval.granted',
        note: note is String ? note : '',
        who: who,
        atMs: int.tryParse(e.hlc.split('-').first) ?? 0,
        supersedes: e.inputs,
      ),
    );
  }
  return out;
}

int _byTime(ApprovalDecision a, ApprovalDecision b) {
  final c = a.atMs.compareTo(b.atMs);
  return c != 0 ? c : a.eventId.compareTo(b.eventId);
}

/// Deriva, **al leer**, el estado de la aprobación de un incidente.
///
/// - Una decisión pertenece al incidente si nombra su identificador o comparte algún reporte con él.
/// - Es **vigente** si vio la versión actual de la recomendación; si vio otra, es **caducada**.
/// - Una decisión sustituye a otras **sólo si las nombra** (el reloj no es un orden entre nodos).
/// - Entre las vigentes no sustituidas manda la **denegación**; si hay de las dos clases se marca la
///   discrepancia. Sin vigentes pero con caducadas: `caduca`. El resultado no depende del orden de la lista.
ApprovalState deriveApproval({
  required String incidentId,
  required Set<String> memberKeys,
  required String? currentRecommendationId,
  required List<ApprovalDecision> approvals,
}) {
  final mine = [
    for (final a in approvals)
      if (a.incidentId == incidentId || a.members.any(memberKeys.contains)) a,
  ]..sort(_byTime);
  final vigentes = [for (final a in mine) if (currentRecommendationId != null && a.recommendationId == currentRecommendationId) a];
  final stale = [for (final a in mine) if (!vigentes.contains(a)) a];

  final named = {for (final a in vigentes) ...a.supersedes};
  var current = [for (final a in vigentes) if (!named.contains(a.eventId)) a];
  if (current.isEmpty) current = vigentes; // un ciclo de sustituciones no deja el estado en blanco

  if (current.isEmpty) {
    return ApprovalState(status: stale.isEmpty ? ApprovalStatus.pendiente : ApprovalStatus.caduca, discrepancy: false, current: const [], stale: stale);
  }
  final denied = current.any((a) => !a.granted);
  final granted = current.any((a) => a.granted);
  return ApprovalState(
    status: denied ? ApprovalStatus.denegada : ApprovalStatus.aprobada,
    discrepancy: denied && granted,
    current: current,
    stale: stale,
  );
}

/// Lo que se acepta en `POST /api/approval`, ya validado.
class ApprovalRequest {
  const ApprovalRequest({required this.recommendationId, required this.incidentId, required this.members, required this.granted, required this.note, required this.who, required this.supersedes});

  final String recommendationId;
  final String incidentId;
  final List<String> members;
  final bool granted;
  final String note;
  final String who;
  final List<String> supersedes;
}

const int kMaxApprovalBytes = 16 * 1024;
const int kMaxApprovalSupersedes = 20;
const int kMaxApprovalMembers = 200;
final RegExp _recId = RegExp(r'^[0-9a-f]{16}$');
final RegExp _control = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');
final RegExp _controlWithNewline = RegExp(r'[\x00-\x1F\x7F]');

/// Validación **estricta** del cuerpo. Lanza [FormatException] con el motivo.
ApprovalRequest parseApprovalRequest(Object? json) {
  if (json is! Map) throw const FormatException('el cuerpo debe ser un objeto JSON');
  const allowed = {'recommendationId', 'incidentId', 'decision', 'note', 'who', 'supersedes', 'members'};
  final extra = json.keys.where((k) => !allowed.contains(k)).toList();
  if (extra.isNotEmpty) throw FormatException('campos desconocidos: ${extra.join(', ')}');

  final rec = json['recommendationId'];
  if (rec is! String || !_recId.hasMatch(rec)) throw const FormatException('recommendationId debe ser 16 cifras hexadecimales');
  final incident = json['incidentId'];
  if (incident is! String || incident.isEmpty || incident.length > 120 || _controlWithNewline.hasMatch(incident)) {
    throw const FormatException('incidentId debe ser texto de 1 a 120 caracteres');
  }
  final decision = json['decision'];
  if (decision != 'granted' && decision != 'denied') throw const FormatException('decision debe ser «granted» o «denied»');
  final who = json['who'];
  if (who is! String || who.trim().isEmpty || who.trim().length > 80 || _controlWithNewline.hasMatch(who.trim())) {
    throw const FormatException('who debe ser texto de 1 a 80 caracteres, sin saltos de línea');
  }
  final note = json['note'] ?? '';
  if (note is! String || note.length > 280 || _control.hasMatch(note)) throw const FormatException('note debe ser texto de hasta 280 caracteres');

  List<String> strings(String k, int max) {
    final v = json[k] ?? const <Object?>[];
    if (v is! List || v.length > max || v.any((e) => e is! String || e.isEmpty || e.length > 120)) {
      throw FormatException('$k debe ser una lista de hasta $max textos');
    }
    return v.cast<String>();
  }

  return ApprovalRequest(
    recommendationId: rec,
    incidentId: incident,
    members: strings('members', kMaxApprovalMembers),
    granted: decision == 'granted',
    note: note,
    who: who.trim(),
    supersedes: strings('supersedes', kMaxApprovalSupersedes),
  );
}
