import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'resources.dart';
import 'triage.dart';

// ───────────────────────────── el agente 6 ─────────────────────────────
//
// Propone qué recursos movilizar para un incidente. Es una **plantilla determinista**: no usa modelo,
// no tiene herramienta de despacho y su salida es una *propuesta* que una persona aprueba o rechaza.
// Todo lo que nombra se comprueba (`validateRecommendation`): recursos que existen y están
// disponibles, citas que son subcadena del texto o campo que existe, acciones de un conjunto cerrado.

/// Acciones posibles, en orden de prioridad. Conjunto **cerrado**.
const List<String> kActions = ['rescate', 'bomberos', 'atencion_medica', 'despejar_via'];

/// Qué tipo de recurso atiende cada acción.
const Map<String, ResourceKind> kActionKind = {
  'rescate': ResourceKind.rescate,
  'bomberos': ResourceKind.bomberos,
  'atencion_medica': ResourceKind.ambulancia,
  'despejar_via': ResourceKind.transito,
};

/// Señal → acción, en el orden en que se citan.
const List<(String, String)> kSignalActions = [
  ('atrapado', 'rescate'),
  ('estructura_inestable', 'rescate'),
  ('incendio', 'bomberos'),
  ('herido', 'atencion_medica'),
  ('dificultad_respiratoria', 'atencion_medica'),
  ('via_bloqueada', 'despejar_via'),
];

/// Un reporte del incidente tal como lo ve el agente 6.
class IncidentMember {
  const IncidentMember({
    required this.reportKey,
    required this.rev,
    required this.urgency,
    required this.signals,
    required this.evidence,
    required this.text,
    required this.lat,
    required this.lon,
    required this.people,
  });

  final String reportKey;
  final int rev;
  final Urgency urgency;
  final List<String> signals;

  /// Una entrada por señal: `{code, field}` (campo estructurado) o `{code, quote}` (cita del texto).
  final List<Map<String, String>> evidence;
  final String? text;
  final double? lat;
  final double? lon;

  /// Código de `PeopleBucket` (0 = no indicado).
  final int people;

  bool get hasLocation => lat != null && lon != null;
}

/// El incidente (un grupo de reportes) sobre el que se recomienda.
class IncidentView {
  const IncidentView({required this.id, required this.urgency, required this.members, required this.sources, required this.uncertainty});

  final String id;

  /// La más grave de las urgencias de los miembros.
  final Urgency urgency;
  final List<IncidentMember> members;
  final int sources;
  final List<String> uncertainty;
}

/// Una cita que respalda la recomendación: qué señal, en qué reporte, y su campo o su texto exacto.
class Citation {
  const Citation({required this.signal, required this.reportKey, this.field, this.quote});

  /// Código de la señal (`atrapado`…) o `ubicacion`.
  final String signal;
  final String reportKey;
  final String? field;
  final String? quote;

  Map<String, Object?> toJson() => {'signal': signal, 'report_key': reportKey, if (field != null) 'field': field, if (quote != null) 'quote': quote};
}

/// Resultado de recomendar.
sealed class RecommendationOutcome {
  const RecommendationOutcome();
}

/// La propuesta. **Siempre** requiere aprobación humana.
class Recommendation extends RecommendationOutcome {
  const Recommendation({
    required this.id,
    required this.incidentId,
    required this.actions,
    required this.resourceIds,
    required this.justification,
    required this.pending,
    required this.uncertainty,
    this.requiresApproval = true,
  });

  final String id;
  final String incidentId;
  final List<String> actions;
  final List<String> resourceIds;
  final List<Citation> justification;

  /// Requisitos pendientes antes de aprobar con criterio (códigos).
  final List<String> pending;
  final List<String> uncertainty;
  final bool requiresApproval;

  Map<String, Object?> toJson() => {
    'id': id,
    'incident_id': incidentId,
    'actions': actions,
    'resource_ids': resourceIds,
    'justification': [for (final c in justification) c.toJson()],
    'pending': pending,
    'uncertainty': uncertainty,
    'requires_approval': requiresApproval,
  };

