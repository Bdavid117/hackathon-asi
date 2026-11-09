// Modelos del tablero: lo que sirve el nodo (`/api/incidents`, `/api/incidents/<id>`, `/api/nodes`),
// leído con validación. Un dato mal formado lanza [FormatException]: el tablero prefiere avisar que la
// respuesta no es válida antes que mostrar algo equivocado (p. ej. una urgencia desconocida como P4).

Map<String, Object?> _map(Object? v, String what) {
  if (v is! Map) throw FormatException('«$what» debe ser un objeto');
  return v.cast<String, Object?>();
}

List<Object?> _list(Object? v, String what) {
  if (v is! List) throw FormatException('«$what» debe ser una lista');
  return v;
}

String _str(Object? v, String what) {
  if (v is! String) throw FormatException('«$what» debe ser texto');
  return v;
}

int _int(Object? v, String what) {
  if (v is! num) throw FormatException('«$what» debe ser un número');
  return v.toInt();
}

bool _bool(Object? v, String what) {
  if (v is! bool) throw FormatException('«$what» debe ser verdadero o falso');
  return v;
}

List<String> _strings(Object? v, String what) {
  final l = _list(v ?? const <Object?>[], what);
  return [for (final e in l) _str(e, what)];
}

const List<String> kUrgencies = ['P1', 'P2', 'P3', 'P4'];

// ───────────────────────────── contadores y página ─────────────────────────────

class Counters {
  const Counters({required this.incidents, required this.reports, required this.byUrgency, required this.bareSos, required this.highUncertainty, required this.needsReview, required this.inShortView, required this.followUp});

  factory Counters.fromJson(Object? j) {
    final m = _map(j, 'counters');
    final by = _map(m['byUrgency'], 'byUrgency');
    return Counters(
      incidents: _int(m['incidents'], 'incidents'),
      reports: _int(m['reports'], 'reports'),
      byUrgency: {for (final u in kUrgencies) u: _int(by[u], 'byUrgency.$u')},
      bareSos: _int(m['bareSos'], 'bareSos'),
      highUncertainty: _int(m['highUncertainty'], 'highUncertainty'),
      needsReview: _int(m['needsReview'], 'needsReview'),
      inShortView: _int(m['inShortView'], 'inShortView'),
      followUp: _int(m['followUp'], 'followUp'),
    );
  }

  final int incidents;
  final int reports;
  final Map<String, int> byUrgency;
  final int bareSos;
  final int highUncertainty;
  final int needsReview;
  final int inShortView;
  final int followUp;
}

class BareAggregate {
  const BareAggregate({required this.count, required this.oldestAt, required this.newestAt, required this.sampleIds});

  factory BareAggregate.fromJson(Object? j) {
    final m = _map(j, 'bareSos');
    return BareAggregate(count: _int(m['count'], 'count'), oldestAt: _int(m['oldestAt'], 'oldestAt'), newestAt: _int(m['newestAt'], 'newestAt'), sampleIds: _strings(m['sampleIds'], 'sampleIds'));
  }

  final int count;
  final int oldestAt;
  final int newestAt;
  final List<String> sampleIds;
}

class IncidentsPage {
  const IncidentsPage({required this.view, required this.counters, required this.total, required this.offset, required this.limit, required this.bare, required this.items, this.stale = false, this.ageMs = 0});

  factory IncidentsPage.fromJson(Map<String, Object?> j, {bool stale = false, int ageMs = 0}) => IncidentsPage(
    view: _str(j['view'], 'view'),
    counters: Counters.fromJson(j['counters']),
    total: _int(j['total'], 'total'),
    offset: _int(j['offset'], 'offset'),
    limit: _int(j['limit'], 'limit'),
    bare: j['bareSos'] == null ? null : BareAggregate.fromJson(j['bareSos']),
    items: [for (final i in _list(j['items'], 'items')) IncidentRow.fromJson(_map(i, 'item'))],
    stale: stale,
    ageMs: ageMs,
  );

