import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';

import 'api.dart';
import 'incident_card.dart';
import 'models.dart';
import 'theme.dart';

String distanceLabel(int? meters) {
  if (meters == null) return 'distancia desconocida';
  if (meters < 1000) return '$meters m';
  return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

/// El detalle de un incidente: por qué tiene esa prioridad, las observaciones originales, la
/// recomendación del agente 6 con lo que falta antes de aprobar, y el registro de las decisiones.
///
/// Aprobar o rechazar **queda registrado** con el nombre de quien decide y la versión de la
/// recomendación que vio. Si el incidente cambia mientras se decide, no se registra sobre la versión
/// vieja: se avisa y se muestra la nueva.
class IncidentDetailView extends StatefulWidget {
  const IncidentDetailView({super.key, required this.api, required this.id, required this.who, this.every = const Duration(seconds: 2), this.clock, this.onGone});

  final DashboardApi api;
  final String id;

  /// El nombre de quien decide: se recuerda mientras dure la sesión.
  final ValueNotifier<String> who;
  final Duration? every;
  final DateTime Function()? clock;

  /// El incidente ya no existe (se fusionó o se dividió): quien muestra esto vuelve a pedir la lista.
  final VoidCallback? onGone;

  @override
  State<IncidentDetailView> createState() => _IncidentDetailViewState();
}

class _IncidentDetailViewState extends State<IncidentDetailView> {
  IncidentDetail? _detail;
  bool _gone = false;
  Object? _error;
  bool _changed = false;
  String? _ok;
  bool _loading = false;
  Timer? _timer;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _load();
    final every = widget.every;
    if (every != null) _timer = Timer.periodic(every, (_) => _load());
  }

  @override
  void didUpdateWidget(IncidentDetailView old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      setState(() {
        _detail = null;
        _gone = false;
        _error = null;
        _changed = false;
        _ok = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final id = widget.id;
    try {
      final d = await widget.api.detail(id);
      if (!mounted || id != widget.id) return;
      setState(() {
        _detail = d;
        _error = null;
        _gone = false;
      });
    } on IncidentGone {
      if (!mounted || id != widget.id) return;
      setState(() => _gone = true);
      widget.onGone?.call();
    } on Object catch (e) {
      if (mounted && id == widget.id) setState(() => _error = e);
    } finally {
      _loading = false;
    }
  }

  Future<void> _decide(bool granted) async {
    final seen = _detail;
    if (seen == null || !seen.recommendation.canDecide) return;
    setState(() {
      _changed = false;
      _ok = null;
    });
    final outcome = await showDialog<_DecisionOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DecisionDialog(api: widget.api, seen: seen, granted: granted, who: widget.who),
    );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case _Registered(:final who):
        setState(() => _ok = granted ? 'Aprobación registrada a nombre de $who.' : 'Rechazo registrado a nombre de $who.');
        unawaited(_load());
      case _Changed(:final fresh):
        setState(() {
          _detail = fresh;
          _changed = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) {
      return const _Message(key: Key('detail_gone'), icon: Icons.call_split, text: 'Este incidente ya no existe tal como estaba: pudo fusionarse con otro o dividirse. Se vuelve a pedir la lista.');
    }
    final d = _detail;
    if (d == null) {
      if (_error != null) {
        return Center(
          key: const Key('detail_error'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No se pudo leer el detalle de este incidente.', style: TextStyle(color: DashColors.muted)),
              const SizedBox(height: 8),
              FilledButton(key: const Key('detail_retry'), onPressed: () {
                setState(() => _error = null);
                _load();
              }, child: const Text('Reintentar')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      key: const Key('detail_panel'),
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null)
                const _Notice(key: Key('detail_stale_notice'), color: DashColors.warn, bg: DashColors.warnBg, icon: Icons.cloud_off, text: 'No se pudo actualizar este detalle: se muestra la última versión leída.'),
              if (_changed)
                const _Notice(
                  key: Key('changed_banner'),
                  color: DashColors.warn,
                  bg: DashColors.warnBg,
                  icon: Icons.sync_problem,
                  text: 'El incidente cambió mientras decidías, así que no se registró nada. Esta es la recomendación nueva: revísala y decide de nuevo.',
                ),
              if (_ok != null) _Notice(key: const Key('decision_ok'), color: DashColors.ok, bg: const Color(0xFF173A2B), icon: Icons.check_circle, text: _ok!),
              _Header(d, _now),
              const SizedBox(height: 16),
              _Why(d),
              const SizedBox(height: 16),
              _Observations(d, _now),
              const SizedBox(height: 16),
              _Recommendation(d: d, onApprove: () => _decide(true), onReject: () => _decide(false), now: _now),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── piezas ─────────────────────────────

class _Message extends StatelessWidget {
  const _Message({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 36, color: DashColors.muted), const SizedBox(height: 12), Text(text, textAlign: TextAlign.center, style: const TextStyle(color: DashColors.muted, fontSize: 15, height: 1.35))]),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.color, required this.bg, required this.icon, required this.text});
  final Color color;
  final Color bg;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: color)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: color, size: 20), const SizedBox(width: 10), Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.3)))]),
  );
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10), child]),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.d, this.now);
  final IncidentDetail d;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final r = d.row;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        UrgencyBadge(r.urgency, large: true),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(headlineOf(r), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              Text('${countsLine(r)} · desde ${clockLabel(r.firstAt)} (${ageLabel(r.firstAt, now)})', style: const TextStyle(fontSize: 13, color: DashColors.muted)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Why extends StatelessWidget {
  const _Why(this.d);
  final IncidentDetail d;

  @override
  Widget build(BuildContext context) {
    final r = d.row;
    return _Section(
      key: const Key('why_section'),
      title: 'Por qué esta prioridad',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.evidence.isEmpty) const Text('Sin señales de riesgo en lo que se ha reportado.', style: TextStyle(color: DashColors.muted)),
          for (final e in d.evidence)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: signalLabel(e.code), style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (e.field != null)
                      TextSpan(text: ' — indicador marcado${e.reportKey == null ? '' : ' en el reporte ${e.reportKey}'}')
                    else
                      TextSpan(text: ' — «${e.quote}» en el texto${e.reportKey == null ? '' : ' del reporte ${e.reportKey}'}'),
                  ],
                ),
                style: const TextStyle(fontSize: 14, height: 1.3),
              ),
            ),
          if (r.uncertainty.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final u in r.uncertainty) Pill(uncertaintyLabel(u), color: DashColors.warn)]),
          ],
          const SizedBox(height: 10),
          const Text('Contradicciones entre reportes: no evaluadas (este análisis no las detecta).', style: TextStyle(fontSize: 13, color: DashColors.muted)),
        ],
      ),
    );
  }
}