  static const _keys = {'id', 'incident_id', 'actions', 'resource_ids', 'justification', 'pending', 'uncertainty', 'requires_approval'};

  /// Lectura **estricta**: ni campos de más ni de menos, tipos exactos. Lanza [FormatException].
  factory Recommendation.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('la recomendación debe ser un objeto');
    final extra = json.keys.where((k) => !_keys.contains(k)).toList();
    if (extra.isNotEmpty) throw FormatException('campos fuera de esquema: ${extra.join(', ')}');
    final missing = _keys.where((k) => !json.containsKey(k)).toList();
    if (missing.isNotEmpty) throw FormatException('faltan campos: ${missing.join(', ')}');
    List<String> strings(String k) {
      final v = json[k];
      if (v is! List || v.any((e) => e is! String)) throw FormatException('«$k» debe ser una lista de textos');
      return v.cast<String>();
    }

    final id = json['id'], incident = json['incident_id'], approval = json['requires_approval'], just = json['justification'];
    if (id is! String) throw const FormatException('«id» debe ser texto');
    if (incident is! String) throw const FormatException('«incident_id» debe ser texto');
    if (approval is! bool) throw const FormatException('«requires_approval» debe ser booleano');
    if (just is! List) throw const FormatException('«justification» debe ser una lista');
    final citations = <Citation>[];
    for (final c in just) {
      if (c is! Map) throw const FormatException('cada cita debe ser un objeto');
      final bad = c.keys.where((k) => !{'signal', 'report_key', 'field', 'quote'}.contains(k)).toList();
      if (bad.isNotEmpty) throw FormatException('campos fuera de esquema en una cita: ${bad.join(', ')}');
      final signal = c['signal'], key = c['report_key'], field = c['field'], quote = c['quote'];
      if (signal is! String || key is! String || (field != null && field is! String) || (quote != null && quote is! String)) {
        throw const FormatException('cita con tipos inválidos');
      }
      citations.add(Citation(signal: signal, reportKey: key, field: field as String?, quote: quote as String?));
    }
    return Recommendation(
      id: id,
      incidentId: incident,
      actions: strings('actions'),
      resourceIds: strings('resource_ids'),
      justification: citations,
      pending: strings('pending'),
      uncertainty: strings('uncertainty'),
      requiresApproval: approval,
    );
  }
}

/// No hay datos mínimos para recomendar: se pide información en vez de inventar.
class InfoRequired extends RecommendationOutcome {
  const InfoRequired(this.missing);

  /// `ubicacion` y/o `situacion`.
  final List<String> missing;
}

/// La propuesta no pasó la validación (o no tenía el esquema): no se muestra como recomendación.
class Rejected extends RecommendationOutcome {
  const Rejected(this.reason);
  final String reason;
}

/// Identificador **pequeño y estable** de la versión del incidente + lo propuesto.
///
/// Sólo entran el conjunto de (reporte, revisión) de los miembros, la urgencia, las acciones y los
/// recursos elegidos, en orden canónico: nada de confianzas en coma flotante, ni el orden de las
/// listas, ni la disponibilidad de otros recursos. Cambia cuando el incidente cambia (otro miembro,
/// otra revisión, otra urgencia) y entonces la aprobación anterior caduca.
String recommendationId({
  required List<(String, int)> members,
  required Urgency urgency,
  required List<String> actions,
  required List<String> resourceIds,
}) {
  final ms = [for (final m in members) '${m.$1}@${m.$2}']..sort();
  final text = '${ms.join(',')}|${urgency.name}|${actions.join('+')}|${([...resourceIds]..sort()).join('+')}';
  return sha256.convert(utf8.encode(text)).toString().substring(0, 16);
}