  final String view;
  final Counters counters;
  final int total;
  final int offset;
  final int limit;

  /// La fila agregada de «SOS sin detalle» (sólo en la vista corta).
  final BareAggregate? bare;
  final List<IncidentRow> items;

  /// El nodo sirvió una versión anterior mientras recalcula (con su antigüedad).
  final bool stale;
  final int ageMs;

  /// La misma página con otra frescura (un 304 reutiliza lo leído, pero la frescura es la de ahora).
  IncidentsPage withFreshness({required bool stale, required int ageMs}) =>
      IncidentsPage(view: view, counters: counters, total: total, offset: offset, limit: limit, bare: bare, items: items, stale: stale, ageMs: ageMs);
}

// ───────────────────────────── incidente ─────────────────────────────

class EvidenceEntry {
  const EvidenceEntry({required this.code, this.field, this.quote, this.reportKey});

  factory EvidenceEntry.fromJson(Object? j) {
    final m = _map(j, 'evidence');
    return EvidenceEntry(code: _str(m['code'], 'code'), field: m['field'] as String?, quote: m['quote'] as String?, reportKey: m['reportKey'] as String?);
  }

  final String code;

  /// Campo estructurado (`flags.atrapado`) o `null` si la evidencia es una cita.
  final String? field;

  /// Cita exacta del texto del reporte.
  final String? quote;
  final String? reportKey;
}

class RecommendationBrief {
  const RecommendationBrief({required this.state, this.id, this.actions = const [], this.resourceIds = const [], this.pending = const [], this.missing = const [], this.reason});

  factory RecommendationBrief.fromJson(Object? j) {
    final m = _map(j, 'recommendation');
    final state = _str(m['state'], 'state');
    if (!const {'propuesta', 'informacion_requerida', 'rechazada'}.contains(state)) throw FormatException('estado de recomendación desconocido: $state');
    return RecommendationBrief(
      state: state,
      id: m['id'] as String?,
      actions: _strings(m['actions'], 'actions'),
      resourceIds: _strings(m['resourceIds'], 'resourceIds'),
      pending: _strings(m['pending'], 'pending'),
      missing: _strings(m['missing'], 'missing'),
      reason: m['reason'] as String?,
    );
  }

  /// `propuesta`, `informacion_requerida` o `rechazada`.
  final String state;
  final String? id;
  final List<String> actions;
  final List<String> resourceIds;
  final List<String> pending;
  final List<String> missing;
  final String? reason;
}

class ApprovalBrief {
  const ApprovalBrief({required this.status, required this.discrepancy, required this.decisions});

  factory ApprovalBrief.fromJson(Object? j) {
    final m = _map(j, 'approval');
    final status = _str(m['status'], 'status');
    if (!const {'pendiente', 'aprobada', 'denegada', 'caduca'}.contains(status)) throw FormatException('estado de aprobación desconocido: $status');
    return ApprovalBrief(
      status: status,
      discrepancy: _bool(m['discrepancy'], 'discrepancy'),
      decisions: m['decisions'] is num ? (m['decisions']! as num).toInt() : (m['current'] is List ? (m['current']! as List).length : 0),
    );
  }

  final String status;
  final bool discrepancy;
  final int decisions;
}

class SharedResource {
  const SharedResource({required this.resourceId, required this.otherIncidents, required this.approvedElsewhere});

  factory SharedResource.fromJson(Object? j) {
    final m = _map(j, 'sharedResource');
    return SharedResource(resourceId: _str(m['resourceId'], 'resourceId'), otherIncidents: _strings(m['otherIncidents'], 'otherIncidents'), approvedElsewhere: m['approvedElsewhere'] == true);
  }

  final String resourceId;
  final List<String> otherIncidents;
  final bool approvedElsewhere;
}

