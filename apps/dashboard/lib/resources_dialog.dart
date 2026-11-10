import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'api.dart';
import 'models.dart';
import 'theme.dart';

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,24}$');
const List<String> _kinds = ['ambulancia', 'bomberos', 'rescate', 'transito'];

/// El panel «Recursos»: qué unidades hay, cuáles están disponibles, y cambiarlo EN VIVO.
///
/// Cambiar una unidad es una DECLARACIÓN que el nodo guarda y replica a los demás; no se edita nada en el sitio. Cada
/// declaración nombra las que reemplaza (las vigentes de esa unidad) y dice quién la hizo. Si dos nodos aislados declararon
/// cosas distintas hay un CONFLICTO: la unidad NO se ofrece hasta que una persona elija (y la elección reemplaza a las dos).
/// Nada de esto despacha nada: sólo cambia qué unidades puede nombrar el agente 6, y sus propuestas siguen esperando a una persona.
class ResourcesDialog extends StatefulWidget {
  const ResourcesDialog({super.key, required this.api, required this.who, required this.units, required this.onChanged});

  final DashboardApi api;

  /// El nombre de quien declara, compartido con las aprobaciones y los informes: se recuerda durante la sesión.
  final ValueNotifier<String> who;
  final List<ResourceUnit> units;

  /// Se llama con la lista nueva tras cada declaración que el nodo aceptó.
  final void Function(List<ResourceUnit> units) onChanged;

  @override
  State<ResourcesDialog> createState() => _ResourcesDialogState();
}

class _ResourcesDialogState extends State<ResourcesDialog> {
  late List<ResourceUnit> _units = [...widget.units]..sort((a, b) => a.id.compareTo(b.id));
  late final TextEditingController _who = TextEditingController(text: widget.who.value);
  final TextEditingController _newId = TextEditingController();
  final TextEditingController _newLabel = TextEditingController();
  final TextEditingController _newLat = TextEditingController();
  final TextEditingController _newLon = TextEditingController();
  String _newKind = 'ambulancia';
  bool _busy = false;
  bool _whoMissing = false;
  String? _error;
  String? _notice;
  String? _newError;

  @override
  void dispose() {
    _who.dispose();
    _newId.dispose();
    _newLabel.dispose();
    _newLat.dispose();
    _newLon.dispose();
    super.dispose();
  }