/// La evidencia verificable de [signal] en [m]: una entrada de evidencia cuya cita es subcadena del
/// texto del miembro, o cuyo campo es el de la bandera. `null` si no hay con qué respaldarla.
Citation? _citationFor(IncidentMember m, String signal) {
  if (!m.signals.contains(signal)) return null;
  for (final e in m.evidence) {
    if (e['code'] != signal) continue;
    final q = e['quote'], f = e['field'];
    if (q != null && q.isNotEmpty && (m.text?.contains(q) ?? false)) return Citation(signal: signal, reportKey: m.reportKey, quote: q);
    if (f != null && f == 'flags.$signal') return Citation(signal: signal, reportKey: m.reportKey, field: f);
  }
  return null;
}

/// Propone la movilización de recursos para [v], o pide información si no hay datos mínimos.
RecommendationOutcome recommend(IncidentView v, List<Resource> resources) {
  final members = [...v.members]..sort((a, b) => a.reportKey.compareTo(b.reportKey));
  final located = [for (final m in members) if (m.hasLocation) m];

  // Señales que mueven recursos: SÓLO las que tienen evidencia verificable en algún miembro.
  final driving = <Citation>[];
  for (final (signal, _) in kSignalActions) {
    for (final m in members) {
      final c = _citationFor(m, signal);
      if (c != null) {
        driving.add(c);
        break;
      }
    }
  }
  final actions = [
    for (final a in kActions)
      if (driving.any((c) => kSignalActions.any((s) => s.$1 == c.signal && s.$2 == a))) a,
  ];

  final missing = [if (located.isEmpty) 'ubicacion', if (actions.isEmpty) 'situacion'];
  if (missing.isNotEmpty) return InfoRequired(missing);

  var lat = 0.0, lon = 0.0;
  for (final m in located) {
    lat += m.lat!;
    lon += m.lon!;
  }
  lat /= located.length;
  lon /= located.length;

  final resourceIds = <String>[];
  final unavailable = <String>[];
  for (final a in actions) {
    final r = nearestAvailable(resources, kActionKind[a]!, lat, lon);
    if (r == null) {
      unavailable.add('sin_recurso_disponible:${kActionKind[a]!.name}');
    } else {
      resourceIds.add(r.id);
    }
  }

  final uncertainty = (v.uncertainty.toSet().toList()..sort());
  final pending = <String>[
    if (v.sources <= 1) 'confirmar_segunda_fuente',
    if (uncertainty.contains('ubicacion_imprecisa')) 'confirmar_ubicacion',
    if (members.every((m) => m.people == 0)) 'confirmar_personas',
    if (members.any((m) => m.signals.contains('menores_mayores') || m.signals.contains('medicacion'))) 'confirmar_necesidades_especiales',
    if (uncertainty.contains('juicios_discrepantes')) 'resolver_juicios_discrepantes',
    ...unavailable,
  ];

  return Recommendation(
    id: recommendationId(members: [for (final m in members) (m.reportKey, m.rev)], urgency: v.urgency, actions: actions, resourceIds: resourceIds),
    incidentId: v.id,
    actions: actions,
    resourceIds: resourceIds,
    justification: [...driving, Citation(signal: 'ubicacion', reportKey: located.first.reportKey, field: 'location')],
    pending: pending,
    uncertainty: uncertainty,
  );
}

final RegExp _codePattern = RegExp(r'^[a-z0-9_:]{1,64}$');