class IncidentRow {
  const IncidentRow({
    required this.id,
    required this.urgency,
    required this.size,
    required this.members,
    required this.signals,
    required this.evidence,
    required this.people,
    required this.peopleLabel,
    required this.sources,
    required this.confidence,
    required this.uncertainty,
    required this.needsReview,
    required this.highUncertainty,
    required this.bareSos,
    required this.lat,
    required this.lon,
    required this.firstAt,
    required this.lastAt,
    required this.recommendation,
    required this.approval,
    required this.shared,
  });

  factory IncidentRow.fromJson(Map<String, Object?> m) {
    final urgency = _str(m['urgency'], 'urgency');
    if (!kUrgencies.contains(urgency)) throw FormatException('urgencia desconocida: $urgency');
    return IncidentRow(
      id: _str(m['id'], 'id'),
      urgency: urgency,
      size: _int(m['size'], 'size'),
      members: _strings(m['members'], 'members'),
      signals: _strings(m['signals'], 'signals'),
      evidence: [for (final e in _list(m['evidence'] ?? const <Object?>[], 'evidence')) EvidenceEntry.fromJson(e)],
      people: _int(m['people'], 'people'),
      peopleLabel: _str(m['peopleLabel'], 'peopleLabel'),
      sources: _int(m['sources'], 'sources'),
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
      uncertainty: _strings(m['uncertainty'], 'uncertainty'),
      needsReview: _bool(m['needsReview'], 'needsReview'),
      highUncertainty: _bool(m['highUncertainty'], 'highUncertainty'),
      bareSos: _bool(m['bareSos'], 'bareSos'),
      lat: (m['lat'] as num?)?.toDouble(),
      lon: (m['lon'] as num?)?.toDouble(),
      firstAt: _int(m['firstAt'], 'firstAt'),
      lastAt: _int(m['lastAt'], 'lastAt'),
      recommendation: RecommendationBrief.fromJson(m['recommendation']),
      approval: ApprovalBrief.fromJson(m['approval']),
      shared: [for (final s in _list(m['sharedResources'] ?? const <Object?>[], 'sharedResources')) SharedResource.fromJson(s)],
    );
  }

  final String id;
  final String urgency;
  final int size;
  final List<String> members;
  final List<String> signals;
  final List<EvidenceEntry> evidence;
  final int people;
  final String peopleLabel;
  final int sources;
  final double confidence;
  final List<String> uncertainty;
  final bool needsReview;
  final bool highUncertainty;
  final bool bareSos;
  final double? lat;
  final double? lon;
  final int firstAt;
  final int lastAt;
  final RecommendationBrief recommendation;
  final ApprovalBrief approval;
  final List<SharedResource> shared;

  bool get hasLocation => lat != null && lon != null;
}

// ───────────────────────────── detalle ─────────────────────────────

class Observation {
  const Observation({required this.reportKey, required this.urgency, required this.rev, required this.flags, required this.text, required this.lat, required this.lon, required this.people, required this.peopleLabel, required this.capturedAt, required this.signals, required this.uncertainty});

  factory Observation.fromJson(Object? j) {
    final m = _map(j, 'member');
    return Observation(
      reportKey: _str(m['reportKey'], 'reportKey'),
      urgency: _str(m['urgency'], 'urgency'),
      rev: _int(m['rev'], 'rev'),
      flags: _int(m['flags'], 'flags'),
      text: m['text'] as String?,
      lat: (m['lat'] as num?)?.toDouble(),
      lon: (m['lon'] as num?)?.toDouble(),
      people: _int(m['people'], 'people'),
      peopleLabel: _str(m['peopleLabel'], 'peopleLabel'),
      capturedAt: _int(m['capturedAt'], 'capturedAt'),
      signals: _strings(m['signals'], 'signals'),
      uncertainty: _strings(m['uncertainty'], 'uncertainty'),
    );
  }

