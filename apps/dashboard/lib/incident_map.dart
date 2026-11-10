import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'incident_card.dart';
import 'map_geometry.dart';
import 'models.dart';
import 'theme.dart';

/// El mapa del tablero: dónde está cada incidente, sin salir a Internet (sin teselas: un esquema con
/// cuadrícula y barra de escala, que funciona en una sala sin red).
///
/// Cuatro reglas, todas con prueba:
///  · El encuadre se fija UNA vez y no se mueve cuando llegan incidentes (el tablero consulta cada 2 s: si
///    se moviera, los marcadores se irían de debajo del dedo). Lo que cae fuera se AVISA y se trae con
///    «Reencuadrar», a petición.
///  · Lo que no tiene ubicación no desaparece: se lista aparte y se puede elegir igual.
///  · Dos incidentes en el mismo sitio forman un grupo con su conteo, con el más urgente encima; no se
///    desplaza ninguno para «separarlos» (eso inventaría posiciones) y un P1 nunca queda tapado.
///  · La precisión no se finge: si la ubicación es menos precisa que el marcador, se dibuja su anillo de
///    incertidumbre; si no se sabe, no se dibuja uno inventado.
/// La capa de «silencio»: las zonas que reportaron y callaron. **El silencio NO es seguridad**: una zona sin marca no está a salvo, y una
/// marcada sólo dejó de reportar. Va DEBAJO de los incidentes, no recibe toques y se enciende y apaga con un interruptor (apagada no se
/// pide al nodo ni se dibuja).
class SilenceLayer {
  const SilenceLayer({required this.on, this.info, this.note, required this.onToggle});

  final bool on;

  /// Lo último que dijo el nodo (`null` mientras no se haya leído, o si el nodo no lo calcula).
  final CoverageInfo? info;

  /// Por qué no hay (o no está al día) la lectura: «leyendo…», «este nodo no las calcula», «no se pudo actualizar».
  final String? note;
  final VoidCallback onToggle;
}

class IncidentMap extends StatefulWidget {
  const IncidentMap({super.key, required this.rows, required this.selected, required this.onSelect, required this.totalIncidents, this.resources = const [], this.silence});

  /// Los incidentes cargados (pueden ser un subconjunto del total: la vista corta, por ejemplo).
  final List<IncidentRow> rows;
  final String? selected;
  final void Function(String id) onSelect;

  /// Cuántos incidentes hay en el nodo (para decir que el mapa muestra los cargados y no el total).
  final int totalIncidents;

  /// Las unidades (ambulancias, bomberos…): una capa DEBAJO de los incidentes, que no se toca ni cambia el encuadre. Vacía = sin capa.
  final List<ResourceUnit> resources;

  /// La capa de silencio; `null` = el tablero no la ofrece (ni interruptor ni rótulo).
  final SilenceLayer? silence;

  @override
  State<IncidentMap> createState() => _IncidentMapState();
}

class _IncidentMapState extends State<IncidentMap> {
  static const double _alertSlot = 34, _statusSlot = 44;

  MapFrame? _frame;

  /// Los incidentes del grupo que se tocó (más de uno en el mismo sitio), para enseñarlos y poder elegir.
  List<String>? _openMembers;

  static GeoPoint _at(IncidentRow r) => GeoPoint(r.lat!, r.lon!);

  void _reframe(List<IncidentRow> located) => setState(() {
    _frame = MapFrame.aroundOrNull([for (final r in located) _at(r)]);
    _openMembers = null;
  });

  void _tapCluster(MarkerCluster cluster) {
    if (cluster.count == 1) {
      setState(() => _openMembers = null);
      widget.onSelect(cluster.top.id);
    } else {
      final ids = [for (final m in cluster.members) m.id];
      setState(() => _openMembers = _openMembers != null && _openMembers!.first == ids.first ? null : ids);
    }
  }