/// Comprueba una propuesta —venga de la plantilla o de cualquier otro proponente— contra el incidente
/// y los recursos **actuales**. Devuelve `null` si es válida o [Rejected] con el primer motivo.
///
/// Es la puerta de seguridad: una propuesta con un recurso que no existe o no está disponible, una cita
/// que no es subcadena del texto, una acción fuera del conjunto cerrado, texto libre donde van códigos,
/// un identificador que no corresponde a esta versión del incidente o sin aprobación humana, no pasa.
Rejected? validateRecommendation(Recommendation r, IncidentView v, List<Resource> resources) {
  if (!r.requiresApproval) return const Rejected('sin_aprobacion_humana: toda propuesta exige aprobación');
  if (r.incidentId != v.id) return Rejected('incidente_distinto: ${r.incidentId} ≠ ${v.id}');

  if (r.actions.isEmpty) return const Rejected('acciones_vacias');
  final seenActions = <String>{};
  for (final a in r.actions) {
    if (!kActions.contains(a)) return Rejected('accion_desconocida: $a');
    if (!seenActions.add(a)) return Rejected('accion_repetida: $a');
  }

  final byId = {for (final x in resources) x.id: x};
  final allowedKinds = {for (final a in r.actions) kActionKind[a]!};
  final seenResources = <String>{};
  for (final id in r.resourceIds) {
    final res = byId[id];
    if (res == null) return Rejected('recurso_inexistente: $id');
    if (!res.available) return Rejected('recurso_no_disponible: $id');
    if (!seenResources.add(id)) return Rejected('recurso_repetido: $id');
    if (!allowedKinds.contains(res.kind)) return Rejected('recurso_de_otro_tipo: $id');
  }

  final members = {for (final m in v.members) m.reportKey: m};
  final backed = <String>{};
  for (final c in r.justification) {
    final m = members[c.reportKey];
    if (m == null) return Rejected('cita_de_reporte_ajeno: ${c.reportKey}');
    if (c.signal == 'ubicacion') {
      if (c.field != 'location' || c.quote != null || !m.hasLocation) return Rejected('cita_ubicacion_invalida: ${c.reportKey}');
      continue;
    }
    final action = kSignalActions.where((s) => s.$1 == c.signal).map((s) => s.$2).firstOrNull;
    if (action == null) return Rejected('senal_desconocida: ${c.signal}');
    if (!m.signals.contains(c.signal)) return Rejected('senal_no_presente: ${c.signal} en ${c.reportKey}');
    if (c.quote != null) {
      final ok = c.quote!.isNotEmpty && (m.text?.contains(c.quote!) ?? false) && m.evidence.any((e) => e['code'] == c.signal && e['quote'] == c.quote);
      if (!ok) return Rejected('cita_inventada: «${c.quote}» no está en el texto de ${c.reportKey}');
    } else if (c.field != null) {
      if (c.field != 'flags.${c.signal}' || !m.evidence.any((e) => e['code'] == c.signal && e['field'] == c.field)) {
        return Rejected('campo_inexistente: ${c.field} en ${c.reportKey}');
      }
    } else {
      return Rejected('cita_sin_evidencia: ${c.signal} en ${c.reportKey}');
    }
    backed.add(action);
  }
  for (final a in r.actions) {
    if (!backed.contains(a)) return Rejected('accion_sin_cita: $a');
  }

  for (final code in [...r.pending, ...r.uncertainty]) {
    if (!_codePattern.hasMatch(code)) return const Rejected('texto_libre_en_codigo: los requisitos y la incertidumbre son códigos, no texto');
  }

  final expected = recommendationId(
    members: [for (final m in v.members) (m.reportKey, m.rev)],
    urgency: v.urgency,
    actions: r.actions,
    resourceIds: r.resourceIds,
  );
  if (r.id != expected) return const Rejected('id_no_coincide: no corresponde a esta versión del incidente');
  return null;
}

/// La puerta única para una propuesta en JSON (de la plantilla o de un modelo): lectura estricta y
/// validación. Devuelve la [Recommendation] o [Rejected]; **nunca** lanza ni deja pasar algo dudoso.
RecommendationOutcome acceptRecommendationJson(String source, IncidentView v, List<Resource> resources) {
  final Recommendation r;
  try {
    r = Recommendation.fromJson(jsonDecode(source));
  } on FormatException catch (e) {
    return Rejected('fuera_de_esquema: ${e.message}');
  }
  return validateRecommendation(r, v, resources) ?? r;
}
