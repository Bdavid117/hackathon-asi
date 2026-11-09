import 'dart:math';

import 'package:sard_agents/sard_agents.dart' show Urgency;
import 'package:sard_protocol/sard_protocol.dart';

/// Generador de datos sintéticos **con verdad de referencia** (T06, T07, T08).
///
/// Los agentes NUNCA ven los campos `true*`, `subgroup` ni `tags`: sólo los usa quien mide.
///
/// ### Qué supone (y por tanto qué NO demuestra)
/// Las fracciones de «casos difíciles» de los sucesos P1 son **supuestos del autor**, fijados antes
/// de escribir las reglas de triaje y comprobados por `synth_test.dart`:
/// 55 % banderas coherentes · 20 % banderas parciales con texto que completa · 10 % sin banderas
/// pero con texto · 10 % sin banderas ni texto («sin pistas») · 5 % banderas equivocadas.
/// Los textos tienen una parte «léxica» (palabras obvias) y otra «parafraseada» (coloquial o
/// indirecta). Autor del generador y de las reglas son la misma persona: una cifra alta de
/// reconocimiento de paráfrasis sería sospechosa, no una prueba.

/// Un suceso real (la verdad de referencia que los agentes no ven).
class SynthIncident {
  const SynthIncident({
    required this.id,
    required this.lat,
    required this.lon,
    required this.startMs,
    required this.type,
    required this.urgency,
    required this.latentFlags,
    this.twinOf,
  });

  final int id;
  final double lat;
  final double lon;
  final int startMs;
  final int type;
  final Urgency urgency;
  final int latentFlags;

  /// Si es un gemelo adversarial, el suceso base al que se parece.
  final int? twinOf;
}

/// Lo que el nodo vería de un reporte, más su verdad de referencia.
class SynthReport {
  const SynthReport({
    required this.reportKey,
    required this.deviceId,
    required this.incidentType,
    required this.flags,
    required this.lat,
    required this.lon,
    required this.locQuality,
    required this.capturedAtMs,
    required this.text,
    required this.sourceClass,
    required this.trueIncident,
    required this.trueUrgency,
    required this.subgroup,
    required this.tags,
  });

  final String reportKey;
  final String deviceId;
  final int incidentType;
  final int flags;
  final double? lat;
  final double? lon;
  final LocQuality locQuality;
  final int capturedAtMs;
  final String? text;

  /// `app` (teléfono, con ubicación y texto propio) o `radio` (rumor de segunda mano).
  final String sourceClass;

  // --- verdad de referencia ---
  /// Suceso real al que pertenece; `-1` = rumor sin suceso.
  final int trueIncident;
  final Urgency trueUrgency;

  /// `banderas_coherentes`, `parcial_con_texto`, `sin_banderas_con_texto`, `sin_pistas`,
  /// `banderas_equivocadas` (sólo sucesos P1) o `no_p1`.
  final String subgroup;

  /// `con_texto`, `sin_texto`, `sin_ubicacion`, `ubicacion_imprecisa`, `parafraseado`,
  /// `con_faltas`, `reloj_desfasado`, `gemelo`, `repetido`.
  final Set<String> tags;

  /// Cadena estable para comparar conjuntos entre ejecuciones.
  String get signature =>
      '$reportKey|$deviceId|$incidentType|$flags|$lat|$lon|${locQuality.index}|$capturedAtMs|$text|$sourceClass|$trueIncident|${trueUrgency.name}|$subgroup|${(tags.toList()..sort()).join(',')}';
}

class SynthDataset {
  const SynthDataset(this.reports, this.incidents);
  final List<SynthReport> reports;
  final Map<int, SynthIncident> incidents;
}

class SynthConfig {
  const SynthConfig({
    this.seed = 1,
    this.incidents = 80,
    this.reports = 1000,
    this.adversarialPairs = 20,
    this.twinReports = 5,
  });

  final int seed;
  final int incidents;
  final int reports;

  /// Cuántos sucesos base tienen un gemelo adversarial (otro suceso, cerca y casi simultáneo).
  final int adversarialPairs;
  final int twinReports;
}

// ---------------------------------------------------------------------------------------------
// Estado latente → urgencia verdadera. Código propio, independiente de las reglas de triaje
// (aunque la política es la misma tabla del PDF).
// ---------------------------------------------------------------------------------------------
const int _a = SituationFlags.atrapado;
const int _h = SituationFlags.herido;
const int _f = SituationFlags.incendio;
const int _r = SituationFlags.dificultadRespiratoria;
const int _v = SituationFlags.viaBloqueada;
const int _e = SituationFlags.estructuraInestable;
const int _m = SituationFlags.menoresMayores;
const int _med = SituationFlags.medicacion;