  @override
  Widget build(BuildContext context) {
    final located = [for (final r in widget.rows) if (r.hasLocation) r];
    final unlocated = [for (final r in widget.rows) if (!r.hasLocation) r];
    // El encuadre se fija la primera vez que hay algo localizado y ya no se recalcula solo.
    _frame ??= MapFrame.aroundOrNull([for (final r in located) _at(r)]);
    final frame = _frame;
    final outside = frame == null ? const <IncidentRow>[] : [for (final r in located) if (!frame.contains(_at(r))) r];
    final inside = frame == null ? const <IncidentRow>[] : [for (final r in located) if (frame.contains(_at(r))) r];
    final more = widget.totalIncidents - widget.rows.length;
    final unitsInside = frame == null ? const <ResourceUnit>[] : [for (final u in widget.resources) if (frame.contains(GeoPoint(u.lat, u.lon))) u];
    final unitsOutside = widget.resources.length - unitsInside.length;
    // Las unidades se cuentan APARTE (un rótulo sobre el lienzo): el estado de los incidentes conserva su cláusula final
    // «N más en la lista completa» y no se recorta por llevar más texto en pantallas estrechas.
    final unitsText = widget.resources.isEmpty ? null : 'Unidades: ${unitsInside.length} en el mapa${unitsOutside > 0 ? ' · $unitsOutside fuera de la vista' : ''}';
    final layer = widget.silence;
    final coverage = layer != null && layer.on ? layer.info : null;
    final zonesInside = frame == null || coverage == null ? const <SilentZone>[] : [for (final z in coverage.cells) if (frame.contains(GeoPoint(z.lat, z.lon))) z];
    final silenceText = layer == null || !layer.on ? null : _silenceCaption(coverage, layer.note, zonesInside.length);
    final status = '${inside.length} en el mapa · ${unlocated.length} sin ubicación · ${outside.length} fuera de la vista${more > 0 ? ' · $more más en la lista completa' : ''}';
    final byId = {for (final r in widget.rows) r.id: r};
    final open = [for (final id in _openMembers ?? const <String>[]) if (byId[id] != null) byId[id]!];

    // Cluster abierto: sus incidentes (los que sigan en las filas) para enseñarlos en una ventana sobre el lienzo.
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: frame == null
                ? Container(
                    decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: DashColors.border)),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: const Text('Ningún incidente de los que están cargados tiene ubicación.', key: Key('map_empty'), textAlign: TextAlign.center, style: TextStyle(color: DashColors.muted, fontSize: 15)),
                  )
                : _Canvas(
                    frame: frame,
                    rows: inside,
                    units: unitsInside,
                    unitsCaption: unitsText,
                    zones: zonesInside,
                    coverage: coverage,
                    selected: widget.selected,
                    onTapCluster: _tapCluster,
                    open: open.length > 1 ? open : const [],
                    onPick: (id) {
                      setState(() => _openMembers = null);
                      widget.onSelect(id);
                    },
                    onClose: () => setState(() => _openMembers = null),
                  ),
          ),
        ),
        // Estas dos zonas miden SIEMPRE lo mismo, haya o no contenido: si aparecieran y desaparecieran, el lienzo
        // cambiaría de tamaño y todos los marcadores se moverían bajo el dedo.
        SizedBox(height: _alertSlot, child: outside.isEmpty ? null : _OutsideAlert(outside: outside)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: SizedBox(
            height: _statusSlot,
            child: Row(
              children: [
                Expanded(child: Text(status, key: const Key('map_status'), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: DashColors.muted))),
                TextButton.icon(
                  key: const Key('map_reframe'),
                  onPressed: located.isEmpty ? null : () => _reframe(located),
                  icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
                  label: const Text('Reencuadrar'),
                  style: outside.isEmpty ? null : TextButton.styleFrom(foregroundColor: DashColors.warn),
                ),
              ],
            ),
          ),
        ),
        // El interruptor y el rótulo de la capa de silencio van FUERA del lienzo, en una franja de altura constante (encendida o apagada): un
        // rótulo encima del mapa taparía incidentes, y el lienzo no debe cambiar de tamaño al encender la capa.
        if (layer != null) _SilenceStrip(layer: layer, text: silenceText),
        _UnlocatedSection(rows: unlocated, onPick: widget.onSelect),
      ],
    );
  }
}