  /// Declara y vuelve a leer lo que dice el nodo. `true` si el nodo la aceptó.
  Future<bool> _declare({required String id, required String kind, required String label, required double lat, required double lon, required bool available, List<String> supersedes = const []}) async {
    if (_busy) return false;
    final who = _who.text.trim();
    if (who.isEmpty || who.length > 80) {
      setState(() => _whoMissing = true);
      return false;
    }
    widget.who.value = who;
    setState(() {
      _busy = true;
      _whoMissing = false;
      _error = null;
      _notice = null;
    });
    try {
      await widget.api.declareResource(id: id, kind: kind, label: label, lat: lat, lon: lon, available: available, who: who, supersedes: supersedes);
      // Desde aquí la unidad SÍ está declarada en el nodo: si falla releer la lista, no se dice que no quedó.
      try {
        final fresh = await widget.api.resources();
        if (!mounted) return true;
        setState(() => _units = [...fresh]..sort((a, b) => a.id.compareTo(b.id)));
        widget.onChanged(fresh);
      } on Object {
        if (mounted) setState(() => _notice = 'La unidad SÍ quedó declarada, pero no se pudo releer la lista. Se actualizará sola en unos segundos.');
      }
      return true;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = 'El nodo no aceptó la declaración (${e.status}): ${e.message}. NO quedó declarada.');
    } on AccessDenied {
      if (mounted) setState(() => _error = 'El nodo no acepta el código de acceso. La unidad NO quedó declarada: cierra este cuadro y escribe el código de nuevo.');
    } on Object catch (e) {
      final network = e is TimeoutException || e is SocketException || e.toString().contains('ClientException');
      if (mounted) {
        setState(() => _error = network
            ? 'No se pudo contactar al nodo. La unidad NO quedó declarada: inténtalo de nuevo.'
            : 'No se pudo declarar la unidad ($e). NO quedó declarada.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  Future<void> _toggle(ResourceUnit u) => _declare(id: u.id, kind: u.kind, label: u.label, lat: u.lat, lon: u.lon, available: !u.available, supersedes: u.declarationIds);

  Future<void> _resolve(ResourceUnit u, {required bool available}) => _declare(id: u.id, kind: u.kind, label: u.label, lat: u.lat, lon: u.lon, available: available, supersedes: u.declarationIds);

  Future<void> _add() async {
    final id = _newId.text.trim(), label = _newLabel.text.trim();
    String? error;
    final lat = double.tryParse(_newLat.text.trim().replaceAll(',', '.')), lon = double.tryParse(_newLon.text.trim().replaceAll(',', '.'));
    if (!_idPattern.hasMatch(id)) {
      error = 'El identificador son de 1 a 24 letras, cifras, «-» o «_» (sin espacios).';
    } else if (_units.any((u) => u.id == id)) {
      error = 'La unidad «$id» ya existe: para cambiarla usa su interruptor.';
    } else if (label.isEmpty || label.length > 80) {
      error = 'El nombre debe tener de 1 a 80 caracteres.';
    } else if (lat == null || lon == null || !lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      error = 'La latitud va de -90 a 90 y la longitud de -180 a 180 (p. ej. 5.0689 y -75.5174).';
    }
    if (error != null) {
      setState(() => _newError = error);
      return;
    }
    setState(() => _newError = null);
    final ok = await _declare(id: id, kind: _newKind, label: label, lat: lat!, lon: lon!, available: true);
    if (ok && mounted) {
      _newId.clear();
      _newLabel.clear();
      _newLat.clear();
      _newLon.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('resources_dialog'),
      backgroundColor: DashColors.surface,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Recursos', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                    IconButton(key: const Key('resources_close'), tooltip: 'Cerrar', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
                  ],
                ),
                const Text('Las unidades que el sistema puede proponer. Cambiarlas no despacha nada: sólo cambia lo que el agente 6 puede nombrar, y toda propuesta sigue esperando a una persona.', style: TextStyle(fontSize: 13, color: DashColors.muted, height: 1.3)),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('resources_who'),
                  controller: _who,
                  enabled: !_busy,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Tu nombre (quien declara)', counterText: ''),
                ),
                if (_whoMissing) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Escribe tu nombre para declarar una unidad.', key: Key('resources_who_error'), style: TextStyle(color: DashColors.danger, fontSize: 13))),
                if (_error != null)
                  Container(
                    key: const Key('resources_error'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: DashColors.dangerBg, borderRadius: BorderRadius.circular(8)),
                    child: Text(_error!, style: const TextStyle(color: DashColors.danger, fontSize: 14, height: 1.3)),
                  ),
                if (_notice != null)
                  Container(
                    key: const Key('resources_notice'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: DashColors.warnBg, borderRadius: BorderRadius.circular(8)),
                    child: Text(_notice!, style: const TextStyle(color: DashColors.warn, fontSize: 14, height: 1.3)),
                  ),
                for (final u in _units) _UnitRow(unit: u, busy: _busy, onToggle: () => _toggle(u), onResolve: (a) => _resolve(u, available: a)),
                const Divider(height: 28),
                const Text('Añadir una unidad', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('unit_new_kind'),
                  initialValue: _newKind,
                  decoration: const InputDecoration(labelText: 'Tipo'),
                  items: [for (final k in _kinds) DropdownMenuItem(value: k, child: Text(resourceKindLabel(k)))],
                  onChanged: _busy ? null : (v) => setState(() => _newKind = v ?? _newKind),
                ),
                const SizedBox(height: 8),
                TextField(key: const Key('unit_new_id'), controller: _newId, enabled: !_busy, decoration: const InputDecoration(labelText: 'Identificador', hintText: 'AMB-09')),
                const SizedBox(height: 8),
                TextField(key: const Key('unit_new_label'), controller: _newLabel, enabled: !_busy, decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ambulancia 9 · Base Norte')),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: TextField(key: const Key('unit_new_lat'), controller: _newLat, enabled: !_busy, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitud', hintText: '5.0689'))),
                    const SizedBox(width: 12),
                    Expanded(child: TextField(key: const Key('unit_new_lon'), controller: _newLon, enabled: !_busy, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitud', hintText: '-75.5174'))),
                  ],
                ),
                if (_newError != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_newError!, key: const Key('unit_new_error'), style: const TextStyle(color: DashColors.danger, fontSize: 13))),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: FilledButton.icon(key: const Key('unit_new_add'), onPressed: _busy ? null : _add, icon: const Icon(Icons.add), label: const Text('Añadir unidad'))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.unit, required this.busy, required this.onToggle, required this.onResolve});

  final ResourceUnit unit;
  final bool busy;
  final VoidCallback onToggle;
  final void Function(bool available) onResolve;

  @override
  Widget build(BuildContext context) {
    final u = unit;
    final state = u.conflict ? 'En conflicto' : (u.available ? 'Disponible' : 'No disponible');
    final color = u.conflict ? DashColors.danger : (u.available ? DashColors.ok : DashColors.muted);
    return Container(
      key: Key('unit_${u.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: DashColors.surfaceHigh, borderRadius: BorderRadius.circular(10), border: Border.all(color: u.conflict ? DashColors.danger : DashColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_shipping_outlined, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    Text('${u.id} · ${resourceKindLabel(u.kind)}${u.declaredBy == null ? '' : ' · declarada por ${u.declaredBy}'}', style: const TextStyle(fontSize: 12, color: DashColors.muted)),
                    Text(state, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
                  ],
                ),
              ),
              if (!u.conflict) Semantics(label: 'Disponibilidad de ${u.label}', child: Switch(key: Key('unit_toggle_${u.id}'), value: u.available, onChanged: busy ? null : (_) => onToggle())),
            ],
          ),
          if (u.conflict) ...[
            const SizedBox(height: 6),
            Text(
              'Dos declaraciones que no coinciden (hechas en nodos aislados). Por seguridad esta unidad no se ofrece hasta que elijas.',
              key: Key('unit_conflict_${u.id}'),
              style: const TextStyle(fontSize: 13, color: DashColors.text, height: 1.3),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(key: Key('unit_keep_available_${u.id}'), onPressed: busy ? null : () => onResolve(true), child: const Text('Dejar disponible')),
                OutlinedButton(key: Key('unit_keep_unavailable_${u.id}'), onPressed: busy ? null : () => onResolve(false), child: const Text('Dejar no disponible')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
