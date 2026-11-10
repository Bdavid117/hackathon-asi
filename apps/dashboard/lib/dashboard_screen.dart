import 'dart:async';

import 'package:flutter/material.dart';

import 'access_prompt.dart';
import 'api.dart';
import 'arrivals.dart';
import 'dispatch_dialog.dart';
import 'brand.dart';
import 'detail_panel.dart';
import 'incident_card.dart';
import 'incident_filter.dart';
import 'incident_map.dart';
import 'models.dart';
import 'resources_dialog.dart';
import 'theme.dart';

enum _Mode { short, all, bare, pending }

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

  /// Se ve el mapa en vez de la lista (la lista es lo que se ve por omisión).
  bool _showMap = false;

  /// Quién dice el nodo que soy (por mi código de acceso), o `null` si no identifica a nadie. Se pregunta UNA vez por sesión de acceso
  /// (y de nuevo tras volver a entrar con otro código): nunca se conserva el de un código anterior.
  String? _identity;
  bool _identityChecked = false;

  /// Los recursos (unidades) que usa el nodo, para el botón «Recursos» y para el mapa. Si el nodo no los sirve, se sigue sin ellos.
  List<ResourceUnit> _resources = const [];

  /// La capa de silencio del mapa (zonas que reportaron y callaron; el silencio NO es seguridad). Por omisión apagada, y apagada no cuesta
  /// red: sólo se lee con la capa encendida Y el mapa a la vista. Al apagarla se olvida la lectura, para no enseñar una vieja al encenderla.
  bool _silenceOn = false;
  CoverageInfo? _coverage;
  _CoverageState _coverageState = _CoverageState.idle;
  bool _coverageLoading = false;

  /// Filtros y búsqueda sobre lo CARGADO (el nodo es quien cuenta el total), y si su panel está abierto.
  IncidentFilter _filter = const IncidentFilter();
  bool _filterOpen = false;

  /// Novedades: lo que el nodo recibió después de la última vez que se vio.
  final Arrivals _arrivals = Arrivals();

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
    _Mode.pending => widget.api.incidents(view: 'all', pending: true, offset: offset, limit: limit),
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
    unawaited(_loadResources());
    unawaited(_loadCoverage());
    if (!_identityChecked) unawaited(_loadIdentity());
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
        _arrivals.observe(_items); // la primera lectura fija la marca y no avisa de nada
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

  /// Lee los recursos aparte de los incidentes: un nodo que no los sirve (anterior) o un fallo suelto no tumban el tablero.
  Future<void> _loadResources() async {
    try {
      final r = await widget.api.resources();
      if (mounted) setState(() => _resources = r);
    } on AccessDenied {
      _lock();
    } on Object {
      // se conserva lo último que se leyó
    }
  }

  /// Lee las zonas en silencio SÓLO si la capa está encendida y el mapa a la vista. Un nodo anterior (404) o un fallo no tumban el tablero:
  /// se dice en el rótulo de la capa. Un 401 bloquea como cualquier otra lectura.
  Future<void> _loadCoverage() async {
    if (!_silenceOn || !_showMap || _coverageLoading || _locked) return;
    _coverageLoading = true;
    try {
      final c = await widget.api.coverage();
      if (!mounted || !_silenceOn) return; // se apagó mientras llegaba: se tira
      setState(() {
        _coverage = c;
        _coverageState = c == null ? _CoverageState.unsupported : _CoverageState.ok;
      });
    } on AccessDenied {
      _lock();
    } on Object {
      if (mounted && _silenceOn) setState(() => _coverageState = _CoverageState.failed);
    } finally {
      _coverageLoading = false;
    }
  }

  void _toggleSilence() {
    setState(() {
      _silenceOn = !_silenceOn;
      if (!_silenceOn) {
        _coverage = null;
        _coverageState = _CoverageState.idle;
      }
    });
    if (_silenceOn) unawaited(_loadCoverage());
  }

  /// Por qué la capa no tiene (o no tiene al día) su lectura. Sin lectura NO se afirma ningún recuento.
  String? get _silenceNote => switch ((_coverage, _coverageState)) {
    (null, _CoverageState.unsupported) => 'Este nodo no calcula las zonas en silencio.',
    (null, _CoverageState.failed) => 'No se pudo leer el silencio; se vuelve a intentar.',
    (null, _) => 'Leyendo el silencio…',
    (_, _CoverageState.failed) => 'No se pudo actualizar; se muestra la última lectura.',
    _ => null,
  };

  /// Pregunta quién soy. Un fallo no bloquea nada ni se inventa un nombre: queda sin identidad (nombre libre) y se vuelve a preguntar.
  Future<void> _loadIdentity() async {
    _identityChecked = true; // una sola pregunta en vuelo
    try {
      final who = await widget.api.whoami();
      if (!mounted || _locked) return;
      setState(() {
        _identity = who;
        if (who != null) _who.value = who;
      });
    } on AccessDenied {
      _identityChecked = false;
      _lock();
    } on Object {
      _identityChecked = false;
    }
  }

  Future<void> _openResources() async {
    await showDialog<void>(
      context: context,
      builder: (_) => Theme(
        data: dashTheme(),
        child: ResourcesDialog(api: widget.api, who: _who, identity: _identity, units: _resources, onChanged: (u) => setState(() => _resources = u)),
      ),
    );
  }

  /// Se pierde el acceso: se olvida lo leído (no se deja en memoria lo de alguien sin código) y se pide de nuevo.
  void _lock() {
    if (!mounted || _locked) return;
    setState(() {
      _locked = true;
      _page = null;
      _items.clear();
      _nodes = null;
      _resources = const [];
      _coverage = null;
      _coverageState = _CoverageState.idle;
      // El nombre que venía del código anterior NO se queda escrito para firmar con el siguiente.
      if (_identity != null) _who.value = '';
      _identity = null;
      _identityChecked = false;
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
      _arrivals.reset(); // otra vista: lo que traiga la primera lectura no es una «novedad»
      _page = _page == null ? null : IncidentsPage(view: _page!.view, counters: _page!.counters, total: 0, offset: 0, limit: widget.pageSize, bare: null, items: const []);
    });
    _loading = false;
    _load();
  }

  /// Tocar el aviso de novedades: se dan por vistas y se abre la más urgente.
  void _openNews() {
    final news = _arrivals.news(_items);
    if (news.isEmpty) return;
    final id = news.first.id;
    setState(() => _arrivals.acknowledge(_items));
    _select(id);
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
              identity: _identity,
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
    // Con poco ancho la barra no tiene sitio para el selector (ya hay que recortar el título): va encima del contenido.
    final narrowBar = MediaQuery.sizeOf(context).width < 700;
    final toggle = _ViewToggle(
      map: _showMap,
      onChanged: (m) {
        setState(() => _showMap = m);
        if (m) unawaited(_loadCoverage()); // al volver al mapa con la capa encendida, una lectura fresca (no la de antes de irse)
      },
    );
    // El aviso de novedades SÓLO avisa: no reordena nada ni cambia de altura nada. Por eso no va en la cabecera de la lista
    // (competiría por el ancho de su texto y todo se reajustaría): va en la barra superior, o junto al selector en pantallas
    // estrechas. Tocarlo lo da por visto y abre la novedad más urgente.
    final news = _arrivals.summary(_items);
    final newsPill = news.count == 0
        ? const SizedBox.shrink()
        : Semantics(
            key: const Key('news_pill'),
            liveRegion: true,
            label: 'Novedades: ${news.label}',
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                onPressed: _openNews,
                avatar: const Icon(Icons.notifications_active_outlined, size: 16),
                label: Text(news.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                backgroundColor: news.p1 > 0 ? DashColors.dangerBg : DashColors.warnBg,
                visualDensity: VisualDensity.compact,
              ),
            ),
          );
    final list = _buildList(context, page);
    return Theme(
      data: dashTheme(),
      child: Scaffold(
        appBar: AppBar(
          title: _title,
          actions: [
            if (!narrowBar) ...[toggle, const SizedBox(width: 4), newsPill],
            Builder(builder: _resourcesButton),
            Builder(builder: _dispatchButton),
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
            if (narrowBar) Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 0), child: Row(children: [toggle, const Spacer(), newsPill])),
            _NodesBar(nodes: _nodes, unknown: _nodesUnknown, now: _now),
            if (page != null) _CountersBar(counters: page.counters, now: _now, urgency: _mode == _Mode.all ? _urgency : null, bareActive: _mode == _Mode.bare, pendingActive: _mode == _Mode.pending, onUrgency: (u) => _switch(_Mode.all, urgency: u), onBare: () => _switch(_Mode.bare), onPending: () => _switch(_Mode.pending)),
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
                                  identity: _identity,
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

  /// «Registrar informe»: en pantallas anchas con texto; en estrechas sólo el ícono (no le quita sitio al título).
  /// «Recursos»: abre el panel. Si hay unidades en conflicto lo dice en una insignia (superpuesta: no cambia el tamaño del botón),
  /// porque un conflicto sin resolver deja una unidad fuera de las propuestas y no debe pasar desapercibido con el panel cerrado.
  Widget _resourcesButton(BuildContext context) {
    final conflicts = _resources.where((u) => u.conflict).length;
    final icon = conflicts == 0
        ? const Icon(Icons.local_shipping_outlined)
        : Badge(key: const Key('resources_conflicts_badge'), label: Text('$conflicts'), backgroundColor: DashColors.danger, child: const Icon(Icons.local_shipping_outlined));
    final tip = conflicts == 0 ? 'Recursos' : 'Recursos: $conflicts ${conflicts == 1 ? 'unidad en conflicto' : 'unidades en conflicto'}';
    // Siempre un icono (con su explicación al posarse): con el texto, la barra no cabe a 700 px junto a «Registrar informe».
    return IconButton(key: const Key('resources_open'), tooltip: tip, onPressed: _openResources, icon: icon);
  }

  Widget _dispatchButton(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return narrow
        ? IconButton(key: const Key('dispatch_open'), tooltip: 'Registrar informe', onPressed: () => _openDispatch(context), icon: const Icon(Icons.edit_note))
        : TextButton.icon(key: const Key('dispatch_open'), onPressed: () => _openDispatch(context), icon: const Icon(Icons.edit_note), label: const Text('Registrar informe'));
  }

  Future<void> _openDispatch(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => Theme(data: dashTheme(), child: DispatchDialog(api: widget.api, who: _who, identity: _identity)));
    if (ok != true || !mounted || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(key: Key('dispatch_done'), content: Text('Informe registrado. Aparecerá en la lista en unos segundos.')));
    _load();
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
    // Filtros sobre lo cargado: lo que se esconde se cuenta (y cuántos son P1) en la cabecera; el filtro activo siempre se lee.
    final result = _filter.apply(_items);
    final filterButton = IconButton(
      key: const Key('filter_open'),
      tooltip: _filter.isActive ? 'Filtro activo: ${_filter.describe()}' : 'Filtrar y buscar en lo cargado',
      onPressed: () => setState(() => _filterOpen = !_filterOpen),
      icon: Icon(_filter.isActive ? Icons.filter_alt : Icons.filter_alt_outlined, color: _filter.isActive ? DashColors.warn : null),
    );
    final summaryText = 'Filtro: ${_filter.describe()} · ${result.shown.length} de ${_items.length} cargados${result.hiddenSummary == null ? '' : ' · ${result.hiddenSummary}'}';
    // La cabecera es fija (no se pierde al final de una lista larga): dice qué se está viendo y cómo ver el resto.
    final headerRow = _mode == _Mode.short
        ? Row(
            children: [
              Expanded(child: Text('Vista corta · ${page.total} de ${page.counters.incidents} incidentes', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
              const SizedBox(width: 8),
              filterButton,
              OutlinedButton(key: const Key('show_all'), onPressed: () => _switch(_Mode.all), child: Text('Ver todo (${page.counters.incidents})')),
            ],
          )
        : Row(
            children: [
              OutlinedButton.icon(key: const Key('back_to_short'), onPressed: () => _switch(_Mode.short), icon: const Icon(Icons.arrow_back, size: 16), label: const Text('Volver a la vista corta')),
              const SizedBox(width: 12),
              Expanded(child: Text(_mode == _Mode.bare ? 'Sólo SOS sin detalle (${page.total})' : (_mode == _Mode.pending ? 'Pendientes de decisión (${page.total})' : (_urgency == null ? 'Todos los incidentes (${page.total})' : 'Incidentes ${_urgency!} (${page.total})')), style: const TextStyle(fontWeight: FontWeight.w700))),
              filterButton,
            ],
          );
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          headerRow,
          if (_filter.isActive) Padding(padding: const EdgeInsets.only(top: 4), child: Text(summaryText, key: const Key('filter_summary'), style: const TextStyle(fontSize: 13, color: DashColors.warn, fontWeight: FontWeight.w700))),
          if (_filterOpen) _FilterPanel(filter: _filter, onChanged: (f) => setState(() => _filter = f)),
        ],
      ),
    );
    final bare = _mode == _Mode.short ? page.bare : null;
    var bareInserted = bare == null;
    for (final row in result.shown) {
      if (!bareInserted && (row.urgency == 'P3' || row.urgency == 'P4')) {
        children.add(_BareRow(bare: bare!, now: now, onShow: () => _switch(_Mode.bare)));
        bareInserted = true;
      }
      children.add(IncidentCard(row: row, now: now, selected: row.id == _selected, onTap: () => _select(row.id)));
    }
    if (!bareInserted) children.add(_BareRow(bare: bare!, now: now, onShow: () => _switch(_Mode.bare)));
    if (_items.isNotEmpty && result.shown.isEmpty) {
      children.add(const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Ningún incidente de los cargados coincide con el filtro.', key: Key('filter_none'), textAlign: TextAlign.center, style: TextStyle(color: DashColors.muted, fontSize: 15)))));
    }
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
    return Column(
      children: [
        header,
        Expanded(
          child: _showMap
              // Una instancia nueva por modo/urgencia: al cambiar de vista el mapa se encuadra de nuevo; con los datos que
              // llegan cada 2 s NO (ver IncidentMap).
              ? IncidentMap(key: ValueKey('map-${_mode.name}-${_urgency ?? ''}'), rows: result.shown, selected: _selected, onSelect: _select, totalIncidents: page.counters.incidents - result.hidden.length, resources: _resources, silence: SilenceLayer(on: _silenceOn, info: _coverage, note: _silenceNote, onToggle: _toggleSilence))
              : ListView(key: const Key('incident_list'), children: children),
        ),
      ],
    );
  }
}