// ───────────────────────────── el lienzo ─────────────────────────────

class _Canvas extends StatelessWidget {
  const _Canvas({required this.frame, required this.rows, required this.units, required this.unitsCaption, required this.zones, required this.coverage, required this.selected, required this.onTapCluster, required this.open, required this.onPick, required this.onClose});

  final MapFrame frame;
  final List<IncidentRow> rows;
  final List<ResourceUnit> units;

  /// «Unidades: 3 en el mapa · 1 fuera de la vista»; nulo si no hay capa de recursos.
  final String? unitsCaption;

  /// Las zonas en silencio dentro del encuadre y lo que las describe (nulas/vacías con la capa apagada).
  final List<SilentZone> zones;
  final CoverageInfo? coverage;
  final String? selected;
  final void Function(MarkerCluster cluster) onTapCluster;

  /// Los incidentes del grupo abierto (vacío si no hay ninguno abierto).
  final List<IncidentRow> open;
  final void Function(String id) onPick;
  final VoidCallback onClose;

  static const double _hitHeight = 44;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: DashColors.border)),
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth, h = box.maxHeight;
            final byId = {for (final r in rows) r.id: r};
            final clusters = clusterMarkers([for (final r in rows) MapMarker(id: r.id, urgency: r.urgency, at: frame.project(GeoPoint(r.lat!, r.lon!), width: w, height: h))], radiusPx: 14);
            // Se pinta de menos a más urgente: el P1 queda encima de lo que tenga cerca.
            final paintOrder = [...clusters]..sort((a, b) => b.urgency.compareTo(a.urgency));
            final pxPerMeter = frame.metersToPixels(1, width: w, height: h);
            final scaleMeters = niceScaleMeters(pxPerMeter);
            final scalePx = scaleMeters * pxPerMeter;
            final center = frame.project(frame.center, width: w, height: h);
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _GridPainter(spacing: scalePx, origin: Offset(center.x, center.y))))),
                // Las zonas en silencio van DEBAJO de todo (anillos, unidades, incidentes) y no reciben toques: un P1 nunca queda tapado.
                if (coverage != null)
                  for (final z in zones) _silenceZone(z, coverage!, w, h),
                // Los anillos de precisión van debajo de los marcadores y no reciben toques.
                for (final c in paintOrder)
                  if (_ringPx(byId[c.top.id]!, pxPerMeter) case final ring?)
                    Positioned(
                      left: c.at.x - ring,
                      top: c.at.y - ring,
                      width: ring * 2,
                      height: ring * 2,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: Key('map_precision_${c.top.id}'),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.urgency(c.urgency).withValues(alpha: 0.12), border: Border.all(color: DashColors.urgency(c.urgency).withValues(alpha: 0.55), width: 1.5)),
                        ),
                      ),
                    ),
                // Las unidades van debajo de los incidentes: un P1 nunca queda tapado por una ambulancia.
                for (final u in units)
                  if (frame.project(GeoPoint(u.lat, u.lon), width: w, height: h) case final p)
                    Positioned(left: p.x - _UnitMark.size / 2, top: p.y - _UnitMark.size / 2, width: _UnitMark.size, height: _UnitMark.size, child: _UnitMark(key: Key('map_unit_${u.id}'), unit: u)),
                for (final c in paintOrder)
                  Positioned(
                    left: c.at.x - _hitWidth(c) / 2,
                    top: c.at.y - _hitHeight / 2,
                    width: _hitWidth(c),
                    height: _hitHeight,
                    child: _Marker(key: Key('map_marker_${c.top.id}'), cluster: c, row: byId[c.top.id]!, selectedId: c.members.any((m) => m.id == selected) ? selected : null, onTap: () => onTapCluster(c)),
                  ),
                if (open.isNotEmpty) _popover(open, clusters, w, h),
                if (unitsCaption != null)
                  Positioned(
                    top: 8,
                    left: 10,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: DashColors.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: Text(unitsCaption!, key: const Key('map_units_caption'), style: const TextStyle(fontSize: 12, color: DashColors.muted))),
                      ),
                    ),
                  ),
                const Positioned(top: 8, right: 10, child: _North()),
                Positioned(left: 12, bottom: 10, child: _ScaleBar(meters: scaleMeters, px: scalePx)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Una zona en silencio: un rectángulo rayado de línea discontinua (la forma y el trazado dicen «sin información»; el color solo no).
  /// No recibe toques, pero SÍ conserva su descripción para quien no la ve (una prueba lo fija: `IgnorePointer` ya no esconde la semántica).
  Widget _silenceZone(SilentZone z, CoverageInfo c, double w, double h) {
    final half = c.cellDeg / 2;
    final a = frame.project(GeoPoint(z.lat + half, z.lon - half), width: w, height: h);
    final b = frame.project(GeoPoint(z.lat - half, z.lon + half), width: w, height: h);
    final cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    // Con un encuadre muy abierto la celda sería un punto: se le deja un tamaño mínimo para que se vea.
    final zw = math.max(8.0, (b.x - a.x).abs()), zh = math.max(8.0, (b.y - a.y).abs());
    final reports = '${z.total} ${z.total == 1 ? 'reporte' : 'reportes'} en las últimas ${_windowLabel(c.activity)}';
    final urgent = z.urgent == 0 ? '' : ' (${z.urgent} ${z.urgent == 1 ? 'urgente' : 'urgentes'})';
    final last = ageLabel(z.lastAtMs ~/ 1000, DateTime.fromMillisecondsSinceEpoch(c.nowMs));
    return Positioned(
      left: cx - zw / 2,
      top: cy - zh / 2,
      width: zw,
      height: zh,
      child: IgnorePointer(
        child: Semantics(
          key: ValueKey('map_silence_${z.id}'),
          container: true,
          label: 'Zona en silencio: $reports$urgent; el último llegó $last. El silencio no es seguridad.',
          child: CustomPaint(painter: _SilencePainter(strong: z.urgent > 0)),
        ),
      ),
    );
  }

  /// La caja de toque de un marcador: que quepa el texto entero («P1» o «P1 ×12») y que sea cómoda de tocar.
  static double _hitWidth(MarkerCluster c) => c.count == 1 ? 56.0 : 88.0;

  /// La ventana del grupo abierto: junto al marcador, dentro del lienzo y SIN taparlo. Se ancla por el borde que
  /// toca al marcador (no se estima su altura): debajo si hay sitio, y si no, encima con su borde inferior pegado.
  Widget _popover(List<IncidentRow> open, List<MarkerCluster> clusters, double w, double h) {
    final anchor = clusters.firstWhere((c) => c.members.any((m) => m.id == open.first.id), orElse: () => clusters.first).at;
    const width = 280.0, gap = 26.0; // medio marcador (22) + aire
    final left = (anchor.x - width / 2).clamp(6.0, (w - width - 6).clamp(6.0, double.infinity));
    final spaceBelow = h - (anchor.y + gap), spaceAbove = anchor.y - gap;
    final below = spaceBelow >= 170 || spaceBelow >= spaceAbove;
    final maxHeight = ((below ? spaceBelow : spaceAbove) - 6).clamp(90.0, double.infinity);
    final panel = ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: _ClusterPanel(rows: open, onPick: onPick, onClose: onClose));
    return below
        ? Positioned(left: left, top: anchor.y + gap, width: width, child: panel)
        : Positioned(left: left, bottom: h - (anchor.y - gap), width: width, child: panel);
  }

  /// El radio del anillo de incertidumbre en píxeles, sólo si lo hay y se vería más grande que el marcador.
  static double? _ringPx(IncidentRow r, double pxPerMeter) {
    final meters = r.locRadiusMeters;
    if (meters == null) return null;
    final px = meters * pxPerMeter;
    return px > 16 ? px : null;
  }
}