Urgency _truth(int l) {
  bool has(int f) => l & f != 0;
  if (has(_r) || (has(_a) && has(_h)) || (has(_a) && has(_f))) return Urgency.p1;
  if (has(_a) || has(_f) || has(_h) || has(_e)) return Urgency.p2;
  if (has(_v) || has(_m) || has(_med)) return Urgency.p3;
  return Urgency.p4;
}

// ---------------------------------------------------------------------------------------------
// Bancos de frases. «léxicas»: palabras obvias. «paráfrasis»: coloquial o indirecto.
// ---------------------------------------------------------------------------------------------
const Map<int, List<String>> _lexical = {
  _a: [
    'estoy atrapado',
    'estamos atrapados',
    'atrapada bajo la losa',
    'atrapados en el segundo piso',
  ],
  _h: ['hay heridos', 'estoy herida', 'mi hijo está herido', 'varios heridos'],
  _f: ['hay un incendio', 'se está quemando', 'fuego en el edificio'],
  _r: ['no respira', 'dificultad para respirar', 'se ahoga'],
  _v: ['vía bloqueada', 'calle bloqueada', 'derrumbe en la vía'],
  _m: ['hay niños', 'adultos mayores solos', 'un bebé'],
  _e: ['edificio a punto de caer', 'pared agrietada'],
  _med: ['necesita medicamentos', 'se le acabó la insulina'],
};
const Map<int, List<String>> _paraphrase = {
  _a: [
    'no puedo moverme, tengo algo encima',
    'la puerta no abre y no hay salida',
    'quedamos encerrados',
    'me cayó el techo encima',
  ],
  _h: ['mucha sangre', 'se rompió la pierna', 'no se levanta'],
  _f: ['mucho humo negro', 'se prendió todo', 'sale humo por las ventanas'],
  _r: ['me falta el aire', 'no le entra aire', 'está morado'],
  _v: ['no se puede pasar por el puente', 'el camino quedó tapado'],
  _m: ['mi abuela no camina', 'están los pequeños solos'],
  _e: ['se escucha que cruje todo', 'esto se va a venir abajo'],
  _med: ['le toca su pastilla y no tenemos'],
};
const List<String> _negations = ['sin heridos', 'nadie herido', 'no hay atrapados', 'sin fuego'];
const List<String> _fillers = [
  'ayuda por favor',
  'urgente',
  'por favor vengan',
  'necesitamos ayuda',
];
const List<String> _emoji = ['🆘', '🙏', '⚠️'];

class _Gen {
  _Gen(int seed) : rnd = Random(seed);
  final Random rnd;
  int _key = 0;

  bool chance(double p) => rnd.nextDouble() < p;
  T pick<T>(List<T> l) => l[rnd.nextInt(l.length)];
  double gauss() {
    final u1 = 1 - rnd.nextDouble(), u2 = rnd.nextDouble();
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
  }

