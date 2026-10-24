import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'reader.dart';
import 'thread.dart';
import 'tokens.dart';

/// Screen timeline: a quiet, local memory of what was on screen, searchable by
/// time and by words. Off until the user turns it on.
class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key, required this.core, required this.run, this.focusQuery});
  final CoreClient core;
  final Run run;

  /// A search the palette handed over: look across all time, not just today.
  final String? focusQuery;
  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  bool _loadFailed = false;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _daybook;
  List<Map<String, dynamic>> _undoable = const [];
  String? _undoBusy;
  List<Map<String, dynamic>>? _moments;
  Map<String, dynamic>? _picked;
  Uint8List? _picture;
  int? _pictureFor;
  String _query = '';
  String _range = 'day';
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _applyFocus();
    _load();
  }

  @override
  void didUpdateWidget(TimelinePage old) {
    super.didUpdateWidget(old);
    if (widget.focusQuery == old.focusQuery || widget.focusQuery == null) return;
    _debounce?.cancel();
    setState(_applyFocus);
    _load();
  }

  void _applyFocus() {
    final query = widget.focusQuery;
    if (query == null) return;
    _query = query;
    _search.text = query;
    _range = 'all';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  bool get _on => _status?['enabled'] == true;
  bool get _paused => _status?['paused'] == true;
  double get _now => DateTime.now().millisecondsSinceEpoch / 1000;

  double? get _after => switch (_range) {
    'hour' => _now - 3600,
    'day' => _now - 86400,
    'week' => _now - 7 * 86400,
    _ => null,
  };

  Future<void> _load() => widget.run(() async {
    if (mounted) setState(() => _loadFailed = false);
    try {
    final status = await widget.core.timelineStatus();
    final moments = await widget.core.timelineMoments(q: _query, after: _after);
    Map<String, dynamic>? book;
    try {
      book = await widget.core.daybook();
    } catch (_) {
      book = null; // the daybook is a bonus; never block the timeline on it
    }
    List<Map<String, dynamic>> undoable = const [];
    try {
      undoable = await widget.core.undoList(hours: 0);
    } catch (_) {
      undoable = const []; // and so is the undo centre
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _moments = moments;
      _daybook = book;
      _undoable = undoable;
      final pickedId = _picked?['id'];
      if (pickedId != null && !moments.any((m) => m['id'] == pickedId)) {
        _picked = null;
        _picture = null;
        _pictureFor = null;
      }
    });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
      rethrow;
    }
  });

  Future<void> _set(Map<String, Object?> changes) async {
    await widget.run(() => widget.core.setTimeline(changes));
    await _load();
  }

  Future<void> _turnOn() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep a quiet memory of your screen?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Compii will take a small look every half a minute and keep the words and a tiny picture, '
                  'so you can ask “what was that error at 3pm?” or “which page had the invoice?” later.'),
              SizedBox(height: 12),
              Text('· Everything stays on this PC. Nothing is uploaded.\n'
                  '· Password managers and private windows are always skipped.\n'
                  '· When screen reading is off, nothing is looked at.\n'
                  '· Older moments delete themselves, and you can forget everything at any time.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Turn on')),
        ],
      ),
    );
    if (ok == true) await _set({'enabled': true});
  }

  Future<void> _resumeSight() async {
    await widget.run(() => widget.core.voiceSettings({'screen_aware': true}));
    await _load();
  }

  Future<void> _pick(Map<String, dynamic> moment) async {
    final id = moment['id'] as int;
    setState(() {
      _picked = moment;
      _picture = null;
      _pictureFor = moment['has_picture'] == true ? id : null;
    });
    if (moment['has_picture'] != true) return;
    try {
      final bytes = await widget.core.timelinePicture(id);
      if (mounted && _picked?['id'] == id) setState(() => _picture = bytes);
    } on Object {
      // no picture is a fine moment too
    }
  }

  Future<void> _open(Map<String, dynamic> moment) async {
    final forget = await showDialog<bool>(
      context: context,
      builder: (context) => _MomentDialog(core: widget.core, id: moment['id'] as int, summary: moment),
    );
    if (forget == true) await _forgetOne(moment);
  }

  Future<void> _forgetOne(Map<String, dynamic> moment) async {
    final id = moment['id'] as int;
    await widget.run(() => widget.core.forgetTimelineMoment(id));
    if (!mounted) return;
    setState(() {
      if (_picked?['id'] == id) {
        _picked = null;
        _picture = null;
        _pictureFor = null;
      }
    });
    await _load();
  }

  Future<void> _forgetHours(double hours) async {
    await widget.run(() => widget.core.forgetTimeline(hours: hours));
    await _load();
  }

  Future<void> _forgetEverything() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget all screen memory?'),
        content: const Text('Every moment and picture in the timeline will be deleted. This can’t be undone, '
            'and Compii won’t be able to answer questions about what was on screen before now.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget everything'),
          ),
        ],
      ),
    );
    if (ok == true) await _forgetHours(0);
  }

  Future<void> _undoDay() async {
    final undo = _daybook?['undo'] as Map?;
    final taskId = '${undo?['task_id'] ?? ''}';
    if (taskId.isEmpty) return;
    var message = '';
    await widget.run(() async {
      message = await widget.core.undo(taskId);
    });
    if (!mounted) return;
    await _load();
    if (message.isNotEmpty) _toast(message);
  }

  Future<void> _undoOne(Map<String, dynamic> action) async {
    final id = '${action['id']}';
    if (id.isEmpty) return;
    setState(() => _undoBusy = id);
    var message = '';
    await widget.run(() async {
      message = await widget.core.undoById(id);
    });
    if (!mounted) return;
    setState(() => _undoBusy = null);
    await _load();
    // Core says what it put back, or why this one can’t be reversed. Either is worth reading.
    if (message.isNotEmpty) _toast(message);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
  bool _dayHasNews(Map<String, dynamic>? book) {
    final counts = book?['counts'] as Map?;
    if (counts == null) return false;
    final n = (counts['done'] as int? ?? 0) +
        (counts['waiting'] as int? ?? 0) +
        (counts['actions'] as int? ?? 0) +
        (counts['apps'] as int? ?? 0);
    return n > 0;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = _status;
    final moments = _moments;
    final anyKept = (st?['moments'] as int? ?? 0) > 0;
    return PageScaffold(
      glyph: G.clock,
      title: 'Timeline',
      subtitle: 'A quiet, private memory of what was on screen — so what you saw is easy to find again.',
      maxWidth: 880,
      trailing: st == null
          ? null
          : Pill(
              !_on ? 'Off' : (_paused ? 'Paused' : 'On'),
              color: !_on ? c.faint : (_paused ? c.warning : c.success),
            ),
      children: [
        if (_loadFailed) LoadFailure(onRetry: _load),
        if (st == null && !_loadFailed)
          const SkeletonCards(rows: 3)
        else if (st != null) ...[
          if (_dayHasNews(_daybook)) ...[
            DaybookCard(book: _daybook!, onUndo: _undoDay),
            const SizedBox(height: 12),
          ],
          if (_undoable.isNotEmpty) ...[
            UndoCentre(actions: _undoable, busyId: _undoBusy, onUndo: _undoOne),
            const SizedBox(height: 12),
          ],
          _statusCard(st),
          if (_on && _paused) ...[const SizedBox(height: 12), _pausedCard()],
          if (_on && st['ocr'] == 'unavailable') ...[const SizedBox(height: 12), _ocrCard()],
          if (_on || anyKept) ...[
            const SizedBox(height: 22),
            _searchField(),
            const SizedBox(height: 10),
            _ranges(),
            const SizedBox(height: 10),
            _scrubber(moments ?? const []),
            if (_picked != null) ...[const SizedBox(height: 10), _detail(_picked!)],
            const SizedBox(height: 24),
            SectionHeader(
              'Moments',
              subtitle: moments == null
                  ? null
                  : _query.isEmpty && _range == 'all'
                      ? '${moments.length} ${moments.length == 1 ? 'moment' : 'moments'} kept'
                      : '${moments.length} found in this range',
              top: 0,
            ),
            _list(moments),
            if (_on) ...[
              const SizedBox(height: 26),
              const SectionHeader('How it keeps things', top: 0),
              _settingsCard(st),
            ],
            const SizedBox(height: 22),
            const SectionHeader('Forget', top: 0),
            _forgetCard(st),
          ] else ...[
            const SizedBox(height: 16),
            _privacyPanel(),
          ],
        ],
      ],
    );
  }

  Widget _statusCard(Map<String, dynamic> st) {
    final c = context.c;
    final moments = st['moments'] as int? ?? 0;
    final mb = (st['megabytes'] as num?)?.toDouble() ?? 0;
    final every = st['every_seconds'] as int? ?? 30;
    return Panel(
      child: Row(
        children: [
          GlyphTile(glyph: G.clock, size: 46, color: _on ? (_paused ? c.warning : c.success) : c.muted),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_on ? (_paused ? 'Paused' : 'Remembering quietly') : 'Screen timeline is off',
                    style: context.type.titleMedium),
                const SizedBox(height: 3),
                Text(
                  _on
                      ? (_paused
                          ? '${st['reason']} Everything already saved is still here.'
                          : 'A look every ${_cadence(every)}, kept for ${_days(st['keep_days'])}. '
                              '$moments ${moments == 1 ? 'moment' : 'moments'} · ${mb.toStringAsFixed(1)} MB. All on this PC.')
                      : 'Compii isn’t looking or remembering. Turn it on if you want the last few days of your screen '
                          'to be searchable — “what was that error at 3pm?”, “which page had the invoice?”.'
                          '${moments == 0 ? '' : ' What was already kept is still below, and you can forget it here.'}',
                  style: context.type.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          if (_on)
            Switch(value: true, onChanged: (_) => _set({'enabled': false}))
          else
            FilledButton(onPressed: _turnOn, child: const Text('Turn on')),
        ],
      ),
    );
  }

  Widget _pausedCard() => Panel(
        borderColor: context.c.warning,
        padding: EdgeInsets.zero,
        child: OptionRow(
          glyph: G.eyeOff,
          title: 'Screen reading is off',
          subtitle: '“Let Compii see your screen” is switched off, so nothing is being remembered.',
          color: context.c.warning,
          trailing: OutlinedButton(onPressed: _resumeSight, child: const Text('Turn screen reading on')),
        ),
      );

  Widget _ocrCard() => Panel(
        borderColor: context.c.warning,
        padding: EdgeInsets.zero,
        child: OptionRow(
          glyph: G.search,
          title: 'Searching the words on screen isn’t available',
          subtitle: 'Windows’ own text reader (OCR) isn’t installed, so only window titles can be searched. '
              'Add its language feature in Windows Settings → Time & language. Pictures still work.',
          color: context.c.warning,
        ),
      );

  Widget _searchField() => TextField(
        controller: _search,
        onChanged: (v) {
          _query = v;
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 350), _load);
        },
        decoration: InputDecoration(
          hintText: 'Search what you saw: an invoice, an error, a page title…',
          prefixIcon: const Padding(padding: EdgeInsets.all(13), child: Glyph(G.search, size: 18)),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Glyph(G.close, size: 16),
                  onPressed: () {
                    _search.clear();
                    _query = '';
                    _debounce?.cancel();
                    _load();
                  },
                ),
        ),
      );

  Widget _ranges() => Wrap(
        spacing: 8,
        children: [
          for (final (key, label) in const [('hour', 'Last hour'), ('day', 'Last 24 hours'), ('week', 'Last 7 days'), ('all', 'All')])
            ChoiceChip(
              label: Text(label),
              selected: _range == key,
              onSelected: (_) {
                if (_range == key) return;
                setState(() => _range = key);
                _load();
              },
            ),
        ],
      );

  Widget _scrubber(List<Map<String, dynamic>> moments) {
    final now = _now;
    var start = _after ?? (moments.isEmpty ? now - 86400 : moments.last['started'] as double);
    final end = now;
    if (start >= end) start = end - 3600;
    return _Scrubber(
      moments: moments,
      start: start,
      end: end,
      selectedId: _picked?['id'] as int?,
      onPick: _pick,
    );
  }

  Widget _detail(Map<String, dynamic> m) {
    final c = context.c;
    final id = m['id'] as int;
    final picture = _pictureFor == id ? _picture : null;
    final loadingPicture = _pictureFor == id && picture == null;
    final excerpt = '${m['excerpt'] ?? ''}'.trim();
    return Panel(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: Shapes.r10,
            child: SizedBox(
              width: 220,
              height: 132,
              child: picture != null
                  ? Image.memory(picture, fit: BoxFit.cover, gaplessPlayback: true)
                  : Container(
                      color: c.sunken,
                      alignment: Alignment.center,
                      child: loadingPicture
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Glyph(G.monitor, size: 26, color: c.faint),
                    ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${m['title']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.titleSmall),
                const SizedBox(height: 4),
                Text('${_spanOf(m)} · ${m['app']}', style: context.type.labelMedium?.copyWith(color: c.muted)),
                if (excerpt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(excerpt, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () => _open(m),
                      icon: const Glyph(G.expand, size: 15),
                      label: const Text('Read it all'),
                    ),
                    TextButton.icon(
                      onPressed: () => _forgetOne(m),
                      icon: const Glyph(G.trash, size: 15),
                      label: const Text('Forget'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(List<Map<String, dynamic>>? moments) {
    final c = context.c;
    if (moments == null) {
      return const SkeletonCards(rows: 3);
    }
    if (moments.isEmpty) {
      return EmptyState(
        glyph: G.clock,
        title: _query.isNotEmpty ? 'Nothing matches “$_query”' : 'Nothing here yet',
        body: _query.isNotEmpty
            ? 'Try fewer words, a wider range, or turn screen memory on a little earlier.'
            : 'Leave the timeline on for a while and what you look at will appear here, newest first.',
        action: _range == 'all'
            ? null
            : OutlinedButton(onPressed: () => setState(() => _range = 'all'), child: const Text('Search all time')),
      );
    }
    return PanelRows(
      children: [
        for (final m in moments)
          Builder(
            builder: (context) {
              final excerpt = '${m['excerpt'] ?? ''}'.trim();
              return Material(
                type: MaterialType.transparency,
                child: ListTile(
                  leading: GlyphTile(
                    glyph: G.monitor,
                    size: 34,
                    color: _picked?['id'] == m['id'] ? c.accent : c.muted,
                  ),
                  title: Text('${m['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodyMedium),
                  subtitle: Text(
                    '${_spanOf(m)} · ${m['app']}${excerpt.isEmpty ? '' : ' — $excerpt'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelMedium,
                  ),
                  trailing: const Glyph(G.chevronRight, size: 16),
                  onTap: () => _open(m),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _settingsCard(Map<String, dynamic> st) {
    final every = st['every_seconds'] as int? ?? 30;
    final days = (st['keep_days'] as num?)?.toDouble() ?? 3;
    final cadences = ({15, 30, 60, 300, every}.toList()..sort());
    final keeps = ({1.0, 3.0, 7.0, 30.0, days}.toList()..sort());
    final moments = st['moments'] as int? ?? 0;
    final mb = (st['megabytes'] as num?)?.toDouble() ?? 0;
    return PanelRows(
      children: [
        OptionRow(
          glyph: G.clock,
          title: 'How often to look',
          subtitle: 'A quick look, then sleep. Shorter is more detailed; longer saves space.',
          trailing: DropdownButton<int>(
            value: every,
            underline: const SizedBox.shrink(),
            items: [
              for (final v in cadences) DropdownMenuItem(value: v, child: Text(_cadence(v))),
            ],
            onChanged: (v) => v == null ? null : _set({'every_seconds': v}),
          ),
        ),
        OptionRow(
          glyph: G.image,
          title: 'Keep a small picture',
          subtitle: 'A thumbnail with each moment, so you recognise the page at a glance. Off keeps only the words.',
          trailing: Switch(
            value: st['pictures'] != false,
            onChanged: (v) => _set({'pictures': v}),
          ),
        ),
        OptionRow(
          glyph: G.broom,
          title: 'Keep for',
          subtitle: '$moments ${moments == 1 ? 'moment' : 'moments'} · ${mb.toStringAsFixed(1)} MB now. '
              'Older ones delete themselves, up to a 200 MB cap.',
          trailing: DropdownButton<double>(
            value: days,
            underline: const SizedBox.shrink(),
            items: [
              for (final v in keeps) DropdownMenuItem(value: v, child: Text(_days(v))),
            ],
            onChanged: (v) => v == null ? null : _set({'keep_days': v}),
          ),
        ),
      ],
    );
  }

  Widget _forgetCard(Map<String, dynamic> st) {
    final c = context.c;
    final any = (st['moments'] as int? ?? 0) > 0;
    return PanelRows(
      children: [
        OptionRow(
          glyph: G.trash,
          title: 'Forget the last hour',
          subtitle: 'Removes only what was recorded in the last 60 minutes.',
          color: c.muted,
          trailing: OutlinedButton(
            onPressed: any ? () => _forgetHours(1) : null,
            child: const Text('Forget hour'),
          ),
        ),
        OptionRow(
          glyph: G.warning,
          title: 'Forget everything',
          subtitle: 'Deletes every moment and picture. This can’t be undone.',
          color: c.danger,
          trailing: OutlinedButton(
            onPressed: any ? _forgetEverything : null,
            child: Text('Forget all', style: context.type.labelLarge?.copyWith(color: c.danger)),
          ),
        ),
      ],
    );
  }

  Widget _privacyPanel() {
    final c = context.c;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What it keeps — and what it never does', style: context.type.titleSmall),
          const SizedBox(height: 12),
          for (final (glyph, title, body) in const [
            (G.lock, 'On this PC only', 'Small pictures and the words on screen are stored locally. Nothing is uploaded.'),
            (G.shieldCheck, 'Skipped on purpose', 'Password managers, private and incognito windows, and anything titled Compii.'),
            (G.eyeOff, 'Paused with screen reading', 'When “Let Compii see your screen” is off, nothing is looked at or remembered.'),
            (G.trash, 'Always deletable', 'Old moments prune themselves; Forget everything removes the rest at once.'),
          ]) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Glyph(glyph, size: 17, color: c.muted),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.type.bodyMedium),
                        Text(body, style: context.type.bodySmall?.copyWith(color: c.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: _turnOn,
            icon: const Glyph(G.clock, size: 16),
            label: const Text('Turn on screen timeline'),
          ),
        ],
      ),
    );
  }
}

/// A horizontal band of the day: a tick for every moment, a knob for the one
/// selected. Dragging maps a position back to the nearest moment.
class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.moments, required this.start, required this.end, required this.selectedId, required this.onPick});
  final List<Map<String, dynamic>> moments;
  final double start;
  final double end;
  final int? selectedId;
  final ValueChanged<Map<String, dynamic>> onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final span = (end - start).clamp(1.0, double.infinity);
    double xOf(double t) => ((t - start) / span).clamp(0.0, 1.0);
    double midOf(Map<String, dynamic> m) => (m['started'] as num).toDouble() + ((m['ended'] as num).toDouble() - (m['started'] as num).toDouble()) / 2;
    final selected = moments.where((m) => m['id'] == selectedId).firstOrNull;
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Column(
        children: [
          SizedBox(
            height: 50,
            child: LayoutBuilder(
              builder: (context, box) {
                void pickAt(Offset p) {
                  if (moments.isEmpty || box.maxWidth <= 0) return;
                  final want = start + span * (p.dx / box.maxWidth).clamp(0.0, 1.0);
                  Map<String, dynamic>? best;
                  var bestDistance = double.infinity;
                  for (final m in moments) {
                    final d = (midOf(m) - want).abs();
                    if (d < bestDistance) {
                      bestDistance = d;
                      best = m;
                    }
                  }
                  if (best != null) onPick(best);
                }

                void step(int delta) {
                  if (moments.isEmpty) return;
                  final ordered = [...moments]..sort((a, b) => (a['started'] as num).compareTo(b['started'] as num));
                  final at = ordered.indexWhere((m) => m['id'] == selectedId);
                  // Nothing highlighted yet: Home and End still mean opposite ends.
                  final to = at < 0 ? (delta < 0 ? 0 : ordered.length - 1) : (at + delta).clamp(0, ordered.length - 1);
                  onPick(ordered[to]);
                }

                return Focus(
                  canRequestFocus: moments.isNotEmpty,
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
                    final k = event.logicalKey;
                    if (k == LogicalKeyboardKey.arrowLeft) {
                      step(-1);
                      return KeyEventResult.handled;
                    }
                    if (k == LogicalKeyboardKey.arrowRight) {
                      step(1);
                      return KeyEventResult.handled;
                    }
                    if (k == LogicalKeyboardKey.home) {
                      step(-moments.length);
                      return KeyEventResult.handled;
                    }
                    if (k == LogicalKeyboardKey.end) {
                      step(moments.length);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Semantics(
                    label: 'Your day, ${moments.length} moments',
                    hint: 'Left and right arrows move between moments',
                    child: Builder(
                      builder: (context) {
                        final focused = Focus.of(context).hasFocus;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => pickAt(d.localPosition),
                          onHorizontalDragUpdate: (d) => pickAt(d.localPosition),
                          child: Stack(
                            children: [
                              CustomPaint(
                                size: Size(box.maxWidth, 50),
                                painter: _TrackPainter(
                                  c: c,
                                  marks: [for (final m in moments) xOf(midOf(m))],
                                  knob: selected == null ? null : xOf(midOf(selected)),
                                ),
                              ),
                              if (focused)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(border: Border.all(color: c.accent, width: 2), borderRadius: Shapes.r10),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(_clockAt(start), style: context.type.labelMedium?.copyWith(color: c.muted)),
              Expanded(
                child: Text(
                  moments.isEmpty ? 'Nothing recorded in this range' : 'Drag to move through your day',
                  textAlign: TextAlign.center,
                  style: context.type.labelMedium?.copyWith(color: c.faint),
                ),
              ),
              Text(_clockAt(end), style: context.type.labelMedium?.copyWith(color: c.muted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({required this.c, required this.marks, this.knob});
  final CompiiColors c;
  final List<double> marks;
  final double? knob;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = Rect.fromLTWH(0, y - 4, size.width, 8);
    final fill = Paint()..color = c.sunken;
    final edge = Paint()
      ..color = c.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final radius = RRect.fromRectAndRadius(track, const Radius.circular(4));
    canvas.drawRRect(radius, fill);
    canvas.drawRRect(radius, edge);

    final mark = Paint()
      ..color = c.accent.withValues(alpha: .55)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final x in marks) {
      final at = x * size.width;
      canvas.drawLine(Offset(at, y - 11), Offset(at, y + 11), mark);
    }

    final k = knob;
    if (k != null) {
      final at = Offset(k * size.width, y);
      canvas.drawCircle(at, 11, Paint()..color = c.accent.withValues(alpha: .18));
      canvas.drawCircle(at, 7.5, Paint()..color = c.accent);
      canvas.drawCircle(at, 3, Paint()..color = c.onAccent);
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.knob != knob || old.c != c || old.marks.length != marks.length || !_sameMarks(old.marks, marks);

  bool _sameMarks(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > .0001) return false;
    }
    return true;
  }
}

/// One moment, whole: the picture (if kept), the words that were on screen,
/// and a way to forget just this one.
class _MomentDialog extends StatefulWidget {
  const _MomentDialog({required this.core, required this.id, required this.summary});
  final CoreClient core;
  final int id;
  final Map<String, dynamic> summary;
  @override
  State<_MomentDialog> createState() => _MomentDialogState();
}

class _MomentDialogState extends State<_MomentDialog> {
  Map<String, dynamic>? _full;
  Uint8List? _picture;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final full = await widget.core.timelineMoment(widget.id);
      Uint8List? picture;
      if (full['has_picture'] == true) {
        try {
          picture = await widget.core.timelinePicture(widget.id);
        } on Object {
          // a missing picture isn't a failure to show the moment
        }
      }
      if (!mounted) return;
      setState(() {
        _full = full;
        _picture = picture;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = _full ?? widget.summary;
    final text = '${m['text'] ?? ''}'.trim();
    return Dialog(
      backgroundColor: c.raised,
      shape: const RoundedRectangleBorder(borderRadius: Shapes.r20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const GlyphTile(glyph: G.clock, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${m['title']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.titleMedium),
                        Text('${_spanOf(m)} · ${m['app']}', style: context.type.labelMedium?.copyWith(color: c.muted)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Glyph(G.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_picture != null) ...[
                ClipRRect(
                  borderRadius: Shapes.r12,
                  child: Image.memory(_picture!, fit: BoxFit.contain, height: 300, width: double.infinity),
                ),
                const SizedBox(height: 14),
              ],
              Flexible(
                child: SingleChildScrollView(
                  child: _loading
                      ? const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
                      : SelectableText(
                          _error ?? (text.isEmpty ? 'No words were read from this moment — the picture is all Compii saw.' : text),
                          style: context.type.bodySmall,
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Only on this PC.', style: context.type.labelMedium?.copyWith(color: c.faint)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Glyph(G.trash, size: 16),
                    label: const Text('Forget this moment'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Done')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String _clockAt(double seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  return '${_two(t.hour)}:${_two(t.minute)}';
}

String _dayOf(double seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  final now = DateTime.now();
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${day.day} ${months[day.month - 1]}';
}

String _spanOf(Map<String, dynamic> m) {
  final a = (m['started'] as num).toDouble();
  final b = (m['ended'] as num).toDouble();
  final day = _dayOf(a);
  return b - a < 60 ? '$day ${_clockAt(a)}' : '$day ${_clockAt(a)}–${_clockAt(b)}';
}

String _cadence(int seconds) {
  if (seconds < 60) return '$seconds sec';
  final minutes = seconds / 60;
  return minutes == minutes.roundToDouble() ? '${minutes.round()} min' : '$seconds sec';
}

String _days(num? days) {
  final d = (days ?? 3).toDouble();
  return '${d == d.roundToDouble() ? d.round() : d} ${d == 1 ? 'day' : 'days'}';
}

/// The undo centre: every change Compii made that it can still put back, newest first.
/// Display only — the page holds the state and calls Core, so this stays testable
/// without a live client.
class UndoCentre extends StatelessWidget {
  const UndoCentre({super.key, required this.actions, required this.onUndo, this.busyId});
  final List<Map<String, dynamic>> actions;
  final Future<void> Function(Map<String, dynamic> action) onUndo;

  /// The row being put back right now; its button shows a spinner and nothing else is clickable.
  final String? busyId;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          'Put things back',
          subtitle: 'Only what Compii itself changed, and only the last change of each conversation — '
              'pulling out an earlier one would break what came after it. Nothing moves until you click.',
        ),
        PanelRows(
          children: [
            for (final a in actions)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GlyphTile(glyph: G.undo, size: 34, color: c.accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${a['summary']}', style: context.type.bodySmall),
                          const SizedBox(height: 4),
                          Text(
                            _lineage(a),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.bodySmall?.copyWith(color: c.faint),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    TextButton.icon(
                      onPressed: busyId == null ? () => onUndo(a) : null,
                      icon: busyId == '${a['id']}'
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Glyph(G.undo, size: 16),
                      label: Text(_verb(a)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// A move goes back where it came from; a file Compii made is taken away again (Core keeps a copy).
  static String _verb(Map<String, dynamic> action) =>
      '${(action['what'] as Map?)?['op'] ?? ''}' == 'created' ? 'Remove it' : 'Move it back';

  static String _lineage(Map<String, dynamic> action) {
    final at = (action['at'] as num?)?.toDouble() ?? 0;
    final when = '${_dayOf(at)} ${_clockAt(at)}';
    final about = '${action['about'] ?? ''}'.trim();
    return about.isEmpty ? when : '$when · asked as “$about”';
  }
}

/// The day so far, straight from what this PC already keeps: tasks finished,
/// what Compii did, and where you left off. The full day opens in the reader.
class DaybookCard extends StatelessWidget {
  const DaybookCard({super.key, required this.book, this.onUndo});
  final Map<String, dynamic> book;
  final Future<void> Function()? onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final left = book['left_off'] as Map?;
    final undo = book['undo'] as Map?;
    final request = '${left?['request'] ?? ''}'.trim();
    final last = '${left?['last'] ?? ''}'.trim();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphTile(glyph: G.sun, size: 46, color: c.accent),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Catch me up', style: context.type.titleMedium),
                    const SizedBox(height: 3),
                    Text('${book['headline']}', style: context.type.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: () => showAnswerReader(
                  context,
                  text: '${book['markdown']}',
                  title: 'Your day',
                  subtitle: 'Tasks, actions and screen moments kept on this PC',
                ),
                icon: const Glyph(G.file, size: 16),
                label: const Text('Read the day'),
              ),
            ],
          ),
          if (request.isNotEmpty || last.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Glyph(G.clock, size: 16, color: c.muted),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        const TextSpan(text: 'Where you left off: '),
                        if (request.isNotEmpty)
                          TextSpan(
                            text: request,
                            style: TextStyle(color: c.text, fontWeight: FontWeight.w600),
                          ),
                        if (request.isNotEmpty && last.isNotEmpty) const TextSpan(text: ' — '),
                        if (last.isNotEmpty) TextSpan(text: last),
                      ]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.bodySmall?.copyWith(color: c.muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (undo != null && onUndo != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${undo['summary']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelMedium?.copyWith(color: c.muted),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => onUndo!(),
                  icon: const Glyph(G.undo, size: 16),
                  label: const Text('Undo'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