class _Marker extends StatelessWidget {
  const _Marker({super.key, required this.cluster, required this.row, required this.selectedId, required this.onTap});

  final MarkerCluster cluster;
  final IncidentRow row;

  /// El incidente elegido, si está en este marcador (solo o dentro del grupo).
  final String? selectedId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = selectedId != null;
    final color = DashColors.urgency(cluster.urgency);
    final single = cluster.count == 1;
    final label = single
        ? '${row.urgency}: ${headlineOf(row)}. ${locPrecisionLabel(row.locQuality)}.'
        : '${cluster.count} incidentes en este punto; el más urgente, ${row.urgency}: ${headlineOf(row)}.';
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? Colors.white : DashColors.bg, width: selected ? 3 : 1.5),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 4)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) SizedBox(key: Key('map_selected_$selectedId'), width: 0, height: 0),
                // Si no cabe (muchos incidentes, letra grande) el texto se reduce en vez de desbordar; y más de 99 se dice «99+».
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(single ? row.urgency : '${cluster.urgency} ×${cluster.count > 99 ? '99+' : cluster.count}', maxLines: 1, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: DashColors.onUrgency(cluster.urgency))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Una unidad en el mapa: un cuadrado (los incidentes son redondos, no se confunden) con el icono de su tipo. Disponible = verde;
/// no disponible = gris y hueca; en conflicto = rojo con «!». La forma y el icono dicen lo mismo que el color.
class _UnitMark extends StatelessWidget {
  const _UnitMark({super.key, required this.unit});

