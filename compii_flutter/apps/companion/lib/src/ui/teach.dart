import 'dart:async';

import 'package:flutter/material.dart';

import 'chrome.dart';
import 'glyphs.dart';
import 'tokens.dart';
import 'trust.dart' show TrustApi;

/// Teach a task by demonstrating it once, review what Compii saw, then keep it
/// as a skill — optionally on a schedule, owned by one of the user's bots.
///
/// Returns the saved skill's name, or null when nothing was saved.
Future<String?> showTeachDialog(BuildContext context, {String? botId}) => showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TeachDialog(botId: botId),
    );

class _TeachDialog extends StatefulWidget {
  const _TeachDialog({this.botId});
  final String? botId;

  @override
  State<_TeachDialog> createState() => _TeachDialogState();
}

class _TeachDialogState extends State<_TeachDialog> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  Timer? _poll;
  Map<String, dynamic>? _draft;
  List<Map<String, dynamic>> _bots = [];
  String? _botId;
  String? _error;
  bool _busy = true;
  bool _saving = false;
  int _seconds = 0;
  List<String> _steps = [];
  List<String> _liveKinds = [];

  // Review: which recorded steps to keep.
  List<String> _kinds = [];
  Set<int> _keep = {};

  // Schedule choices for the review step.
  bool _schedule = false;
  String _kind = 'weekdays';
  TimeOfDay _at = const TimeOfDay(hour: 8, minute: 0);
  final Set<String> _days = {'mon'};

  bool get _reviewing => _draft != null;

  @override
  void initState() {
    super.initState();
    _botId = widget.botId;
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final statusFuture = TrustApi.teachStart();
      final botsFuture = TrustApi.call('GET', '/bots');
      final status = Map<String, dynamic>.from(await statusFuture);
      final botView = Map<String, dynamic>.from(await botsFuture as Map);
      final bots = [for (final b in botView['bots'] as List) Map<String, dynamic>.from(b as Map)];
      if (!mounted) return;
      setState(() {
        _bots = bots;
        _botId ??= botView['primary'] as String? ?? (bots.isEmpty ? null : '${bots.first['id']}');
        _steps = [for (final s in status['steps'] as List? ?? const []) '$s'];
        _liveKinds = _kindsOf(status);
        _seconds = status['seconds'] as int? ?? 0;
        _busy = false;
      });
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _tick() async {
    if (!mounted || _reviewing) return;
    try {
      final s = await TrustApi.teachStatus();
      if (!mounted) return;
      setState(() {
        _steps = [for (final x in s['steps'] as List? ?? const []) '$x'];
        _liveKinds = _kindsOf(s);
        _seconds = s['seconds'] as int? ?? _seconds;
      });
    } catch (_) {}
  }

  Future<void> _done() async {
    setState(() => _busy = true);
    try {
      final d = await TrustApi.teachStop();
      _poll?.cancel();
      if (!mounted) return;
      setState(() {
        _draft = d;
        _name.text = '${d['name'] ?? ''}';
        _steps = [for (final s in d['steps'] as List? ?? const []) '$s'];
        _kinds = _kindsOf(d);
        _keep = {for (var i = 0; i < _steps.length; i++) i};
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  static List<String> _kindsOf(Map<String, dynamic> view) =>
      [for (final a in view['actions'] as List? ?? const []) '${(a as Map)['kind'] ?? ''}'];

  List<int> get _kept => _keep.toList()..sort();

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give it a name first.');
      return;
    }
    final keep = _kept;
    if (keep.isEmpty) {
      setState(() => _error = 'Keep at least one step.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final hm = '${_at.hour.toString().padLeft(2, '0')}:${_at.minute.toString().padLeft(2, '0')}';
    try {
      await TrustApi.teachSave(
        name: name,
        about: _about.text.trim(),
        botId: _schedule ? _botId : null,
        keep: keep,
        schedule: _schedule
            ? {'kind': _kind, 'at': hm, if (_kind == 'weekly') 'days': _days.toList()}
            : null,
      );
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  Future<void> _cancel() async {
    _poll?.cancel();
    if (!_reviewing) {
      try {
        await TrustApi.teachCancel();
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: Row(
        children: [
          GlyphTile(glyph: _reviewing ? G.skill : G.eye, size: 34, color: c.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(_reviewing ? 'Review what I saw' : 'Teach me a task')),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: _reviewing ? _review(context) : _record(context),
        ),
      ),
      actions: _reviewing
          ? [
              TextButton(onPressed: _saving ? null : _cancel, child: const Text('Discard')),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save skill'),
              ),
            ]
          : [
              TextButton(onPressed: _busy && _steps.isEmpty ? null : _cancel, child: const Text('Cancel')),
              FilledButton(
                onPressed: _busy ? null : _done,
                child: const Text('Done — show me the steps'),
              ),
            ],
    );
  }

  Widget _record(BuildContext context) {
    final c = context.c;
    final mm = (_seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (_seconds % 60).toString().padLeft(2, '0');
    final first = _steps.length > 6 ? _steps.length - 6 : 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Show me the task in any app. I write down what you click (by name), the shortcuts you press and the '
          'windows you switch to. What you type is never recorded.',
          style: context.type.bodySmall?.copyWith(color: c.muted),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: c.accentSoft,
            borderRadius: Shapes.r14,
            border: Border.all(color: c.accent.withValues(alpha: .35)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _busy && _steps.isEmpty ? 'Starting to watch…' : 'Watching · $mm:$ss · ${_steps.length} steps',
                  style: context.type.titleSmall,
                ),
              ),
              Text('up to 10 min', style: context.type.labelMedium?.copyWith(color: c.faint)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_steps.isEmpty)
          Text(
            'Nothing yet. Switch to the app you want to teach and do it once, step by step. When you come back here '
            'and press Done, the last click on Compii is ignored.',
            style: context.type.bodySmall?.copyWith(color: c.faint),
          )
        else
          for (final (i, step) in _steps.skip(first).indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text('${first + i + 1}. ',
                        style: context.type.bodySmall?.copyWith(color: c.faint)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Glyph(_kindGlyph(first + i < _liveKinds.length ? _liveKinds[first + i] : ''),
                        size: 13, color: c.accent),
                  ),
                  const SizedBox(width: 7),
                  Expanded(child: Text(step, style: context.type.bodySmall)),
                ],
              ),
            ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
        ],
      ],
    );
  }

  Widget _review(BuildContext context) {
    final c = context.c;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'Sort invoices by month'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _about,
          decoration: const InputDecoration(
            labelText: 'What it is for (optional)',
            hintText: 'Files new invoices into the right month folder.',
          ),
        ),
        const SizedBox(height: 16),
        TeachSteps(
          steps: _steps,
          kinds: _kinds,
          tester: (keep) async {
            final r = await TrustApi.teachCheck(keep: keep);
            return [for (final x in r['checks'] as List? ?? const []) Map<String, dynamic>.from(x as Map)];
          },
          onKeepChanged: (keep) => _keep = keep.toSet(),
        ),
        const SizedBox(height: 7),
        Text(
          'Testing only looks, it never clicks or types. Words you type are never recorded, so Compii asks for them when it runs.',
          style: context.type.bodySmall?.copyWith(color: c.faint),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _schedule,
          onChanged: (on) => setState(() => _schedule = on),
          title: const Text('Also run it on its own'),
          subtitle: Text(
            _schedule ? 'It will run as the teammate below.' : 'You can add a schedule later in Routines.',
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
        ),
        if (_schedule) ...[
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'daily', label: Text('Every day')),
              ButtonSegment(value: 'weekdays', label: Text('Weekdays')),
              ButtonSegment(value: 'weekly', label: Text('Some days')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          if (_kind == 'weekly') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final d in const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'])
                  FilterChip(
                    label: Text(d[0].toUpperCase() + d.substring(1)),
                    selected: _days.contains(d),
                    onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  final t = await showTimePicker(context: context, initialTime: _at);
                  if (t != null) setState(() => _at = t);
                },
                icon: const Glyph(G.clock),
                label: Text('At ${_at.hour.toString().padLeft(2, '0')}:${_at.minute.toString().padLeft(2, '0')}'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _bots.any((b) => b['id'] == _botId) ? _botId : null,
                  hint: const Text('Who runs it'),
                  items: [
                    for (final b in _bots)
                      DropdownMenuItem(value: '${b['id']}', child: Text('${b['name']}')),
                  ],
                  onChanged: (v) => setState(() => _botId = v),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
        ],
      ],
    );
  }
}

class TeachSteps extends StatefulWidget {
  const TeachSteps({
    super.key,
    required this.steps,
    this.kinds = const [],
    this.tester,
    this.initialKeep,
    this.onKeepChanged,
  });
  final List<String> steps;
  final List<String> kinds;

  /// Looks (never acts) at the kept steps and says which are reachable.
  final Future<List<Map<String, dynamic>>> Function(List<int> keep)? tester;
  final Set<int>? initialKeep;
  final void Function(List<int> keep)? onKeepChanged;

  @override
  State<TeachSteps> createState() => _TeachStepsState();
}

class _TeachStepsState extends State<TeachSteps> {
  late Set<int> _keep = widget.initialKeep ?? {for (var i = 0; i < widget.steps.length; i++) i};
  Map<int, Map<String, dynamic>> _checks = {};
  bool _testing = false;
  bool _tested = false;
  String? _error;

  List<int> get _kept => _keep.toList()..sort();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onKeepChanged?.call(_kept));
  }

  void _toggle(int i, bool on) {
    setState(() {
      on ? _keep.add(i) : _keep.remove(i);
      _checks = {};
      _tested = false;
    });
    widget.onKeepChanged?.call(_kept);
  }

  Future<void> _test() async {
    final keep = _kept;
    final tester = widget.tester;
    if (keep.isEmpty) {
      setState(() => _error = 'Keep at least one step to test.');
      return;
    }
    if (tester == null) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final checks = await tester(keep);
      if (!mounted) return;
      setState(() {
        _checks = {for (final (i, c) in checks.indexed) if (i < keep.length) keep[i]: c};
        _testing = false;
        _tested = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final failed = _checks.values.where((x) => x['ok'] != true).length;
    final allKept = _keep.length == widget.steps.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('STEPS', style: context.type.labelSmall),
            const SizedBox(width: 8),
            Text('${_keep.length} of ${widget.steps.length} kept',
                style: context.type.bodySmall?.copyWith(color: c.faint)),
            const Spacer(),
            if (!allKept)
              TextButton(
                onPressed: () {
                  setState(() {
                    _keep = {for (var i = 0; i < widget.steps.length; i++) i};
                    _checks = {};
                    _tested = false;
                  });
                  widget.onKeepChanged?.call(_kept);
                },
                child: const Text('Keep all'),
              ),
            TextButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.8))
                  : const Glyph(G.search, size: 15),
              label: Text(_testing ? 'Looking…' : 'Test'),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Container(
          decoration: BoxDecoration(
            color: c.sunken,
            borderRadius: Shapes.r12,
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              for (final (i, step) in widget.steps.indexed) ...[
                if (i > 0) Divider(height: 1, color: c.border),
                _StepRow(
                  step: step,
                  kind: i < widget.kinds.length ? widget.kinds[i] : '',
                  kept: _keep.contains(i),
                  check: _checks[i],
                  onToggle: (on) => _toggle(i, on),
                ),
              ],
            ],
          ),
        ),
        if (_tested) ...[
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Glyph(failed == 0 ? G.checkCircle : G.alert,
                    size: 15, color: failed == 0 ? c.success : c.warning),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  failed == 0
                      ? 'Every kept step can be found on screen right now.'
                      : '$failed step${failed == 1 ? '' : 's'} can’t be found right now. You can still save, but check ${failed == 1 ? 'it' : 'them'} when the app is open.',
                  style: context.type.bodySmall?.copyWith(color: failed == 0 ? c.success : c.warning),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
        ],
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.kind, required this.kept, required this.onToggle, this.check});
  final String step;
  final String kind;
  final bool kept;
  final void Function(bool on) onToggle;
  final Map<String, dynamic>? check;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final result = check;
    final ok = result?['ok'] == true;
    return InkWell(
      onTap: () => onToggle(!kept),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: kept,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => onToggle(v == true),
            ),
            const SizedBox(width: 2),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Glyph(_kindGlyph(kind), size: 15, color: kept ? c.accent : c.faint),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step,
                      style: context.type.bodySmall?.copyWith(
                        color: kept ? c.text : c.faint,
                        decoration: kept ? null : TextDecoration.lineThrough,
                        height: 1.35,
                      ),
                    ),
                    if (result != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Glyph(ok ? G.checkCircle : G.alert,
                                size: 12, color: ok ? c.success : c.warning),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text('${result['detail']}',
                                style: context.type.labelSmall?.copyWith(color: ok ? c.muted : c.warning)),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

GlyphData _kindGlyph(String kind) => switch (kind) {
      'click' => G.hand,
      'type' => G.keyboard,
      'keys' => G.bolt,
      'switch' => G.monitor,
      _ => G.dot,
    };
