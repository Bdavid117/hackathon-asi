import 'dart:async';

import 'package:flutter/material.dart';

import 'access_prompt.dart';
import 'api.dart';
import 'brand.dart';
import 'detail_panel.dart';
import 'incident_card.dart';
import 'models.dart';
import 'theme.dart';

enum _Mode { short, all, bare }

/// El tablero del coordinador: **el incidente es la unidad**, no el mensaje.
///
/// Muestra la vista corta por omisión (todos los P1/P2, los P3/P4 recientes y una fila agregada de
/// «SOS sin detalle») con contadores sobre el total real, el estado de los nodos («vista parcial» si
/// puede faltar información), y el detalle del incidente elegido. Cuando algo falla lo dice —sin
/// conexión, vista vieja, respuesta inválida— y conserva la última vista en vez de borrarla.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.api, this.every = const Duration(seconds: 2), this.clock, this.pageSize = 200});

  final DashboardApi api;

  /// Periodo de consulta; `null` la desactiva (pruebas).
  final Duration? every;
  final DateTime Function()? clock;

  /// Cuántas filas se piden por página en la vista completa.
  final int pageSize;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  IncidentsPage? _page;
  final List<IncidentRow> _items = [];
  NodesStatus? _nodes;
  bool _nodesUnknown = false;
  _Mode _mode = _Mode.short;
  String? _urgency;
  bool _offline = false;
  bool _invalid = false;
  String? _failure;
  String? _selected;
  bool _loading = false;

  /// El nodo exige código y no se tiene (o ya no vale): sólo se ve la pantalla de acceso, sin datos.
  bool _locked = false;
  bool _triedCode = false;
  bool _hadAccess = false;
  Timer? _timer;
  final ValueNotifier<String> _who = ValueNotifier<String>('');

  DateTime get _now => (widget.clock ?? DateTime.now)();
  static const double _wide = 900;

  @override
  void initState() {
    super.initState();
    _load();
    final every = widget.every;
    if (every != null) _timer = Timer.periodic(every, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _who.dispose();
    super.dispose();
  }

  Future<IncidentsPage> _fetch({required int offset, required int limit}) => switch (_mode) {
    _Mode.short => widget.api.incidents(),
    _Mode.all => widget.api.incidents(view: 'all', urgency: _urgency, offset: offset, limit: limit),
    _Mode.bare => widget.api.incidents(view: 'all', bare: true, offset: offset, limit: limit),
  };

  /// Lee la vista actual (y el estado de los nodos). En las vistas por páginas se vuelve a leer lo ya
  /// cargado (hasta 1 000 filas) para que no se quede viejo.
  Future<void> _load() async {
    if (_loading || _locked) return;
    _loading = true;
    final mode = _mode, urgency = _urgency;
    unawaited(
      widget.api.nodes().then((n) {
        if (mounted) {
          setState(() {
            _nodes = n;
            _nodesUnknown = false;
          });
        }
      }).catchError((Object e) {
        if (e is AccessDenied) {
          _lock();
        } else if (mounted) {
          setState(() => _nodesUnknown = true);
        }
      }),
    );
    try {
      final loaded = _items.length;
      final limit = mode == _Mode.short ? widget.pageSize : (loaded < widget.pageSize ? widget.pageSize : (loaded > 1000 ? 1000 : loaded));
      final page = await _fetch(offset: 0, limit: limit);
      if (!mounted || mode != _mode || urgency != _urgency) return;
      setState(() {
        _page = page;
        final keep = _items.length > page.items.length && mode != _Mode.short ? _items.sublist(page.items.length) : const <IncidentRow>[];
        _items
          ..clear()
          ..addAll(page.items)
          ..addAll(keep);
        _offline = false;
        _invalid = false;
        _failure = null;
        _hadAccess = true;
        _triedCode = false;
      });
    } on AccessDenied {
      _lock();
    } on FormatException {
      if (mounted) setState(() => _invalid = true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _offline = true;
          _failure = 'el nodo respondió con un error (HTTP ${e.status})';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _offline = true;
          _failure = null;
        });
      }
    } finally {
      _loading = false;
    }
  }

  /// Se pierde el acceso: se olvida lo leído (no se deja en memoria lo de alguien sin código) y se pide de nuevo.
  void _lock() {
    if (!mounted || _locked) return;
    setState(() {
      _locked = true;
      _page = null;
      _items.clear();
      _nodes = null;
      _selected = null;
      _offline = false;
    });
  }

  void _submitCode(String code) {
    widget.api.accessCode = code;
    _triedCode = true;
    setState(() => _locked = false);
    _load();
  }

  String? get _lockMessage => _triedCode ? 'Ese código no es correcto. Revísalo e inténtalo de nuevo.' : (_hadAccess ? 'El nodo ya no acepta el código que tenías. Escríbelo de nuevo.' : null);

  Future<void> _loadMore() async {
    final page = _page;
    if (page == null) return;
    try {
      final next = await _fetch(offset: _items.length, limit: widget.pageSize);
      if (!mounted) return;
      setState(() {
        final seen = {for (final i in _items) i.id};
        _items.addAll(next.items.where((i) => !seen.contains(i.id)));
        _page = IncidentsPage(view: next.view, counters: next.counters, total: next.total, offset: 0, limit: page.limit, bare: null, items: _items, stale: next.stale, ageMs: next.ageMs);
      });
    } on Object {
      if (mounted) setState(() => _offline = true);
    }
  }

  void _switch(_Mode mode, {String? urgency}) {
    setState(() {
      _mode = mode;
      _urgency = urgency;
      _items.clear();
      _page = _page == null ? null : IncidentsPage(view: _page!.view, counters: _page!.counters, total: 0, offset: 0, limit: widget.pageSize, bare: null, items: const []);
    });
    _loading = false;
    _load();
  }

  void _select(String id) {
    final wide = MediaQuery.sizeOf(context).width >= _wide;
    if (wide) {
      setState(() => _selected = id);
      return;
    }
    setState(() => _selected = id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Theme(
          data: dashTheme(),
          child: Scaffold(
            appBar: AppBar(title: const Text('Incidente')),
            body: IncidentDetailView(
              api: widget.api,
              id: id,
              who: _who,
              every: widget.every,
              clock: widget.clock,
              onGone: () {
                if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                _load();
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return Theme(
        data: dashTheme(),
        child: Scaffold(appBar: AppBar(title: _title), body: AccessPrompt(onSubmit: _submitCode, message: _lockMessage)),
      );
    }
    final page = _page;
    final wide = MediaQuery.sizeOf(context).width >= _wide;
    final list = _buildList(context, page);
    return Theme(
      data: dashTheme(),
      child: Scaffold(
        appBar: AppBar(
          title: _title,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: _Freshness(page: page, offline: _offline)),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_offline)
              _Banner(key: const Key('offline_banner'), color: DashColors.warn, bg: DashColors.warnBg, icon: Icons.cloud_off, text: 'Sin conexión con el nodo${_failure == null ? '' : ' ($_failure)'}: se muestra la última vista${page == null ? ' (todavía no hay ninguna)' : ''}.'),
            if (_invalid)
              const _Banner(key: Key('invalid_banner'), color: DashColors.danger, bg: DashColors.dangerBg, icon: Icons.error_outline, text: 'El nodo mandó una respuesta que el tablero no puede interpretar. Se conserva la última vista válida: no te fíes de ella hasta que se resuelva.'),
            if (page != null && page.stale)
              _Banner(key: const Key('stale_banner'), color: DashColors.warn, bg: DashColors.warnBg, icon: Icons.history_toggle_off, text: 'Vista de hace ${(page.ageMs / 1000).round()} s: el nodo está recalculando y puede faltar algún reporte reciente.'),
            _NodesBar(nodes: _nodes, unknown: _nodesUnknown, now: _now),
            if (page != null) _CountersBar(counters: page.counters, urgency: _mode == _Mode.all ? _urgency : null, bareActive: _mode == _Mode.bare, onUrgency: (u) => _switch(_Mode.all, urgency: u), onBare: () => _switch(_Mode.bare)),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: list),
                        const VerticalDivider(width: 1),
                        Expanded(
                          flex: 6,
                          child: _selected == null
                              ? const Center(key: Key('detail_empty'), child: Text('Elige un incidente para ver por qué tiene esa prioridad y qué se recomienda.', textAlign: TextAlign.center, style: TextStyle(color: DashColors.muted)))
                              : IncidentDetailView(
                                  key: ValueKey(_selected),
                                  api: widget.api,
                                  id: _selected!,
                                  who: _who,
                                  every: widget.every,
                                  clock: widget.clock,
                                  onGone: () => WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (mounted) _load();
                                  }),
                                ),
                        ),
                      ],
                    )
                  : list,
            ),
          ],
        ),
      ),
    );
  }

  static const Widget _title = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SardMark(key: Key('brand_mark'), size: 30),
      SizedBox(width: 10),
      Flexible(child: Text('SARD · Tablero del coordinador', overflow: TextOverflow.ellipsis)),
    ],
  );

  Widget _buildList(BuildContext context, IncidentsPage? page) {
    if (page == null) {
      return Center(
        key: const Key('no_data'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_offline || _invalid ? 'Todavía no se ha podido leer ningún incidente del nodo.' : 'Cargando incidentes…', textAlign: TextAlign.center, style: const TextStyle(color: DashColors.muted, fontSize: 15)),
        ),
      );
    }
    final now = _now;
    final children = <Widget>[];
    // La cabecera es fija (no se pierde al final de una lista larga): dice qué se está viendo y cómo ver el resto.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: _mode == _Mode.short
          ? Row(
              children: [
                Expanded(child: Text('Vista corta · ${page.total} de ${page.counters.incidents} incidentes', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
                const SizedBox(width: 8),
                OutlinedButton(key: const Key('show_all'), onPressed: () => _switch(_Mode.all), child: Text('Ver todo (${page.counters.incidents})')),
              ],
            )
          : Row(
              children: [
                OutlinedButton.icon(key: const Key('back_to_short'), onPressed: () => _switch(_Mode.short), icon: const Icon(Icons.arrow_back, size: 16), label: const Text('Volver a la vista corta')),
                const SizedBox(width: 12),
                Expanded(child: Text(_mode == _Mode.bare ? 'Sólo SOS sin detalle (${page.total})' : (_urgency == null ? 'Todos los incidentes (${page.total})' : 'Incidentes ${_urgency!} (${page.total})'), style: const TextStyle(fontWeight: FontWeight.w700))),
              ],
            ),
    );
    final bare = _mode == _Mode.short ? page.bare : null;
    var bareInserted = bare == null;
    for (final row in _items) {
      if (!bareInserted && (row.urgency == 'P3' || row.urgency == 'P4')) {
        children.add(_BareRow(bare: bare!, now: now, onShow: () => _switch(_Mode.bare)));
        bareInserted = true;
      }
      children.add(IncidentCard(row: row, now: now, selected: row.id == _selected, onTap: () => _select(row.id)));
    }
    if (!bareInserted) children.add(_BareRow(bare: bare!, now: now, onShow: () => _switch(_Mode.bare)));
    if (_items.isEmpty && bare == null && !_loading) {
      children.add(const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Sin reportes todavía', style: TextStyle(color: DashColors.muted, fontSize: 16)))));
    }
    if (_mode != _Mode.short && _items.length < page.total) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          child: Align(alignment: Alignment.centerLeft, child: OutlinedButton(key: const Key('load_more'), onPressed: _loadMore, child: Text('Cargar más (${page.total - _items.length} restantes)'))),
        ),
      );
    }
    return Column(children: [header, Expanded(child: ListView(key: const Key('incident_list'), children: children))]);
  }
}