// ───────────────────────────── piezas ─────────────────────────────

/// El panel de filtros y búsqueda (lo abre y lo cierra la persona; no se mueve solo).
class _FilterPanel extends StatefulWidget {
  const _FilterPanel({required this.filter, required this.onChanged});

  final IncidentFilter filter;
  final void Function(IncidentFilter) onChanged;

  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  late final TextEditingController _query = TextEditingController(text: widget.filter.query);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('filter_panel'),
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: DashColors.border)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('filter_query'),
          controller: _query,
          decoration: const InputDecoration(hintText: 'Buscar en lo cargado (p. ej. atrapado, vía, incendio)', prefixIcon: Icon(Icons.search, size: 20), isDense: true),
          onChanged: (v) => widget.onChanged(widget.filter.withQuery(v)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final f in FilterFlag.values)
              FilterChip(key: Key('filter_flag_${f.name}'), label: Text(f.label, style: const TextStyle(fontSize: 12)), selected: widget.filter.flags.contains(f), visualDensity: VisualDensity.compact, onSelected: (on) => widget.onChanged(widget.filter.withFlag(f, on))),
            TextButton(
              key: const Key('filter_clear'),
              onPressed: widget.filter.isActive
                  ? () {
                      _query.clear();
                      widget.onChanged(widget.filter.cleared());
                    }
                  : null,
              child: const Text('Quitar filtro'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Lista | Mapa: dos formas de ver los MISMOS incidentes cargados. Va en la barra superior, de iconos, para no
/// quitarle altura a la lista (es lo que se lee durante horas).
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.map, required this.onChanged});

  final bool map;
  final void Function(bool map) onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<bool>(
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact, padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
    segments: const [
      ButtonSegment(value: false, icon: Icon(Icons.view_list, key: Key('view_list')), tooltip: 'Ver la lista'),
      ButtonSegment(value: true, icon: Icon(Icons.map_outlined, key: Key('view_map')), tooltip: 'Ver el mapa'),
    ],
    selected: {map},
    onSelectionChanged: (s) => onChanged(s.first),
  );
}

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
  const _CountersBar({required this.counters, required this.now, required this.urgency, required this.bareActive, required this.pendingActive, required this.onUrgency, required this.onBare, required this.onPending});
  final Counters counters;
  final DateTime now;
  final bool pendingActive;
  final VoidCallback onPending;
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
          // Una sola línea que MIDE SIEMPRE LO MISMO: con `Wrap`, cada contador nuevo o cada ancho distinto añadía una línea y
          // le quitaba altura a la lista y al detalle. Con poco ancho se desplaza en horizontal.
          SingleChildScrollView(
            key: const Key('stats_row'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, stat) in <Widget>[
                  _Stat(const Key('counter_highUncertainty'), 'Incertidumbre alta', counters.highUncertainty, DashColors.warn),
                  _Stat(const Key('counter_needsReview'), 'A revisar', counters.needsReview, DashColors.warn),
                  // Propuestas que esperan a una persona, sobre el TOTAL del nodo: tocarlas pide sólo esas; dice desde cuándo espera la más antigua.
                  _Stat(const Key('counter_pendingDecision'), 'Pendientes de decisión', counters.pendingDecision, DashColors.warn, onTap: counters.pendingDecision > 0 ? onPending : null, active: pendingActive, suffix: counters.pendingOldestAt == null ? '' : ' · la más antigua ${ageLabel(counters.pendingOldestAt!, now)}'),
                  _Stat(const Key('counter_discrepancies'), 'Decisiones contradictorias', counters.discrepancies, DashColors.danger),
                  _Stat(const Key('counter_withContradictions'), 'Con contradicciones', counters.withContradictions, DashColors.danger),
                  _Stat(const Key('counter_bareSos'), 'SOS sin detalle', counters.bareSos, DashColors.muted, onTap: counters.bareSos > 0 ? onBare : null, active: bareActive),
                  _Stat(const Key('counter_followUp'), 'En seguimiento fuera de la vista', counters.followUp, DashColors.muted),
                ].indexed) ...[if (i > 0) const SizedBox(width: 10), stat],
              ],
            ),
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
  const _Stat(this.statKey, this.label, this.value, this.color, {this.onTap, this.active = false, this.suffix = ''});
  final Key statKey;
  final String label;
  final int value;
  final Color color;
  final VoidCallback? onTap;
  final bool active;

  /// Texto que se añade a la etiqueta (p. ej. desde cuándo espera la más antigua).
  final String suffix;

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
          Flexible(child: Text('$label$suffix', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: DashColors.muted))),
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

/// Cómo va la lectura de las zonas en silencio: sin pedir, leída, un nodo anterior que no las calcula, o un fallo.
enum _CoverageState { idle, ok, unsupported, failed }