  final ResourceUnit unit;
  static const double size = 22;

  @override
  Widget build(BuildContext context) {
    final u = unit;
    final color = u.conflict ? DashColors.danger : (u.available ? DashColors.ok : DashColors.muted);
    final state = u.conflict ? 'En conflicto: no se ofrece' : (u.available ? 'Disponible' : 'No disponible');
    return Tooltip(
      key: Key('map_unit_tip_${u.id}'),
      message: '${u.label} · $state',
      child: Container(
        decoration: BoxDecoration(
          color: u.available && !u.conflict ? color.withValues(alpha: 0.9) : DashColors.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color, width: 2),
        ),
        alignment: Alignment.center,
        child: u.conflict
            ? Text('!', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: color, height: 1))
            : Icon(Icons.local_shipping_outlined, size: 14, color: u.available ? DashColors.bg : color),
      ),
    );
  }
}

class _North extends StatelessWidget {
  const _North();

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.arrow_upward, size: 14, color: DashColors.muted), Text('N', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: DashColors.muted))]),
  );
}

class _ScaleBar extends StatelessWidget {
  const _ScaleBar({required this.meters, required this.px});

  final double meters;
  final double px;

  @override
  Widget build(BuildContext context) {
    final label = meters >= 1000 ? '${(meters / 1000).round()} km' : '${meters.round()} m';
    return IgnorePointer(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: px,
            height: 7,
            decoration: const BoxDecoration(border: Border(left: BorderSide(color: DashColors.muted, width: 2), right: BorderSide(color: DashColors.muted, width: 2), bottom: BorderSide(color: DashColors.muted, width: 2))),
          ),
          const SizedBox(width: 6),
          Text(label, key: const Key('map_scale'), style: const TextStyle(fontSize: 12, color: DashColors.muted, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter({required this.spacing, required this.origin});

  final double spacing;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    if (spacing < 12) return;
    final paint = Paint()
      ..color = DashColors.border.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var x = origin.dx % spacing; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = origin.dy % spacing; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.spacing != spacing || old.origin != origin;
}

// ───────────────────────────── lo que rodea al mapa ─────────────────────────────

/// Avisa de lo que queda fuera de la vista —y de cuántos son P1— sin mover nada.
class _OutsideAlert extends StatelessWidget {
  const _OutsideAlert({required this.outside});

  final List<IncidentRow> outside;

  @override
  Widget build(BuildContext context) {
    final p1 = outside.where((r) => r.urgency == 'P1').length;
    final n = outside.length;
    final text = '${n == 1 ? '1 incidente fuera' : '$n incidentes fuera'} de la vista${p1 == 0 ? '' : (p1 == 1 ? ' (1 es P1)' : ' ($p1 son P1)')}. Toca «Reencuadrar» para verlos.';
    return Container(
      key: const Key('map_outside_alert'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: DashColors.warnBg, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.visibility_off_outlined, size: 16, color: DashColors.warn),
          const SizedBox(width: 8),
          Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// Los incidentes que comparten punto: se enseñan todos y se elige uno, en vez de elegir a ciegas.
class _ClusterPanel extends StatelessWidget {
  const _ClusterPanel({required this.rows, required this.onPick, required this.onClose});

  final List<IncidentRow> rows;
  final void Function(String id) onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('map_cluster_panel'),
    color: DashColors.surfaceHigh,
    elevation: 6,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('En este punto (${rows.length}):', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
              IconButton(key: const Key('map_cluster_close'), onPressed: onClose, tooltip: 'Cerrar', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18)),
            ],
          ),
          Flexible(child: SingleChildScrollView(child: Wrap(spacing: 8, runSpacing: 6, children: [for (final r in rows) _IncidentChip(key: Key('map_cluster_member_${r.id}'), row: r, onTap: () => onPick(r.id))]))),
        ],
      ),
    ),
  );
}

