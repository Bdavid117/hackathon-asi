import 'dart:math';

import 'correlation.dart';
import 'geo.dart';
import 'text_sim.dart';

/// Qué tan creíble es un grupo de reportes y cuántas fuentes **independientes** hay detrás.
class GroupAssessment {
  const GroupAssessment({
    required this.reports,
    required this.devices,
    required this.independentSources,
    required this.confidence,
    required this.uncertainty,
    this.contradictionsEvaluated = false,
  });

  final int reports;
  final int devices;

  /// Familias de copias: cada una cuenta como una sola fuente.
  final int independentSources;

  /// `P(real) = 1 − Π(1 − pᵢ·wᵢ)` sobre las familias (noisy-OR). Contar mensajes no mide
  /// confianza; contar fuentes independientes, sí.
  final double confidence;
  final List<String> uncertainty;

  /// Sin modelo de lenguaje las contradicciones no se detectan: se dice «no evaluadas» en vez de
  /// afirmar que no las hay.
  final bool contradictionsEvaluated;
}

class _Rep {
  _Rep(this.tokens, this.minT, this.maxT, this.located);
  final Set<String> tokens;
  int minT, maxT;
  Observation? located;
}

/// ¿Son [a] y [b] copias una de otra? Textos casi idénticos (con al menos 3 palabras de contenido),
/// cercanos en el tiempo y que no estén en lugares incompatibles.
bool _isCopy(String ta, _Rep a, String tb, _Rep b, Duration window, double minSimilarity) {
  if (a.tokens.length < 3 || b.tokens.length < 3) return false;
  if (textSimilarity(ta, tb) < minSimilarity) return false;
  final gap = max(0, max(a.minT, b.minT) - min(a.maxT, b.maxT));
  if (gap > window.inMilliseconds) return false;
  final la = a.located, lb = b.located;
  if (la != null && lb != null) {
    final d = distanceMeters(la.lat!, la.lon!, lb.lat!, lb.lon!);
    if (d >= la.sigma! + lb.sigma!) return false; // mismas palabras en otro lugar: otra persona
  }
  return true;
}

/// Evalúa un grupo: cada dispositivo cuenta una vez; los dispositivos con textos casi idénticos y
/// cercanos en el tiempo y el espacio forman una **familia de copias** que cuenta como una sola
/// fuente; la confianza combina las familias con noisy-OR usando la credibilidad base de su clase
/// de fuente (la de su origen más creíble).
///
/// Es conservadora a propósito: dos personas que por casualidad escriben lo mismo, juntas y casi a
/// la vez, se cuentan como una; es preferible subestimar la confianza que amplificar un rumor.
GroupAssessment assessGroup(
  List<Observation> members, {
  Map<String, double> baseCredibility = const {'app': 0.6, 'radio': 0.2},
  Duration copyWindow = const Duration(minutes: 30),
  double copySimilarity = 0.8,
}) {
  if (members.isEmpty) {
    return const GroupAssessment(reports: 0, devices: 0, independentSources: 0, confidence: 0, uncertainty: []);
  }
  final byDevice = <String, List<Observation>>{};
  for (final m in members) {
    (byDevice[m.deviceId] ??= []).add(m);
  }
  final devs = byDevice.keys.toList()..sort();

  // Representantes: un texto distinto por dispositivo, con el intervalo de tiempo en que lo envió.
  final reps = <String, Map<String, _Rep>>{};
  for (final d in devs) {
    final m = <String, _Rep>{};
    for (final o in byDevice[d]!) {
      final text = o.text;
      if (text == null) continue;
      final key = normalizeText(text);
      final r = m.putIfAbsent(key, () => _Rep(contentTokens(text), o.capturedAtMs, o.capturedAtMs, null));
      r.minT = min(r.minT, o.capturedAtMs);
      r.maxT = max(r.maxT, o.capturedAtMs);
      if (r.located == null && o.hasLocation) r.located = o;
    }
    reps[d] = m;
  }
  String originalText(String device, String key) =>
      byDevice[device]!.firstWhere((o) => o.text != null && normalizeText(o.text!) == key).text!;

  final parent = {for (final d in devs) d: d};
  String find(String x) {
    var r = x;
    while (parent[r] != r) {
      r = parent[r]!;
    }
    return r;
  }

  for (var i = 0; i < devs.length; i++) {
    for (var j = i + 1; j < devs.length; j++) {
      if (find(devs[i]) == find(devs[j])) continue;
      var copy = false;
      for (final ea in reps[devs[i]]!.entries) {
        for (final eb in reps[devs[j]]!.entries) {
          if (_isCopy(originalText(devs[i], ea.key), ea.value, originalText(devs[j], eb.key), eb.value, copyWindow, copySimilarity)) {
            copy = true;
            break;
          }
        }
        if (copy) break;
      }
      if (copy) parent[find(devs[j])] = find(devs[i]);
    }
  }

  final families = <String, List<String>>{};
  for (final d in devs) {
    (families[find(d)] ??= []).add(d);
  }
  var notP = 1.0;
  for (final fam in families.values) {
    var p = 0.0;
    for (final d in fam) {
      for (final o in byDevice[d]!) {
        p = max(p, baseCredibility[o.sourceClass] ?? 0.5);
      }
    }
    notP *= 1 - p; // wᵢ = 1: las familias son independientes entre sí por construcción
  }

  final uncertainty = <String>[];
  if (families.length == 1) uncertainty.add('fuente_unica');
  if (devs.length > families.length) uncertainty.add('fuente_no_independiente');
  if (!members.any((o) => o.hasLocation)) uncertainty.add('ubicacion_ausente');

  return GroupAssessment(
    reports: members.length,
    devices: devs.length,
    independentSources: families.length,
    confidence: (1 - notP).clamp(0.0, 1.0),
    uncertainty: uncertainty,
  );
}