  final String reportKey;
  final String urgency;
  final int rev;
  final int flags;
  final String? text;
  final double? lat;
  final double? lon;
  final int people;
  final String peopleLabel;
  final int capturedAt;
  final List<String> signals;
  final List<String> uncertainty;

  bool get hasLocation => lat != null && lon != null;
}

class Citation {
  const Citation({required this.signal, required this.reportKey, this.field, this.quote});

  factory Citation.fromJson(Object? j) {
    final m = _map(j, 'justification');
    return Citation(signal: _str(m['signal'], 'signal'), reportKey: _str(m['report_key'], 'report_key'), field: m['field'] as String?, quote: m['quote'] as String?);
  }

  final String signal;
  final String reportKey;
  final String? field;
  final String? quote;
}

class ResourceInfo {
  const ResourceInfo({required this.id, required this.kind, required this.label, required this.distanceMeters, required this.available});

  factory ResourceInfo.fromJson(Object? j) {
    final m = _map(j, 'resource');
    return ResourceInfo(id: _str(m['id'], 'id'), kind: _str(m['kind'], 'kind'), label: _str(m['label'], 'label'), distanceMeters: (m['distanceMeters'] as num?)?.toInt(), available: m['available'] == true);
  }

  final String id;
  final String kind;
  final String label;
  final int? distanceMeters;
  final bool available;
}

class RecommendationDetail {
  const RecommendationDetail({required this.brief, required this.justification, required this.uncertainty, required this.requiresApproval, required this.resources});

  factory RecommendationDetail.fromJson(Object? j) {
    final m = _map(j, 'recommendation');
    final brief = RecommendationBrief.fromJson(m);
    final proposed = brief.state == 'propuesta';
    if (proposed && m['requires_approval'] != true) throw const FormatException('una propuesta debe exigir aprobación humana');
    return RecommendationDetail(
      brief: brief,
      justification: [for (final c in _list(m['justification'] ?? const <Object?>[], 'justification')) Citation.fromJson(c)],
      uncertainty: _strings(m['uncertainty'], 'uncertainty'),
      requiresApproval: m['requires_approval'] == true,
      resources: [for (final r in _list(m['resources'] ?? const <Object?>[], 'resources')) ResourceInfo.fromJson(r)],
    );
  }

  final RecommendationBrief brief;
  final List<Citation> justification;
  final List<String> uncertainty;
  final bool requiresApproval;
  final List<ResourceInfo> resources;

  String get state => brief.state;
  String? get id => brief.id;
  List<String> get actions => brief.actions;
  List<String> get pending => brief.pending;
  List<String> get missing => brief.missing;
  String? get reason => brief.reason;

  /// ¿Hay algo que una persona pueda aprobar o rechazar?
  bool get canDecide => state == 'propuesta' && requiresApproval && id != null;
}

class Decision {
  const Decision({required this.eventId, required this.recommendationId, required this.granted, required this.note, required this.who, required this.atMs, required this.supersedes});

  factory Decision.fromJson(Object? j) {
    final m = _map(j, 'decision');
    final d = _str(m['decision'], 'decision');
    if (d != 'granted' && d != 'denied') throw FormatException('decisión desconocida: $d');
    return Decision(eventId: _str(m['eventId'], 'eventId'), recommendationId: _str(m['recommendationId'], 'recommendationId'), granted: d == 'granted', note: (m['note'] as String?) ?? '', who: _str(m['who'], 'who'), atMs: _int(m['at'], 'at'), supersedes: _strings(m['supersedes'], 'supersedes'));
  }

  final String eventId;
  final String recommendationId;
  final bool granted;
  final String note;
  final String who;
  final int atMs;
  final List<String> supersedes;
}

class ApprovalDetail {
  const ApprovalDetail({required this.status, required this.discrepancy, required this.current, required this.stale});