/// Lo que no tiene ubicación no se puede poner en el mapa, pero no desaparece. La zona mide siempre lo mismo.
class _UnlocatedSection extends StatelessWidget {
  const _UnlocatedSection({required this.rows, required this.onPick});

  final List<IncidentRow> rows;
  final void Function(String id) onPick;

  static const double height = 96;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    height: height,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: BoxDecoration(border: Border.all(color: DashColors.border), borderRadius: BorderRadius.circular(10)),
    child: rows.isEmpty
        ? const Align(alignment: Alignment.centerLeft, child: Text('Todos los incidentes cargados tienen ubicación.', key: Key('map_unlocated_empty'), style: TextStyle(fontSize: 13, color: DashColors.muted)))
        : SingleChildScrollView(
            key: const Key('map_unlocated'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [const Icon(Icons.location_off_outlined, size: 15, color: DashColors.muted), const SizedBox(width: 6), Expanded(child: Text('Sin ubicación (${rows.length}): no se pueden poner en el mapa', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))]),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 6, children: [for (final r in rows) _IncidentChip(key: Key('map_unlocated_${r.id}'), row: r, onTap: () => onPick(r.id))]),
              ],
            ),
          ),
  );
}

class _IncidentChip extends StatelessWidget {
  const _IncidentChip({super.key, required this.row, required this.onTap});

  final IncidentRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    onPressed: onTap,
    avatar: CircleAvatar(backgroundColor: DashColors.urgency(row.urgency), child: Text(row.urgency, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: DashColors.onUrgency(row.urgency)))),
    label: Text(headlineOf(row), style: const TextStyle(fontSize: 12)),
    visualDensity: VisualDensity.compact,
  );
}

// ───────────────────────────── la capa de silencio ─────────────────────────────

const Color _kSilence = Color(0xFFA78BFA);

