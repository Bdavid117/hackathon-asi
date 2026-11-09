import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';

/// Un miembro construido con el triaje REAL (señales y citas como las produce el agente 2).
IncidentMember member(
  String key, {
  int rev = 0,
  int flags = 0,
  String? text,
  double? lat = 5.0703,
  double? lon = -75.5138,
  int people = 0,
}) {
  final t = triage(flags, text: text, hasLocation: lat != null);
  return IncidentMember(
    reportKey: key,
    rev: rev,
    urgency: t.urgency,
    signals: t.signals,
    evidence: [
      for (final e in t.evidence) {'code': e.code, if (e.field != null) 'field': e.field!, if (e.quote != null) 'quote': e.quote!},
    ],
    text: text,
    lat: lat,
    lon: lon,
    people: people,
  );
}

IncidentView view(List<IncidentMember> ms, {String id = 'aa-1', int sources = 2, List<String> uncertainty = const []}) => IncidentView(
  id: id,
  urgency: ms.map((m) => m.urgency).reduce((a, b) => a.index <= b.index ? a : b),
  members: ms,
  sources: sources,
  uncertainty: uncertainty,
);

final List<Resource> resources = parseResources(
  jsonEncode({
    'resources': [
      {'id': 'AMB-01', 'kind': 'ambulancia', 'label': 'Ambulancia 1', 'lat': 5.0710, 'lon': -75.5140, 'available': true},
      {'id': 'AMB-02', 'kind': 'ambulancia', 'label': 'Ambulancia 2', 'lat': 5.1500, 'lon': -75.4000, 'available': true},
      {'id': 'BOM-01', 'kind': 'bomberos', 'label': 'Bomberos 1', 'lat': 5.0720, 'lon': -75.5150, 'available': true},
      {'id': 'RES-01', 'kind': 'rescate', 'label': 'Rescate 1', 'lat': 5.0730, 'lon': -75.5160, 'available': true},
      {'id': 'TRA-01', 'kind': 'transito', 'label': 'Tránsito 1', 'lat': 5.0740, 'lon': -75.5170, 'available': true},
    ],
  }),
);
