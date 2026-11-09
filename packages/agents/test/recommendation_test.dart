import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'rec_support.dart';

Recommendation rec(IncidentView v, [List<Resource>? rs]) {
  final out = recommend(v, rs ?? resources);
  expect(out, isA<Recommendation>(), reason: '$out');
  return out as Recommendation;
}

void main() {
  group('recommend: qué propone el agente 6 según las señales con evidencia', () {
    test('atrapado → rescate, con el recurso disponible MÁS CERCANO y una cita al campo', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.atrapado)]));
      expect(r.actions, ['rescate']);
      expect(r.resourceIds, ['RES-01']);
      expect(r.justification.any((c) => c.reportKey == 'aa-1' && c.signal == 'atrapado' && c.field == 'flags.atrapado'), isTrue);
      expect(r.requiresApproval, isTrue);
    });

    test('señales distintas piden recursos distintos, en orden de prioridad (rescate, bomberos, médica, vía)', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.atrapado | SituationFlags.herido | SituationFlags.incendio | SituationFlags.viaBloqueada)]));
      expect(r.actions, ['rescate', 'bomberos', 'atencion_medica', 'despejar_via']);
      expect(r.resourceIds, ['RES-01', 'BOM-01', 'AMB-01', 'TRA-01']);
    });

    test('herido y dificultad respiratoria piden UNA sola atención médica, no dos ambulancias', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.herido | SituationFlags.dificultadRespiratoria)]));
      expect(r.actions, ['atencion_medica']);
      expect(r.resourceIds, ['AMB-01']);
    });

    test('estructura inestable también pide rescate', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.estructuraInestable)]));
      expect(r.actions, ['rescate']);
    });

    test('las señales del texto también cuentan, y se citan con la cita EXACTA', () {
      const text = 'hay una persona atrapada bajo la losa';
      final r = rec(view([member('aa-1', text: text)]));
      expect(r.actions, contains('rescate'));
      final q = r.justification.firstWhere((c) => c.quote != null);
      expect(text, contains(q.quote!));
    });

    test('varios reportes: las señales se unen y cada cita apunta al reporte que la dio', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.atrapado), member('bb-1', flags: SituationFlags.herido, lat: 5.0704, lon: -75.5139)]));
      expect(r.actions, ['rescate', 'atencion_medica']);
      expect(r.justification.where((c) => c.signal == 'herido').single.reportKey, 'bb-1');
      expect(r.justification.where((c) => c.signal == 'atrapado').single.reportKey, 'aa-1');
    });

    test('el recurso se elige cerca del CENTRO de todos los reportes localizados, no del primero', () {
      final r = rec(view([
        member('aa-1', flags: SituationFlags.herido, lat: 5.0703, lon: -75.5138), // junto a AMB-01
        member('bb-1', flags: SituationFlags.herido, lat: 5.150, lon: -75.400), // junto a AMB-02
        member('cc-1', flags: SituationFlags.herido, lat: 5.151, lon: -75.399),
      ]));
      expect(r.resourceIds, ['AMB-02'], reason: 'el centro de los tres queda del lado de AMB-02');
    });

    test('el recurso se elige cerca del CENTRO del incidente, no de un reporte cualquiera', () {
      // dos reportes lejos de AMB-01 pero cerca de AMB-02
      final r = rec(view([member('aa-1', flags: SituationFlags.herido, lat: 5.149, lon: -75.401), member('bb-1', flags: SituationFlags.herido, lat: 5.151, lon: -75.399)]));
      expect(r.resourceIds, ['AMB-02']);
    });
  });

  group('requisitos pendientes: lo que falta para aprobar con criterio', () {
    test('una sola fuente pide una segunda; con varias no', () {
      expect(rec(view([member('aa-1', flags: SituationFlags.herido)], sources: 1)).pending, contains('confirmar_segunda_fuente'));
      expect(rec(view([member('aa-1', flags: SituationFlags.herido)], sources: 2)).pending, isNot(contains('confirmar_segunda_fuente')));
    });

    test('personas sin indicar piden confirmarlas; indicadas, no', () {
      expect(rec(view([member('aa-1', flags: SituationFlags.herido)])).pending, contains('confirmar_personas'));
      expect(rec(view([member('aa-1', flags: SituationFlags.herido, people: 2)])).pending, isNot(contains('confirmar_personas')));
    });

    test('ubicación imprecisa pide confirmarla', () {
      expect(rec(view([member('aa-1', flags: SituationFlags.herido)], uncertainty: ['ubicacion_imprecisa'])).pending, contains('confirmar_ubicacion'));
    });

    test('menores o mayores piden confirmar necesidades especiales', () {
      expect(rec(view([member('aa-1', flags: SituationFlags.herido | SituationFlags.menoresMayores)])).pending, contains('confirmar_necesidades_especiales'));
    });

    test('juicios discrepantes del modelo piden resolverlos antes', () {
      expect(rec(view([member('aa-1', flags: SituationFlags.herido)], uncertainty: ['juicios_discrepantes'])).pending, contains('resolver_juicios_discrepantes'));
    });

    test('sin recurso disponible de un tipo se dice, y no se sustituye por otro tipo', () {
      final none = [resources.firstWhere((r) => r.id == 'AMB-01')];
      final r = rec(view([member('aa-1', flags: SituationFlags.atrapado | SituationFlags.herido)]), none);
      expect(r.resourceIds, ['AMB-01']);
      expect(r.pending, contains('sin_recurso_disponible:rescate'));
    });

    test('con TODOS los recursos no disponibles igual se recomienda la acción, sin recursos y con el motivo', () {
      final off = [for (final r in resources) Resource(id: r.id, kind: r.kind, label: r.label, lat: r.lat, lon: r.lon, available: false)];
      final r = rec(view([member('aa-1', flags: SituationFlags.herido)]), off);
      expect(r.resourceIds, isEmpty);
      expect(r.pending, contains('sin_recurso_disponible:ambulancia'));
    });

    test('la incertidumbre del incidente se copia tal cual y en orden', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.herido)], uncertainty: ['ubicacion_imprecisa', 'fuente_unica']));
      expect(r.uncertainty, ['fuente_unica', 'ubicacion_imprecisa']);
    });
  });

  group('información requerida: si faltan datos mínimos, NO se recomienda', () {
    test('un solo reporte sin ubicación ni texto ni indicadores', () {
      final out = recommend(view([member('aa-1', lat: null, lon: null)]), resources);
      expect(out, isA<InfoRequired>());
      expect((out as InfoRequired).missing, ['ubicacion', 'situacion']);
    });

    test('con ubicación pero sin ninguna señal: falta la situación', () {
      final out = recommend(view([member('aa-1')]), resources);
      expect((out as InfoRequired).missing, ['situacion']);
    });

    test('con señal pero sin ubicación en ningún miembro: falta la ubicación', () {
      final out = recommend(view([member('aa-1', flags: SituationFlags.herido, lat: null, lon: null)]), resources);
      expect((out as InfoRequired).missing, ['ubicacion']);
    });

    test('una señal que dice el modelo pero SIN evidencia verificable no mueve a nadie', () {
      final m = IncidentMember(reportKey: 'aa-1', rev: 0, urgency: Urgency.p1, signals: ['atrapado'], evidence: const [], text: 'algo', lat: 5.07, lon: -75.51, people: 0);
      final out = recommend(view([m]), resources);
      expect(out, isA<InfoRequired>(), reason: 'sin cita ni campo no hay con qué justificar el rescate');
      expect((out as InfoRequired).missing, ['situacion']);
    });
  });

  group('identificador de la recomendación: estable, pequeño, sensible a lo que importa', () {
    IncidentView base() => view([member('aa-1', flags: SituationFlags.atrapado), member('bb-1', flags: SituationFlags.herido, lat: 5.0704, lon: -75.5139)]);

    test('mismo incidente ⇒ mismo id, aunque cambie el orden de los miembros', () {
      final a = rec(base());
      final b = rec(view(base().members.reversed.toList()));
      expect(a.id, b.id);
      expect(a.id, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('valor de oro: la fórmula del identificador no cambia sin que se note', () {
      expect(recommendationId(members: [('aa-1', 0), ('bb-1', 2)], urgency: Urgency.p1, actions: ['rescate', 'atencion_medica'], resourceIds: ['RES-01', 'AMB-01']), '5ab063a14f20583d');
    });

    test('cambia si cambia la revisión de un miembro (el incidente cambió)', () {
      final other = view([member('aa-1', flags: SituationFlags.atrapado, rev: 1), base().members[1]]);
      expect(rec(other).id, isNot(rec(base()).id));
    });

    test('cambia si entra un miembro nuevo', () {
      final other = view([...base().members, member('cc-1', flags: SituationFlags.herido, lat: 5.0705, lon: -75.514)]);
      expect(rec(other).id, isNot(rec(base()).id));
    });

    test('cambia si cambia la urgencia, la acción o el recurso elegido', () {
      final noAmb = [for (final r in resources) if (r.id != 'AMB-01') r];
      expect(rec(base(), noAmb).id, isNot(rec(base()).id), reason: 'otro recurso elegido');
      expect(rec(view([member('aa-1', flags: SituationFlags.atrapado)])).id, isNot(rec(view([member('aa-1', flags: SituationFlags.atrapado | SituationFlags.incendio)])).id));
    });

    test('NO cambia con lo que no es de esta versión: fuentes, confianza, incertidumbre, ni recursos no elegidos', () {
      final a = rec(base());
      final b = rec(view(base().members, sources: 5, uncertainty: ['ubicacion_imprecisa']));
      expect(b.id, a.id);
      final farOff = [for (final r in resources) if (r.id == 'AMB-02') Resource(id: r.id, kind: r.kind, label: r.label, lat: r.lat, lon: r.lon, available: false) else r];
      expect(rec(base(), farOff).id, a.id, reason: 'la ambulancia lejana no era la elegida');
    });

    test('sólo la URGENCIA distinta (mismos miembros y revisiones, p. ej. el modelo subió la prioridad) cambia el id', () {
      final base = recommendationId(members: [('aa-1', 0)], urgency: Urgency.p2, actions: ['rescate'], resourceIds: ['RES-01']);
      expect(recommendationId(members: [('aa-1', 0)], urgency: Urgency.p1, actions: ['rescate'], resourceIds: ['RES-01']), isNot(base));
    });

    test('recommendationId no depende del orden en que se le den los miembros ni los recursos', () {
      final a = recommendationId(members: [('aa-1', 0), ('bb-1', 2)], urgency: Urgency.p1, actions: ['rescate', 'atencion_medica'], resourceIds: ['AMB-01', 'RES-01']);
      final b = recommendationId(members: [('bb-1', 2), ('aa-1', 0)], urgency: Urgency.p1, actions: ['rescate', 'atencion_medica'], resourceIds: ['RES-01', 'AMB-01']);
      expect(b, a);
    });

    test('es pequeño: 16 caracteres hexadecimales', () {
      expect(rec(base()).id.length, 16);
    });
  });

  group('toJson / fromJson estricto', () {
    test('ida y vuelta', () {
      final r = rec(view([member('aa-1', flags: SituationFlags.atrapado)]));
      final back = Recommendation.fromJson(jsonDecode(jsonEncode(r.toJson())));
      expect(jsonEncode(back.toJson()), jsonEncode(r.toJson()));
    });

    test('toJson lleva requires_approval en verdadero y los campos del PDF', () {
      final j = rec(view([member('aa-1', flags: SituationFlags.atrapado)])).toJson();
      expect(j['requires_approval'], true);
      expect(j.keys, containsAll(['id', 'incident_id', 'actions', 'resource_ids', 'justification', 'pending', 'uncertainty', 'requires_approval']));
    });
  });
}