  String deviceId() =>
      List.generate(8, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  String reportKey(String dev) => '$dev-${++_key}';
}

({double lat, double lon}) _offset(double lat, double lon, double northM, double eastM) =>
    (lat: lat + northM / 111320.0, lon: lon + eastM / (111320.0 * cos(lat * pi / 180)));

/// Qué calidad de ubicación (y su error real) tiene un reporte.
(LocQuality, double) _quality(_Gen g) {
  final x = g.rnd.nextDouble();
  if (x < 0.12) return (LocQuality.none, 0);
  if (x < 0.32) return (LocQuality.within10m, 5);
  if (x < 0.72) return (LocQuality.within50m, 25);
  if (x < 0.92) return (LocQuality.within200m, 100);
  if (x < 0.97) return (LocQuality.within1km, 500);
  return (LocQuality.over1km, 1500);
}

String _misspell(_Gen g, String s) {
  var out = s;
  switch (g.rnd.nextInt(3)) {
    case 0:
      out = out
          .replaceAll('á', 'a')
          .replaceAll('é', 'e')
          .replaceAll('í', 'i')
          .replaceAll('ó', 'o')
          .replaceAll('ú', 'u');
    case 1:
      if (out.length > 4) {
        final i = 1 + g.rnd.nextInt(out.length - 2);
        out = out.substring(0, i) + out.substring(i + 1);
      }
    default:
      if (out.length > 4) {
        final i = 1 + g.rnd.nextInt(out.length - 3);
        out = out.substring(0, i) + out[i + 1] + out[i] + out.substring(i + 2);
      }
  }
  return out;
}

class _TextOut {
  _TextOut(this.text, this.paraphrased, this.misspelled);
  final String text;
  final bool paraphrased;
  final bool misspelled;
}

/// Frases para los rasgos [features] (bits), con probabilidad [pParaphrase] de usar la paráfrasis.
_TextOut _compose(
  _Gen g,
  List<int> features, {
  required double pParaphrase,
  required String street,
  bool negations = false,
}) {
  final parts = <String>[];
  var para = false;
  for (final f in features) {
    final usePara = g.chance(pParaphrase) && _paraphrase[f] != null;
    if (usePara) para = true;
    final bank = usePara ? _paraphrase[f]! : (_lexical[f] ?? _paraphrase[f]!);
    parts.add(g.pick(bank));
  }
  if (negations) parts.add(g.pick(_negations));
  if (g.chance(0.7)) parts.add(street);
  if (g.chance(0.4)) parts.add(g.pick(_fillers));
  var text = parts.join(', ');
  var miss = false;
  if (g.chance(0.15)) {
    text = _misspell(g, text);
    miss = true;
  }
  if (g.chance(0.1)) text = '${g.pick(_emoji)} $text';
  return _TextOut(truncateUtf8(text, kMaxTextBytes), para, miss);
}

List<int> _bitsOf(int flags) => [
  for (final b in [_a, _h, _f, _r, _v, _e, _m, _med])
    if (flags & b != 0) b,
];

String _street(_Gen g) => 'carrera ${10 + g.rnd.nextInt(40)} con calle ${10 + g.rnd.nextInt(60)}';

SynthIncident _newIncident(
  _Gen g,
  int id, {
  SynthIncident? twinOf,
  required double baseLat,
  required double baseLon,
  required int baseStartMs,
}) {
  if (twinOf != null) {
    final dist = 60 + g.rnd.nextDouble() * 190;
    final bearing = g.rnd.nextDouble() * 2 * pi;
    final c = _offset(twinOf.lat, twinOf.lon, dist * cos(bearing), dist * sin(bearing));
    final latent = _latentFor(g, g.pick([Urgency.p1, Urgency.p2, Urgency.p3, Urgency.p4]));
    return SynthIncident(
      id: id,
      lat: c.lat,
      lon: c.lon,
      startMs: twinOf.startMs + (g.rnd.nextInt(16) - 8) * 60000,
      type: twinOf.type,
      urgency: _truth(latent),
      latentFlags: latent,
      twinOf: twinOf.id,
    );
  }
  final c = _offset(
    baseLat,
    baseLon,
    (g.rnd.nextDouble() - 0.5) * 20000,
    (g.rnd.nextDouble() - 0.5) * 20000,
  );
  final u = g.rnd.nextDouble();
  final target = u < 0.25
      ? Urgency.p1
      : u < 0.55
      ? Urgency.p2
      : u < 0.80
      ? Urgency.p3
      : Urgency.p4;
  final latent = _latentFor(g, target);
  return SynthIncident(
    id: id,
    lat: c.lat,
    lon: c.lon,
    startMs: baseStartMs + g.rnd.nextInt(6 * 3600 * 1000),
    type: g.chance(0.5) ? 1 : 2 + g.rnd.nextInt(4),
    urgency: _truth(latent),
    latentFlags: latent,
  );
}

/// Estado latente de un suceso para una urgencia objetivo. Los P1 siempre tienen ≥ 2 rasgos.
int _latentFor(_Gen g, Urgency target) => switch (target) {
  Urgency.p1 => g.pick([_a | _h, _a | _f, _r | _h, _r | _a, _a | _h | _r]),
  Urgency.p2 => g.pick([_a, _f, _h, _e]),
  Urgency.p3 => g.pick([_v, _m, _v | _m, _med]),
  Urgency.p4 => 0,
};

SynthReport _report(
  _Gen g,
  SynthIncident inc, {
  required String street,
  required String deviceId,
  bool repeated = false,
  bool twin = false,
}) {
  final tags = <String>{if (twin) 'gemelo', if (repeated) 'repetido'};
  // --- ubicación ---
  final (q, err) = _quality(g);
  double? lat, lon;
  if (q != LocQuality.none) {
    final p = _offset(inc.lat, inc.lon, g.gauss() * err, g.gauss() * err);
    lat = p.lat;
    lon = p.lon;
    if (q.index >= LocQuality.within1km.index) tags.add('ubicacion_imprecisa');
  } else {
    tags.add('sin_ubicacion');
  }
  // --- hora (3 % con el reloj del teléfono desfasado de 1 a 3 h) ---
  int at = inc.startMs + min(180 * 60000, (-log(1 - g.rnd.nextDouble()) * 8 * 60000).round());
  if (g.chance(0.03)) {
    at += (g.chance(0.5) ? 1 : -1) * (3600000 + g.rnd.nextInt(2 * 3600000));
    tags.add('reloj_desfasado');
  }
  // --- banderas y texto según el subgrupo ---
  final latent = inc.latentFlags;
  final bits = _bitsOf(latent);
  var flags = 0;
  String? text;
  var subgroup = 'no_p1';
  var para = false, miss = false;

  _TextOut mk(List<int> f, double pp, {bool neg = false}) =>
      _compose(g, f, pParaphrase: pp, street: street, negations: neg);

  if (inc.urgency == Urgency.p1 && !twin) {
    final x = g.rnd.nextDouble();
    if (x < 0.55) {
      subgroup = 'banderas_coherentes';
      flags = latent;
      if (g.chance(0.5)) {
        final t = mk(bits, 0.3);
        text = t.text;
        para = t.paraphrased;
        miss = t.misspelled;
      }
    } else if (x < 0.75) {
      subgroup = 'parcial_con_texto';
      final marked = g.pick(bits);
      flags = marked;
      final rest = bits.where((b) => b != marked).toList();
      final t = mk(rest.isEmpty ? bits : rest, 0.4);
      text = t.text;
      para = t.paraphrased;
      miss = t.misspelled;
    } else if (x < 0.85) {
      subgroup = 'sin_banderas_con_texto';
      final t = mk(bits, 0.5);
      text = t.text;
      para = t.paraphrased;
      miss = t.misspelled;
    } else if (x < 0.95) {
      subgroup = 'sin_pistas';
    } else {
      subgroup = 'banderas_equivocadas';
      flags = g.pick([_v, _m]);
    }
  } else {
    // Sucesos no P1 (y gemelos): se marca lo verdadero con alta probabilidad y de vez en cuando algo de más.
    for (final b in bits) {
      if (g.chance(0.8)) flags |= b;
    }
    if (g.chance(0.02)) flags |= g.pick([_v, _m]);
    if (g.chance(0.5) || twin) {
      final negs = inc.urgency.index >= Urgency.p3.index && g.chance(0.25);
      final t = mk(bits, 0.35, neg: negs);
      text = t.text;
      para = t.paraphrased;
      miss = t.misspelled;
    }
  }
  tags.add(text == null ? 'sin_texto' : 'con_texto');
  if (para) tags.add('parafraseado');
  if (miss) tags.add('con_faltas');

  return SynthReport(
    reportKey: g.reportKey(deviceId),
    deviceId: deviceId,
    incidentType: g.chance(0.9) ? 1 : inc.type,
    flags: flags,
    lat: lat,
    lon: lon,
    locQuality: q,
    capturedAtMs: at,
    text: text,
    sourceClass: 'app',
    trueIncident: inc.id,
    trueUrgency: inc.urgency,
    subgroup: subgroup,
    tags: tags,
  );
}

/// 1 000 reportes en 80 sucesos base, más 20 sucesos gemelos adversariales de 5 reportes (otro
/// suceso, a 60–250 m y casi a la misma hora, con la misma calle y el mismo tipo).
SynthDataset generateDataset(SynthConfig c) {
  final g = _Gen(c.seed);
  const baseLat = 5.07, baseLon = -75.52; // Manizales
  final baseStart = DateTime.utc(2026, 8, 10, 14).millisecondsSinceEpoch;
  final incidents = <int, SynthIncident>{};
  final streets = <int, String>{};
  for (var i = 0; i < c.incidents; i++) {
    incidents[i] = _newIncident(g, i, baseLat: baseLat, baseLon: baseLon, baseStartMs: baseStart);
    streets[i] = _street(g);
  }
  // Reparto de reportes: 2 como mínimo por suceso; el resto al azar con pesos distintos.
  final counts = List<int>.filled(c.incidents, 2);
  final w = List<double>.generate(c.incidents, (_) => 0.4 + g.rnd.nextDouble());
  final tw = w.reduce((a, b) => a + b);
  for (var k = 0; k < c.reports - 2 * c.incidents; k++) {
    var x = g.rnd.nextDouble() * tw, i = 0;
    while (i < c.incidents - 1 && x > w[i]) {
      x -= w[i];
      i++;
    }
    counts[i]++;
  }
  final reports = <SynthReport>[];
  for (var i = 0; i < c.incidents; i++) {
    final devices = <String>[];
    for (var k = 0; k < counts[i]; k++) {
      final repeat = devices.length >= 2 && g.chance(0.08);
      final dev = repeat ? g.pick(devices) : g.deviceId();
      if (!repeat) devices.add(dev);
      reports.add(_report(g, incidents[i]!, street: streets[i]!, deviceId: dev, repeated: repeat));
    }
  }
  // Gemelos adversariales: sucesos distintos, parecidos a uno base.
  final bases = List<int>.generate(c.incidents, (i) => i)..shuffle(g.rnd);
  for (var k = 0; k < c.adversarialPairs; k++) {
    final base = incidents[bases[k]]!;
    final id = c.incidents + k;
    final twin = _newIncident(
      g,
      id,
      twinOf: base,
      baseLat: baseLat,
      baseLon: baseLon,
      baseStartMs: baseStart,
    );
    incidents[id] = twin;
    for (var j = 0; j < c.twinReports; j++) {
      reports.add(_report(g, twin, street: streets[base.id]!, deviceId: g.deviceId(), twin: true));
    }
  }
  reports.sort((a, b) => a.capturedAtMs.compareTo(b.capturedAtMs));
  return SynthDataset(reports, incidents);
}

/// Un rumor repetido: [copies] reportes casi idénticos que vienen de sólo [sources] fuentes.
List<SynthReport> generateRumor({required int copies, required int sources, required int seed}) {
  final g = _Gen(seed);
  final devs = List.generate(sources, (_) => g.deviceId());
  const variants = [
    'dicen por la radio que el puente de la calle 20 colapsó, que nadie pase',
    'dicen por la radio que el puente de la calle 20 se colapsó, que nadie pase',
    'dicen por la radio que el puente de la calle 20 colapso, que nadie pase',
  ];
  final start = DateTime.utc(2026, 8, 10, 14).millisecondsSinceEpoch;
  return [
    for (var i = 0; i < copies; i++)
      SynthReport(
        reportKey: g.reportKey(devs[i % sources]),
        deviceId: devs[i % sources],
        incidentType: 2,
        flags: 0,
        lat: null,
        lon: null,
        locQuality: LocQuality.none,
        capturedAtMs: start + i * 7000,
        text: variants[i % variants.length],
        sourceClass: 'radio',
        trueIncident: -1,
        trueUrgency: Urgency.p4,
        subgroup: 'no_p1',
        tags: {'con_texto', 'sin_ubicacion'},
      ),
  ];
}

/// [sources] personas distintas, cada una con sus palabras y su ubicación, que cuentan lo mismo.
List<SynthReport> generateCorroboration({required int sources, required int seed}) {
  final g = _Gen(seed);
  const texts = [
    'el puente de la calle 20 se partió por la mitad',
    'vi caer la mitad del puente, hay carros abajo',
    'puente colapsado en la 20, gente atrapada en un bus',
    'se cayó el puente, ayuden a los del bus',
    'colapso del puente frente a la gasolinera, hay heridos',
    'el puente cedió y quedó un hueco enorme',
  ];
  final start = DateTime.utc(2026, 8, 10, 14).millisecondsSinceEpoch;
  final inc = SynthIncident(
    id: 0,
    lat: 5.0689,
    lon: -75.5174,
    startMs: start,
    type: 2,
    urgency: Urgency.p1,
    latentFlags: _a | _h,
  );
  return [
    for (var i = 0; i < sources; i++)
      () {
        final dev = g.deviceId();
        final p = _offset(inc.lat, inc.lon, g.gauss() * 15, g.gauss() * 15);
        return SynthReport(
          reportKey: g.reportKey(dev),
          deviceId: dev,
          incidentType: 2,
          flags: _a | _h,
          lat: p.lat,
          lon: p.lon,
          locQuality: LocQuality.within50m,
          capturedAtMs: start + (1 + i * 2) * 60000,
          text: texts[i % texts.length],
          sourceClass: 'app',
          trueIncident: 0,
          trueUrgency: Urgency.p1,
          subgroup: 'banderas_coherentes',
          tags: {'con_texto'},
        );
      }(),
  ];
}