class _Observations extends StatelessWidget {
  const _Observations(this.d, this.now);
  final IncidentDetail d;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final extra = d.membersTotal - d.members.length;
    return _Section(
      key: const Key('observations_section'),
      title: 'Observaciones originales (${d.membersTotal})',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in d.members)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: DashColors.surfaceHigh, borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reporte ${m.reportKey} · ${clockLabel(m.capturedAt)}${m.people == 0 ? '' : ' · ${m.peopleLabel} personas'}${m.hasLocation ? '' : ' · sin ubicación'}',
                    style: const TextStyle(fontSize: 12, color: DashColors.muted),
                  ),
                  const SizedBox(height: 4),
                  if (m.text != null) Text('«${m.text}»', style: const TextStyle(fontSize: 15, height: 1.3)) else const Text('Sin texto', style: TextStyle(fontSize: 14, color: DashColors.muted)),
                  if (m.signals.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(m.signals.map(signalLabel).join(' · '), style: const TextStyle(fontSize: 13)),
                  ],
                ],
              ),
            ),
          if (extra > 0) Text('… y $extra más.', style: const TextStyle(color: DashColors.muted)),
        ],
      ),
    );
  }
}

class _Recommendation extends StatelessWidget {
  const _Recommendation({required this.d, required this.onApprove, required this.onReject, required this.now});
  final IncidentDetail d;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final rec = d.recommendation;
    final ap = d.approval;
    final shared = d.row.shared;
    return _Section(
      key: const Key('recommendation_section'),
      title: 'Recomendación',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rec.state == 'informacion_requerida')
            Text('Todavía no se puede recomendar: falta saber ${rec.missing.map(missingLabel).join(' y ')}.', style: const TextStyle(fontSize: 15, height: 1.35))
          else if (rec.state == 'rechazada')
            Text('La propuesta del sistema no pasó la validación y no se muestra como recomendación (${rec.reason ?? 'sin motivo'}).', style: const TextStyle(fontSize: 15, height: 1.35, color: DashColors.warn))
          else ...[
            const Text('Es una propuesta: requiere aprobación humana antes de ejecutarse. El sistema no despacha nada por su cuenta.', style: TextStyle(fontSize: 13, color: DashColors.muted, height: 1.3)),
            const SizedBox(height: 10),
            for (final a in rec.actions) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(actionLabel(a), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
            const SizedBox(height: 6),
            if (rec.resources.isEmpty)
              const Text('Sin recursos disponibles para proponer.', style: TextStyle(color: DashColors.warn))
            else
              for (final r in rec.resources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(children: [const Icon(Icons.local_shipping_outlined, size: 16, color: DashColors.muted), const SizedBox(width: 6), Expanded(child: Text('${r.label} · ${distanceLabel(r.distanceMeters)}', style: const TextStyle(fontSize: 14)))]),
                ),
            if (shared.isNotEmpty)
              for (final s in shared)
                _Notice(
                  key: const Key('shared_warning'),
                  color: DashColors.warn,
                  bg: DashColors.warnBg,
                  icon: Icons.share_location,
                  text: 'El recurso ${s.resourceId} también lo propone ${s.otherIncidents.length == 1 ? 'otro incidente' : '${s.otherIncidents.length} incidentes más'}${s.approvedElsewhere ? ' (ya aprobado en uno de ellos)' : ''}. Decide cuál lo recibe.',
                ),
            if (rec.pending.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Antes de aprobar', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              for (final p in rec.pending) Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.radio_button_unchecked, size: 16, color: DashColors.warn), const SizedBox(width: 6), Expanded(child: Text(pendingLabel(p), style: const TextStyle(fontSize: 14)))])),
            ],
            if (rec.justification.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('En qué se apoya', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              for (final c in rec.justification)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${signalLabel(c.signal)}${c.quote != null ? ' — «${c.quote}»' : (c.field != null && c.signal != 'ubicacion' ? ' — indicador marcado' : '')} (${c.reportKey})',
                    style: const TextStyle(fontSize: 13, color: DashColors.muted),
                  ),
                ),
            ],
          ],
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 6),
          _ApprovalState(ap: ap, now: now),
          if (rec.canDecide) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(key: const Key('approve_button'), onPressed: onApprove, icon: const Icon(Icons.check), label: const Text('Aprobar'), style: FilledButton.styleFrom(backgroundColor: DashColors.ok, foregroundColor: DashColors.bg)),
                const SizedBox(width: 10),
                OutlinedButton.icon(key: const Key('reject_button'), onPressed: onReject, icon: const Icon(Icons.close), label: const Text('Rechazar'), style: OutlinedButton.styleFrom(foregroundColor: DashColors.danger, side: const BorderSide(color: DashColors.danger))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ApprovalState extends StatelessWidget {
  const _ApprovalState({required this.ap, required this.now});
  final ApprovalDetail ap;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final color = switch (ap.status) {
      'aprobada' => DashColors.ok,
      'denegada' => DashColors.danger,
      'caduca' => DashColors.warn,
      _ => DashColors.muted,
    };
    String when(Decision d) => clockLabel(d.atMs ~/ 1000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(key: const Key('approval_status'), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(8)), child: Text(approvalLabel(ap.status), style: TextStyle(fontWeight: FontWeight.w800, color: color))),
        if (ap.discrepancy)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: _Notice(key: Key('discrepancy_banner'), color: DashColors.danger, bg: DashColors.dangerBg, icon: Icons.warning_amber_rounded, text: 'Hay decisiones contradictorias de esta misma versión. Manda el rechazo hasta que alguien las resuelva explícitamente, sustituyendo una de ellas al decidir.'),
          ),
        if (ap.current.isNotEmpty) ...[
          const SizedBox(height: 10),
          Column(
            key: const Key('decisions'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final d in ap.current) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('${d.granted ? 'Aprobó' : 'Rechazó'} ${d.who} · ${when(d)}${d.note.isEmpty ? '' : ' — ${d.note}'}', style: const TextStyle(fontSize: 14)))],
          ),
        ],
        if (ap.stale.isNotEmpty) ...[
          const SizedBox(height: 10),
          Column(
            key: const Key('stale_decisions'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Decisiones de versiones anteriores (ya no valen para lo que se propone ahora)', style: TextStyle(fontSize: 12, color: DashColors.muted)),
              const SizedBox(height: 4),
              for (final d in ap.stale) Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('${d.granted ? 'Aprobó' : 'Rechazó'} ${d.who} · ${when(d)}', style: const TextStyle(fontSize: 13, color: DashColors.muted, decoration: TextDecoration.lineThrough))),
            ],
          ),
        ],
      ],
    );
  }
}