  factory ApprovalDetail.fromJson(Object? j) {
    final m = _map(j, 'approval');
    final brief = ApprovalBrief.fromJson(m);
    return ApprovalDetail(status: brief.status, discrepancy: brief.discrepancy, current: [for (final d in _list(m['current'], 'current')) Decision.fromJson(d)], stale: [for (final d in _list(m['stale'], 'stale')) Decision.fromJson(d)]);
  }

  final String status;
  final bool discrepancy;

  /// Decisiones de la versión vigente de la recomendación, sin sustituir.
  final List<Decision> current;

  /// Decisiones de versiones anteriores (la recomendación cambió).
  final List<Decision> stale;
}

class IncidentDetail {
  const IncidentDetail({required this.row, required this.members, required this.evidence, required this.recommendation, required this.approval, required this.membersTotal, this.stale = false, this.ageMs = 0});

  factory IncidentDetail.fromJson(Map<String, Object?> j, {bool stale = false, int ageMs = 0}) {
    if (j['recommendation'] == null) throw const FormatException('el detalle no trae la recomendación');
    return IncidentDetail(
      row: IncidentRow.fromJson(j),
      members: [for (final m in _list(j['observations'], 'observations')) Observation.fromJson(m)],
      evidence: [for (final e in _list(j['evidence'], 'evidence')) EvidenceEntry.fromJson(e)],
      recommendation: RecommendationDetail.fromJson(j['recommendation']),
      approval: ApprovalDetail.fromJson(j['approval']),
      membersTotal: _int(j['membersTotal'], 'membersTotal'),
      stale: stale,
      ageMs: ageMs,
    );
  }

  final IncidentRow row;
  final List<Observation> members;
  final List<EvidenceEntry> evidence;
  final RecommendationDetail recommendation;
  final ApprovalDetail approval;
  final int membersTotal;
  final bool stale;
  final int ageMs;
}

// ───────────────────────────── nodos ─────────────────────────────

class PeerInfo {
  const PeerInfo({required this.url, required this.state, this.lastSeenAgoMs, this.lastSyncAgoMs, this.missingEvents, this.lastError});

  factory PeerInfo.fromJson(Object? j) {
    final m = _map(j, 'peer');
    return PeerInfo(url: _str(m['url'], 'url'), state: _str(m['state'], 'state'), lastSeenAgoMs: (m['lastSeenAgoMs'] as num?)?.toInt(), lastSyncAgoMs: (m['lastSyncAgoMs'] as num?)?.toInt(), missingEvents: (m['missingEvents'] as num?)?.toInt(), lastError: m['lastError'] as String?);
  }

  final String url;
  final String state;
  final int? lastSeenAgoMs;
  final int? lastSyncAgoMs;
  final int? missingEvents;
  final String? lastError;
}

class NodesStatus {
  const NodesStatus({required this.selfId, required this.events, required this.peers, required this.partialView, required this.reasons});

  factory NodesStatus.fromJson(Map<String, Object?> j) {
    final self = _map(j['self'], 'self');
    return NodesStatus(selfId: _str(self['id'], 'id'), events: _int(self['events'], 'events'), peers: [for (final p in _list(j['peers'], 'peers')) PeerInfo.fromJson(p)], partialView: _bool(j['partialView'], 'partialView'), reasons: _strings(j['reasons'], 'reasons'));
  }

  final String selfId;
  final int events;
  final List<PeerInfo> peers;
  final bool partialView;
  final List<String> reasons;
}

// ───────────────────────────── etiquetas en español ─────────────────────────────

/// «codigo_futuro_raro» → «Codigo futuro raro»: un código que el tablero aún no conoce se muestra
/// legible en vez de romper.
String _humanize(String code) {
  final t = code.replaceAll('_', ' ').replaceAll(':', ' ');
  return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
}