/// «6 h» / «30 min».
String _windowLabel(Duration d) => d.inMinutes % 60 == 0 && d.inMinutes >= 60 ? '${d.inHours} h' : '${d.inMinutes} min';

/// El rótulo de la capa de silencio. Dice lo que SÍ se sabe (cuántas zonas, cuántas se dibujan, cuántos reportes no entran) y, siempre,
/// que el silencio no es seguridad. Sin lectura no afirma un recuento: da la nota.
String _silenceCaption(CoverageInfo? c, String? note, int inside) {
  final lines = <String>[];
  if (c != null) {
    final n = c.silentTotal;
    var head = '$n ${n == 1 ? 'zona' : 'zonas'} en silencio';
    if (c.cells.length < n) head += ' (se dibujan las ${c.cells.length} más urgentes)';
    final outside = c.cells.length - inside;
    if (outside > 0) head += ' · $outside fuera de la vista';
    lines.add(head);
    if (c.withoutLocation > 0) lines.add('${c.withoutLocation} ${c.withoutLocation == 1 ? 'reporte sin ubicación no entra' : 'reportes sin ubicación no entran'}');
  }
  if (note != null) lines.add(note);
  // El aviso va PRIMERO: si el texto no cabe y se recorta, se pierde un detalle y no la advertencia.
  return 'El silencio no es seguridad. ${lines.join(' · ')}';
}

class _SilencePainter extends CustomPainter {
  const _SilencePainter({required this.strong});

  /// La zona tuvo reportes urgentes (P1/P2): relleno y trazo más fuertes.
  final bool strong;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = _kSilence.withValues(alpha: strong ? 0.22 : 0.12));
    canvas.save();
    canvas.clipRect(rect);
    final hatch = Paint()
      ..color = _kSilence.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var d = -size.height; d < size.width; d += 7) {
      canvas.drawLine(Offset(d, size.height), Offset(d + size.height, 0), hatch);
    }
    canvas.restore();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strong ? 2 : 1.4
      ..color = _kSilence.withValues(alpha: 0.9);
    final border = Path()..addRect(rect.deflate(0.7));
    for (final metric in border.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 5, metric.length)), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_SilencePainter old) => old.strong != strong;
}

/// El interruptor de la capa: una píldora de al menos 44 px de alto para tocarla, accesible como interruptor.
class _SilenceToggle extends StatelessWidget {
  const _SilenceToggle({super.key, required this.layer});

  final SilenceLayer layer;

  @override
  Widget build(BuildContext context) {
    final on = layer.on;
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      label: 'Zonas en silencio',
      hint: 'Marca dónde se reportó y se dejó de reportar. El silencio no es seguridad.',
      excludeSemantics: true,
      onTap: layer.onToggle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: layer.onToggle,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: on ? _kSilence.withValues(alpha: 0.25) : DashColors.surface.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: on ? _kSilence : DashColors.border, width: 2), // el mismo grosor: encender no cambia el tamaño de la píldora
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(on ? Icons.visibility_off : Icons.visibility_off_outlined, size: 16, color: on ? DashColors.text : DashColors.muted),
                  const SizedBox(width: 4),
                  Text('Silencio', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? DashColors.text : DashColors.muted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La franja de la capa: el interruptor y, con la capa encendida, lo que se sabe de ella. Mide SIEMPRE lo mismo para que encender la capa no
/// cambie el tamaño del lienzo (y no mueva los marcadores bajo el dedo).
class _SilenceStrip extends StatelessWidget {
  const _SilenceStrip({required this.layer, required this.text});

  final SilenceLayer layer;
  final String? text;

  static const double height = 52;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            _SilenceToggle(key: const Key('map_silence_toggle'), layer: layer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text ?? 'Zonas que reportaron y dejaron de reportar.',
                key: text == null ? const Key('map_silence_hint') : const Key('map_silence_caption'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.25, color: text == null ? DashColors.muted.withValues(alpha: 0.7) : DashColors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