// ───────────────────────────── decidir ─────────────────────────────

sealed class _DecisionOutcome {}

class _Registered extends _DecisionOutcome {
  _Registered(this.who);
  final String who;
}

class _Changed extends _DecisionOutcome {
  _Changed(this.fresh);
  final IncidentDetail fresh;
}

class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({required this.api, required this.seen, required this.granted, required this.who});

  final DashboardApi api;
  final IncidentDetail seen;
  final bool granted;
  final ValueNotifier<String> who;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  late final TextEditingController _who = TextEditingController(text: widget.who.value);
  final TextEditingController _note = TextEditingController();
  final Set<String> _supersede = {};
  bool _sending = false;
  bool _whoMissing = false;
  String? _error;

  @override
  void dispose() {
    _who.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_sending) return;
    final who = _who.text.trim();
    if (who.isEmpty || who.length > 80) {
      setState(() => _whoMissing = true);
      return;
    }
    widget.who.value = who; // se recuerda aunque la decisión no llegue a registrarse (cambió el incidente, falló la red)
    setState(() {
      _sending = true;
      _whoMissing = false;
      _error = null;
    });
    final seen = widget.seen;
    try {
      // Justo antes de registrar se vuelve a leer el incidente: si cambió, la decisión NO se registra
      // sobre una versión que la persona ya no está viendo.
      final fresh = await widget.api.detail(seen.row.id);
      if (fresh.recommendation.id != seen.recommendation.id || !fresh.recommendation.canDecide) {
        if (mounted) Navigator.of(context).pop<_DecisionOutcome>(_Changed(fresh));
        return;
      }
      await widget.api.decide(
        recommendationId: seen.recommendation.id!,
        incidentId: seen.row.id,
        members: seen.row.members.length == seen.membersTotal ? seen.row.members : [for (final m in seen.members) m.reportKey],
        granted: widget.granted,
        who: who,
        note: _note.text.trim(),
        supersedes: [for (final d in seen.approval.current) if (_supersede.contains(d.eventId)) d.eventId],
      );
      if (mounted) Navigator.of(context).pop<_DecisionOutcome>(_Registered(who));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = 'El nodo no aceptó la decisión (${e.status}): ${e.message}. No quedó registrada.');
    } on IncidentGone {
      if (mounted) setState(() => _error = 'Este incidente ya no existe tal como estaba. No se registró nada: cierra y vuelve a abrirlo.');
    } on Object catch (e) {
      final network = e is TimeoutException || e is SocketException || e.toString().contains('ClientException');
      if (mounted) setState(() => _error = network ? 'No se pudo contactar al nodo. La decisión NO quedó registrada: inténtalo de nuevo.' : 'No se pudo registrar la decisión ($e). No quedó registrada.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.seen.recommendation;
    final verb = widget.granted ? 'Aprobar' : 'Rechazar';
    return AlertDialog(
      key: const Key('approval_dialog'),
      title: Text('$verb la recomendación'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rec.actions.map(actionLabel).join(' + '), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (rec.resources.isNotEmpty) Text(rec.resources.map((r) => r.label).join(' · '), style: const TextStyle(fontSize: 13, color: DashColors.muted)),
              const SizedBox(height: 10),
              const Text('Tu decisión queda registrada con tu nombre y con la versión que ves ahora. Aprobar no despacha nada por sí solo.', style: TextStyle(fontSize: 13, height: 1.3)),
              const SizedBox(height: 14),
              TextField(key: const Key('who_field'), controller: _who, enabled: !_sending, decoration: InputDecoration(labelText: 'Tu nombre', errorText: _whoMissing ? 'Escribe tu nombre para registrar la decisión' : null, errorMaxLines: 2)),
              if (_whoMissing) const SizedBox(key: Key('who_error'), height: 0),
              const SizedBox(height: 10),
              TextField(key: const Key('note_field'), controller: _note, enabled: !_sending, maxLength: 280, minLines: 2, maxLines: 3, decoration: const InputDecoration(labelText: 'Nota (opcional)')),
              if (widget.seen.approval.current.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Text('Ya hay una decisión sobre esta versión. Si la tuya la resuelve, márcala para sustituirla:', style: TextStyle(fontSize: 13, color: DashColors.muted)),
                for (final d in widget.seen.approval.current)
                  CheckboxListTile(
                    key: Key('supersede_${d.eventId}'),
                    value: _supersede.contains(d.eventId),
                    onChanged: _sending ? null : (v) => setState(() => v == true ? _supersede.add(d.eventId) : _supersede.remove(d.eventId)),
                    title: Text('Sustituir la decisión de ${d.who} (${d.granted ? 'aprobó' : 'rechazó'})', style: const TextStyle(fontSize: 14)),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, key: const Key('decision_error'), style: const TextStyle(color: DashColors.danger, fontSize: 14, height: 1.3))),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(key: const Key('cancel_decision'), onPressed: _sending ? null : () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(
          key: const Key('confirm_decision'),
          onPressed: _sending ? null : _confirm,
          style: FilledButton.styleFrom(backgroundColor: widget.granted ? DashColors.ok : DashColors.danger, foregroundColor: DashColors.bg),
          child: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(widget.granted ? 'Registrar aprobación' : 'Registrar rechazo'),
        ),
      ],
    );
  }
}