const Map<String, String> _signals = {
  'atrapado': 'Atrapado',
  'herido': 'Herido',
  'incendio': 'Incendio',
  'dificultad_respiratoria': 'Dificultad para respirar',
  'via_bloqueada': 'Vía bloqueada',
  'estructura_inestable': 'Estructura inestable',
  'menores_mayores': 'Menores / mayores',
  'medicacion': 'Necesita medicación',
  'ubicacion': 'Ubicación',
};

String signalLabel(String code) => _signals[code] ?? _humanize(code);

const Map<String, String> _uncertainty = {
  'sin_detalle': 'Sin detalle',
  'texto_no_interpretado': 'Texto no interpretado',
  'ubicacion_ausente': 'Sin ubicación',
  'ubicacion_imprecisa': 'Ubicación imprecisa',
  'fuente_unica': 'Fuente única',
  'juicios_discrepantes': 'Juicios discrepantes',
  'baja_confianza_modelo': 'Baja confianza del modelo',
  'texto_truncado': 'Texto truncado',
};

String uncertaintyLabel(String code) => _uncertainty[code] ?? _humanize(code);

const Map<String, String> _actions = {
  'rescate': 'Enviar rescate',
  'bomberos': 'Enviar bomberos',
  'atencion_medica': 'Enviar atención médica',
  'despejar_via': 'Despejar la vía',
};

String actionLabel(String code) => _actions[code] ?? _humanize(code);

const Map<String, String> _pending = {
  'confirmar_segunda_fuente': 'Confirmar con una segunda fuente',
  'confirmar_ubicacion': 'Confirmar la ubicación',
  'confirmar_personas': 'Confirmar cuántas personas hay',
  'confirmar_necesidades_especiales': 'Confirmar necesidades especiales (menores, mayores, medicación)',
  'resolver_juicios_discrepantes': 'Resolver los juicios discrepantes',
};

String pendingLabel(String code) {
  if (code.startsWith('sin_recurso_disponible:')) return 'No hay ${code.substring('sin_recurso_disponible:'.length)} disponible';
  return _pending[code] ?? _humanize(code);
}

String missingLabel(String code) => switch (code) {
  'ubicacion' => 'la ubicación',
  'situacion' => 'qué está pasando (indicadores o un texto)',
  _ => _humanize(code).toLowerCase(),
};

String approvalLabel(String status) => switch (status) {
  'pendiente' => 'Pendiente de decisión',
  'aprobada' => 'Aprobada',
  'denegada' => 'Rechazada',
  'caduca' => 'Caducada: el incidente cambió',
  _ => _humanize(status),
};

String peerStateLabel(String state) => switch (state) {
  'sincronizado' => 'Sincronizado',
  'atrasado' => 'Atrasado',
  'sin_respuesta' => 'Sin respuesta',
  'desconocido' => 'Sin contacto todavía',
  _ => _humanize(state),
};

String partialReasonLabel(String code) => switch (code) {
  'par_desconocido' => 'Con algún nodo todavía no se ha hablado desde que este arrancó.',
  'par_sin_respuesta' => 'Algún nodo no responde: puede tener reportes que este aún no ve.',
  'faltan_eventos' => 'Todavía faltan eventos por traer de algún nodo.',
  _ => _humanize(code),
};

// ───────────────────────────── tiempo ─────────────────────────────

String _two(int n) => n.toString().padLeft(2, '0');

/// La hora local («14:07») de unos segundos de época.
String clockLabel(int epochSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// «hace 5 s», «hace 3 min», «hace 2 h», «hace 3 d». Un reloj adelantado no da tiempos negativos.
String ageLabel(int epochSeconds, DateTime now) {
  final s = now.difference(DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000)).inSeconds;
  if (s < 5) return 'ahora mismo';
  if (s < 60) return 'hace $s s';
  if (s < 3600) return 'hace ${s ~/ 60} min';
  if (s < 86400) return 'hace ${s ~/ 3600} h';
  return 'hace ${s ~/ 86400} d';
}