// ───────────────────────────── piezas ─────────────────────────────

class _Freshness extends StatelessWidget {
  const _Freshness({required this.page, required this.offline});
  final IncidentsPage? page;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final p = page;
    final (text, color) = offline ? ('Sin conexión', DashColors.warn) : (p == null ? ('Cargando…', DashColors.muted) : (p.stale ? ('Vista de hace ${(p.ageMs / 1000).round()} s', DashColors.warn) : ('En vivo', DashColors.ok)));
    return Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.circle, size: 10, color: color), const SizedBox(width: 6), Text(text, key: const Key('freshness'), style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w700))]);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.color, required this.bg, required this.icon, required this.text});
  final Color color;
  final Color bg;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: bg,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    child: Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: 10), Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.25)))]),
  );
}

class _NodesBar extends StatelessWidget {
  const _NodesBar({required this.nodes, required this.unknown, required this.now});
  final NodesStatus? nodes;
  final bool unknown;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final n = nodes;
    if (n == null) {
      return unknown
          ? const _Banner(key: Key('nodes_unknown'), color: DashColors.warn, bg: DashColors.warnBg, icon: Icons.device_hub, text: 'No se pudo leer el estado de los nodos: no se puede afirmar que la vista esté completa.')
          : const SizedBox.shrink();
    }
    Color stateColor(String s) => switch (s) {
      'sincronizado' => DashColors.ok,
      'atrasado' => DashColors.warn,
      _ => DashColors.danger,
    };
    String ago(int? ms) => ms == null ? '' : ' · hace ${ms < 1000 ? 'menos de 1' : (ms / 1000).round()} s';
    return Column(
      key: const Key('nodes_bar'),
      children: [
        if (n.partialView)
          Container(
            key: const Key('partial_view'),
            width: double.infinity,
            color: DashColors.warnBg,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.visibility_off_outlined, size: 18, color: DashColors.warn),
                const SizedBox(width: 10),
                Expanded(child: Text.rich(TextSpan(children: [const TextSpan(text: 'Vista parcial. ', style: TextStyle(fontWeight: FontWeight.w800)), TextSpan(text: n.reasons.map(partialReasonLabel).join(' '))]), style: const TextStyle(fontSize: 14, height: 1.25))),
              ],
            ),
          ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Nodo ${n.selfId} (este) · ${n.events} eventos', style: const TextStyle(fontSize: 13, color: DashColors.muted)),
              for (var i = 0; i < n.peers.length; i++)
                Row(
                  key: Key('peer_$i'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 9, color: stateColor(n.peers[i].state)),
                    const SizedBox(width: 5),
                    Text('${Uri.tryParse(n.peers[i].url)?.host ?? n.peers[i].url}: ${peerStateLabel(n.peers[i].state)}${ago(n.peers[i].lastSeenAgoMs)}', style: const TextStyle(fontSize: 13)),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// La barra de triaje: un segmento por urgencia, ancho según cuántos incidentes hay (con un mínimo para
/// que se lea y se pueda tocar), y los demás contadores. Tocar una urgencia filtra por ella.
class _CountersBar extends StatelessWidget {
  const _CountersBar({required this.counters, required this.urgency, required this.bareActive, required this.onUrgency, required this.onBare});
  final Counters counters;
  final String? urgency;
  final bool bareActive;
  final void Function(String urgency) onUrgency;
  final VoidCallback onBare;

  @override
  Widget build(BuildContext context) {
    final by = counters.byUrgency;
    final total = by.values.fold<int>(0, (a, b) => a + b);
    return Container(
      key: const Key('counters'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 64,
            child: LayoutBuilder(
              builder: (context, c) {
                // Ancho de cada segmento: un mínimo fijo que siempre cabe el número y la etiqueta, y el
                // resto repartido según cuántos incidentes hay. Si no cabe ni el mínimo, se reparte igual.
                const gap = 4.0, minW = 92.0;
                final usable = c.maxWidth - gap * (kUrgencies.length - 1);
                final widths = usable < minW * kUrgencies.length
                    ? List<double>.filled(kUrgencies.length, usable / kUrgencies.length)
                    : [for (final u in kUrgencies) minW + (usable - minW * kUrgencies.length) * (total == 0 ? 1 / kUrgencies.length : by[u]! / total)];
                return Row(
                  children: [
                    for (var i = 0; i < kUrgencies.length; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
                      SizedBox(width: widths[i], child: _TriageSegment(u: kUrgencies[i], count: by[kUrgencies[i]]!, selected: urgency == kUrgencies[i], onTap: () => onUrgency(kUrgencies[i]))),
                    ],
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              _Stat(const Key('counter_highUncertainty'), 'Incertidumbre alta', counters.highUncertainty, DashColors.warn),
              _Stat(const Key('counter_needsReview'), 'A revisar', counters.needsReview, DashColors.warn),
              _Stat(const Key('counter_bareSos'), 'SOS sin detalle', counters.bareSos, DashColors.muted, onTap: counters.bareSos > 0 ? onBare : null, active: bareActive),
              _Stat(const Key('counter_followUp'), 'En seguimiento fuera de la vista', counters.followUp, DashColors.muted),
            ],
          ),
        ],
      ),
    );
  }
}

class _TriageSegment extends StatelessWidget {
  const _TriageSegment({required this.u, required this.count, required this.selected, required this.onTap});
  final String u;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: DashColors.urgency(u),
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      key: Key('counter_$u'),
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        decoration: selected ? BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white, width: 3)) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$count', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: DashColors.onUrgency(u), fontFeatures: kTabular)),
              const SizedBox(width: 8),
              Text(u, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashColors.onUrgency(u))),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.statKey, this.label, this.value, this.color, {this.onTap, this.active = false});
  final Key statKey;
  final String label;
  final int value;
  final Color color;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => InkWell(
    key: statKey,
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(border: Border.all(color: active ? DashColors.text : DashColors.border), borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$value', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: color, fontFeatures: kTabular)),
          const SizedBox(width: 6),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: DashColors.muted))),
        ],
      ),
    ),
  );
}

class _BareRow extends StatelessWidget {
  const _BareRow({required this.bare, required this.now, required this.onShow});
  final BareAggregate bare;
  final DateTime now;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Container(
      key: const Key('bare_row'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: DashColors.border)),
      child: Row(
        children: [
          const UrgencyBadge('P3'),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${bare.count} SOS sin detalle', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text('Alguien tocó SOS y no dijo más. El más antiguo, ${ageLabel(bare.oldestAt, now)}; el más reciente, ${ageLabel(bare.newestAt, now)}.', style: const TextStyle(fontSize: 13, color: DashColors.muted, height: 1.25)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(key: const Key('show_bare'), onPressed: onShow, child: const Text('Ver')),
        ],
      ),
    ),
  );
}
