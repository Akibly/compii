import 'dart:async';

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'teach.dart' show showTeachDialog;
import 'reader.dart';
import 'thread.dart';
import 'tokens.dart';
import 'chrome.dart';
import 'glyphs.dart';

/// Loads Compii's routines, watches, brief settings and inbox, and reloads
/// when something new arrives.
class _Plans extends StatefulWidget {
  const _Plans({required this.core, required this.run, required this.builder, this.quiet = false});

  /// Show nothing (instead of a spinner) until loaded.
  final bool quiet;
  final CoreClient core;
  final Run run;
  final Widget Function(BuildContext, Map<String, dynamic>, void Function(Map<String, dynamic>), VoidCallback?) builder;
  @override
  State<_Plans> createState() => _PlansState();
}

class _PlansState extends State<_Plans> {
  Map<String, dynamic>? _v;
  StreamSubscription<Map<String, dynamic>>? _sub;
  CoreStatus _last = CoreStatus.connecting;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _v = widget.core.plansCache;
    _load();
    _sub = widget.core.updates.stream.listen((_) => _load());
    widget.core.addListener(_onCore);
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.core.removeListener(_onCore);
    super.dispose();
  }

  /// Reload once Core is reachable again (e.g. the app started first).
  void _onCore() {
    final now = widget.core.status;
    if (now == CoreStatus.online && _last != CoreStatus.online) _load();
    _last = now;
  }

  /// Background load: keeps the last good view, and a failure gets a retry.
  Future<void> _load() async {
    try {
      final v = await widget.core.proactive();
      if (mounted) setState(() { _v = v; _loadFailed = false; });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  void _set(Map<String, dynamic> v) {
    if (mounted) setState(() => _v = v);
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    if (v == null) {
      if (widget.quiet) return const SizedBox.shrink();
      if (_loadFailed) return Center(child: LoadFailure(onRetry: _load));
      return const Center(child: CircularProgressIndicator());
    }
    return widget.builder(context, v, _set, _loadFailed ? _load : null);
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.subtitle, required this.children, this.action});
  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => PageScaffold(
    glyph: pageGlyph(title),
    title: title,
    subtitle: subtitle,
    trailing: action,
    children: children,
  );
}

/// Core's scheduled loop stopped: say so plainly instead of listing times
/// that will quietly never fire.
class _Offline extends StatelessWidget {
  const _Offline({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final why = error.length > 140 ? '${error.substring(0, 140)}…' : error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.warningSoft,
        borderRadius: Shapes.r14,
        border: Border.all(color: c.warning.withValues(alpha: .4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Glyph(G.warning, size: 20, color: c.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nothing is firing right now', style: context.type.titleSmall),
                const SizedBox(height: 3),
                Text(
                  'Compii stopped checking its schedule, so the routines and watches below will not happen until Core is restarted. Reason: $why',
                  style: context.type.bodySmall?.copyWith(color: c.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _ago(Object? at) {
  if (at == null) return 'never';
  final when = at is num ? DateTime.fromMillisecondsSinceEpoch((at * 1000).round()) : DateTime.tryParse('$at');
  if (when == null) return '';
  final d = DateTime.now().difference(when);
  if (d.isNegative) {
    final ahead = -d;
    if (ahead.inMinutes < 60) return 'in ${ahead.inMinutes + 1} min';
    if (ahead.inHours < 24) return 'today ${_hm(when)}';
    return '${_day(when)} ${_hm(when)}';
  }
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String _day(DateTime t) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1];

/// Routines (scheduled), watches (tell me when) and the daily brief.
class RoutinesPage extends StatelessWidget {
  const RoutinesPage({super.key, required this.core, required this.run, this.onOpenTask, this.focusId});
  final CoreClient core;
  final Run run;
  final void Function(String taskId)? onOpenTask;

  /// A routine search found; its studio opens once the page has data.
  final String? focusId;

  @override
  Widget build(BuildContext context) => _Plans(
    core: core,
    run: run,
    builder: (context, v, set, retry) {
      final c = context.c;
      final brief = Map<String, dynamic>.from(v['brief'] as Map);
      final error = v['error'] as String?;
      final routines = [for (final r in v['routines'] as List) Map<String, dynamic>.from(r as Map)];
      final watches = [for (final w in v['watches'] as List) Map<String, dynamic>.from(w as Map)];
      final notices = [
        for (final n in (v['suggestions'] as List? ?? const [])) Map<String, dynamic>.from(n as Map)
      ];
      Future<void> apply(Future<Map<String, dynamic>> Function() f) => run(() async => set(await f()));

      return _Page(
        title: 'Routines',
        subtitle: 'Things Compii does on its own schedule, and things it keeps an eye on for you. You can also just ask: “every Friday at 5, tidy my Downloads”.',
        children: [
          _OpenRoutine(
            focusId: focusId,
            routines: routines,
            onOpen: (r) => showRoutineStudio(context, core: core, set: set, routine: r, run: run, onOpenTask: onOpenTask),
          ),
          if (retry != null) LoadFailure(onRetry: retry),
          if (error != null) ...[_Offline(error: error), const SizedBox(height: 14)],
          if (notices.isNotEmpty) ...[
            SectionHeader(
              'Compii has noticed',
              subtitle: 'Counted from the conversations saved on this PC. Nothing is scheduled or saved '
                  'until you answer.',
            ),
            PanelRows(children: [for (final n in notices) _HabitCard(core: core, suggestion: n, set: set)]),
            const SizedBox(height: 22),
          ],
          Text('Daily brief', style: context.type.titleLarge),
          const SizedBox(height: 10),
          PanelRows(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    GlyphTile(glyph: G.sun, size: 34, color: c.accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Morning brief', style: context.type.titleSmall),
                          Text('What needs you, what got done, what your watches caught, what’s on today. Free, made on this PC.',
                              style: context.type.bodySmall),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final t = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay(
                            hour: int.parse('${brief['at']}'.split(':')[0]),
                            minute: int.parse('${brief['at']}'.split(':')[1]),
                          ),
                        );
                        if (t != null) {
                          await apply(() => core.briefSettings(at: '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'));
                        }
                      },
                      child: Text('${brief['at']}'),
                    ),
                    Switch(value: brief['enabled'] == true, onChanged: (on) => apply(() => core.briefSettings(enabled: on))),
                    IconButton(
                      tooltip: 'Brief me now',
                      onPressed: () => run(core.briefNow),
                      icon: const Glyph(G.play),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('Work journal', style: context.type.titleLarge),
          const SizedBox(height: 10),
          PanelRows(children: [_JournalCard(core: core, set: set, view: v)]),
          const SizedBox(height: 28),
          if (routines.isNotEmpty) ...[
            _WeekAhead(
              core: core,
              routines: routines,
              onOpen: (r) => showRoutineStudio(context, core: core, set: set, routine: r, run: run, onOpenTask: onOpenTask),
            ),
            const SizedBox(height: 28),
          ],
          Row(
            children: [
              Expanded(child: Text('Scheduled', style: context.type.titleLarge)),
              OutlinedButton.icon(
                onPressed: () async {
                  final name = await showTeachDialog(context);
                  if (name != null) await apply(() => core.proactive());
                },
                icon: const Glyph(G.eye, size: 18),
                label: const Text('Teach a task'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => showRoutineEditor(context, core: core, set: set),
                icon: const Glyph(G.plus, size: 18),
                label: const Text('New routine'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (routines.isEmpty)
            _Starters(core: core, set: set)
          else
            PanelRows(
              children: [
                for (final r in routines)
                  _RoutineTile(
                    core: core,
                    routine: r,
                    run: run,
                    set: set,
                    onOpen: () => showRoutineStudio(context, core: core, set: set, routine: r, run: run, onOpenTask: onOpenTask),
                  ),
              ],
            ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: Text('Watching', style: context.type.titleLarge)),
              OutlinedButton.icon(
                onPressed: () => _newWatch(context, core, run, set),
                icon: const Glyph(G.plus, size: 18),
                label: const Text('New watch'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (watches.isEmpty)
            const EmptyState(
              glyph: G.eye,
              title: 'Nothing watched yet.',
              body: 'Try: “Tell me when an invoice lands in Downloads.”',
            )
          else
            PanelRows(
              children: [
                for (final w in watches)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        GlyphTile(glyph: switch ('${w['kind']}') {
                          'folder' => G.folder,
                          'web' => G.globe,
                          _ => G.memory,
                        }, size: 34, color: w['enabled'] == true ? c.accent : c.faint),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${w['title']}', style: context.type.titleSmall),
                              Text(
                                '${_watchWhat(w)} · every ${w['every_minutes']} min · ${w['kind'] == 'ai' ? 'uses Claude' : 'free'}'
                                '${w['last_triggered'] != null ? ' · last caught ${_ago(w['last_triggered'])}' : ''}',
                                style: context.type.bodySmall,
                              ),
                              if (w['error'] != null)
                                Text('${w['error']}', style: context.type.bodySmall?.copyWith(color: c.danger)),
                            ],
                          ),
                        ),
                        Switch(value: w['enabled'] == true, onChanged: (on) => apply(() => core.setEnabled('${w['id']}', on))),
                        IconButton(tooltip: 'Delete', onPressed: () => apply(() => core.removePlan('${w['id']}')), icon: const Glyph(G.trash)),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );
}

/// The work journal, shown from what Core reports: the hour it writes, a switch,
/// and every day it has already written down.
class JournalCard extends StatelessWidget {
  const JournalCard({
    super.key,
    required this.settings,
    required this.days,
    required this.folder,
    required this.onToggle,
    required this.onAt,
    required this.onNow,
    required this.onRead,
    this.busy = false,
    this.error,
  });

  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> days;
  final String folder;
  final void Function(bool on) onToggle;
  final VoidCallback onAt;
  final VoidCallback onNow;
  final void Function(Map<String, dynamic> day) onRead;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = settings['enabled'] == true;
    final at = '${settings['at'] ?? '21:00'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlyphTile(glyph: G.note, size: 34, color: on ? c.accent : c.faint),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Every day, written down', style: context.type.titleSmall),
                    Text(
                      on
                          ? 'When a day closes, Compii saves it as a plain text file. Months later you can still ask what you were doing that week.'
                          : 'Off. Turning it on makes Compii keep a plain text file of each day that closes, on this PC only.',
                      style: context.type.bodySmall?.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: busy ? null : onAt, child: Text(at)),
              Switch(value: on, onChanged: busy ? null : onToggle),
              IconButton(
                tooltip: 'Write yesterday now',
                onPressed: busy ? null : onNow,
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Glyph(G.play),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (days.isEmpty)
            Text(
              on
                  ? 'Nothing is written down yet. The first file appears once the next day closes at $at.'
                  : 'Nothing is written down yet.',
              style: context.type.bodySmall?.copyWith(color: c.faint),
            )
          else
            for (final d in days)
              InkWell(
                borderRadius: Shapes.r12,
                onTap: busy ? null : () => onRead(d),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(padding: const EdgeInsets.only(top: 4), child: Glyph(G.doc, size: 15, color: c.faint)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${d['title']}',
                                style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                            Text('${d['lead']}', style: context.type.bodySmall?.copyWith(color: c.muted)),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Glyph(G.chevronRight, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
          if (folder.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Saved in $folder', style: context.type.bodySmall?.copyWith(color: c.faint)),
          ],
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
          ],
        ],
      ),
    );
  }
}

/// The same card, wired to Core: switching it on is the only way a day ever gets
/// written, so the file stays the user's decision, not a default.
class _JournalCard extends StatefulWidget {
  const _JournalCard({required this.core, required this.set, required this.view});
  final CoreClient core;
  final void Function(Map<String, dynamic>) set;
  final Map<String, dynamic> view;

  @override
  State<_JournalCard> createState() => _JournalCardState();
}

class _JournalCardState extends State<_JournalCard> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<Map<String, dynamic>> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.set(await action());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime() async {
    final parts = '${widget.view['journal']?['at'] ?? '21:00'}'.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked == null) return;
    final at = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    await _act(() => widget.core.journalSettings(at: at));
  }

  Future<void> _read(Map<String, dynamic> day) async {
    try {
      final text = await widget.core.journalDay('${day['date']}');
      if (!mounted) return;
      showAnswerReader(context, text: text, title: '${day['title']}', subtitle: 'Compii’s journal for that day');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => JournalCard(
        settings: Map<String, dynamic>.from(widget.view['journal'] as Map? ?? const {}),
        days: [for (final d in (widget.view['days'] as List? ?? const [])) Map<String, dynamic>.from(d as Map)],
        folder: '${widget.view['folder'] ?? ''}',
        busy: _busy,
        error: _error,
        onToggle: (on) => _act(() => widget.core.journalSettings(enabled: on)),
        onAt: _pickTime,
        onNow: () => _act(widget.core.journalNow),
        onRead: _read,
      );
}

/// Opens one routine's studio once, when search brought the user straight to it.
class _OpenRoutine extends StatefulWidget {
  const _OpenRoutine({required this.focusId, required this.routines, required this.onOpen});
  final String? focusId;
  final List<Map<String, dynamic>> routines;
  final void Function(Map<String, dynamic>) onOpen;
  @override
  State<_OpenRoutine> createState() => _OpenRoutineState();
}

class _OpenRoutineState extends State<_OpenRoutine> {
  String? _opened;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_OpenRoutine old) {
    super.didUpdateWidget(old);
    if (widget.focusId != old.focusId) _opened = null;
    _schedule();
  }

  void _schedule() {
    final id = widget.focusId;
    if (id == null || id == _opened) return;
    Map<String, dynamic>? match;
    for (final r in widget.routines) {
      if ('${r['id']}' == id) {
        match = r;
        break;
      }
    }
    if (match == null) return;
    _opened = id;
    final found = match;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onOpen(found);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

String _watchWhat(Map<String, dynamic> w) {
  final spec = Map<String, dynamic>.from(w['spec'] as Map);
  return switch ('${w['kind']}') {
    'folder' => 'New ${spec['pattern'] ?? 'files'} in ${'${spec['folder']}'.split(RegExp(r'[\\/]')).last}',
    'web' => spec['contains'] != null ? '“${spec['contains']}” on ${Uri.tryParse('${spec['url']}')?.host ?? spec['url']}' : 'Changes to ${spec['url']}',
    _ => '${spec['check']}',
  };
}

class _OwnerTag extends StatelessWidget {
  const _OwnerTag({required this.core, required this.botId});
  final CoreClient core;
  final String? botId;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bot = core.botFor(botId);
    final v = int.tryParse((bot?.color ?? '').replaceFirst('#', ''), radix: 16);
    final color = v == null ? c.muted : Color(0xFF000000 | v);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(
          bot == null ? 'Compii' : (bot.archived ? '${bot.name} (archived — not running)' : bot.name),
          style: context.type.labelMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// Days in the next week this routine lands on (0 is today).
Set<int> _routineDays(Map<String, dynamic> r) {
  final s = (r['schedule'] as Map?) ?? const {};
  final kind = '${s['kind']}';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final out = <int>{};
  for (var i = 0; i < 7; i++) {
    final d = today.add(Duration(days: i));
    final ok = switch (kind) {
      'daily' => true,
      'weekdays' => d.weekday <= 5,
      'weekly' => (s['days'] as List? ?? const []).contains(_dowCode(d)),
      'once' => '${s['date'] ?? ''}' ==
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
      _ => false,
    };
    if (ok) out.add(i);
  }
  return out;
}

String _dowCode(DateTime d) => const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'][d.weekday - 1];

/// The next seven days, with what lands on each one. This is the part a list
/// can't show: how busy tomorrow is, and what is already handled.
class _WeekAhead extends StatelessWidget {
  const _WeekAhead({required this.core, required this.routines, required this.onOpen});
  final CoreClient core;
  final List<Map<String, dynamic>> routines;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = <int, List<Map<String, dynamic>>>{};
    for (final r in routines) {
      for (final i in _routineDays(r)) {
        days.putIfAbsent(i, () => []).add(r);
      }
    }
    for (final list in days.values) {
      list.sort((a, b) => '${(a['schedule'] as Map?)?['at'] ?? ''}'.compareTo('${(b['schedule'] as Map?)?['at'] ?? ''}'));
    }
    final active = routines.where((r) => r['enabled'] == true).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdaptiveRow(
          children: [
            Text('This week', style: context.type.titleLarge),
            const Spacer(),
            Text('$active running · ${routines.length} total', style: context.type.labelMedium?.copyWith(color: c.faint)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == 6 ? 0 : 6),
                  child: _DayColumn(
                    day: today.add(Duration(days: i)),
                    first: i == 0,
                    core: core,
                    routines: days[i] ?? const [],
                    onOpen: onOpen,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({required this.day, required this.first, required this.core, required this.routines, required this.onOpen});
  final DateTime day;
  final bool first;
  final CoreClient core;
  final List<Map<String, dynamic>> routines;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final shown = routines.take(2).toList();
    return Container(
      constraints: const BoxConstraints(minHeight: 132),
      padding: const EdgeInsets.fromLTRB(9, 9, 9, 8),
      decoration: BoxDecoration(
        color: first ? c.accentSoft.withValues(alpha: c.dark ? .5 : .6) : c.raised,
        borderRadius: Shapes.r12,
        border: Border.all(color: first ? c.accent.withValues(alpha: .35) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_day(day), style: context.type.labelSmall?.copyWith(color: first ? c.accent : c.faint)),
              const Spacer(),
              Text('${day.day}', style: context.type.titleSmall?.copyWith(color: first ? c.accent : c.text)),
            ],
          ),
          const SizedBox(height: 7),
          if (routines.isEmpty)
            Text('—', style: context.type.bodySmall?.copyWith(color: c.faint))
          else
            for (final r in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _DayChip(core: core, routine: r, onTap: () => onOpen(r)),
              ),
          if (routines.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text('+${routines.length - shown.length} more',
                  style: context.type.labelSmall?.copyWith(color: c.faint)),
            ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.core, required this.routine, required this.onTap});
  final CoreClient core;
  final Map<String, dynamic> routine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = routine['enabled'] == true;
    final bot = core.botFor(routine['bot_id'] as String?);
    final v = int.tryParse((bot?.color ?? '').replaceFirst('#', ''), radix: 16);
    final dot = v == null ? c.accent : Color(0xFF000000 | v);
    return Keyable(
      radius: Shapes.r8,
      label: '${routine['title']}, ${on ? 'on' : 'off'}',
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
            decoration: BoxDecoration(
              color: on ? c.raised : c.sunken,
              borderRadius: Shapes.r8,
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 5, height: 5, decoration: BoxDecoration(color: on ? dot : c.faint, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text('${(routine['schedule'] as Map?)?['at'] ?? ''}',
                        style: context.type.labelSmall?.copyWith(color: on ? c.text : c.faint, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 2),
                Text('${routine['title']}', maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: context.type.labelSmall?.copyWith(color: on ? c.muted : c.faint, height: 1.25)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoutineTile extends StatelessWidget {
  const _RoutineTile({required this.core, required this.routine, required this.run, required this.set, required this.onOpen, this.showOwner = true});
  final CoreClient core;
  final Map<String, dynamic> routine;
  final Run run;
  final void Function(Map<String, dynamic>) set;
  final VoidCallback onOpen;
  final bool showOwner;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = routine;
    final enabled = r['enabled'] == true;
    final runs = [for (final x in r['runs'] as List? ?? const []) Map<String, dynamic>.from(x as Map)];
    final last = runs.isEmpty ? null : runs.first;
    final task = last == null ? null : core.tasks['${last['task_id']}'];
    final running = task?.active == true || last?['status'] == 'running';
    final status = running
        ? 'Running now'
        : !enabled
            ? 'Paused'
            : 'Next ${_ago(r['next_run'])}';
    final statusColor = running ? c.accent : (enabled ? c.success : c.faint);
    final snippet = task?.finalText?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                GlyphTile(glyph: G.routine, size: 36, color: enabled ? c.accent : c.faint),
                const SizedBox(height: 7),
                Text('${(r['schedule'] as Map?)?['at'] ?? ''}',
                    style: context.type.labelSmall?.copyWith(color: enabled ? c.text : c.faint, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text('${r['title']}', style: context.type.titleSmall)),
                      if (showOwner) ...[
                        const SizedBox(width: 8),
                        _OwnerTag(core: core, botId: r['bot_id'] as String?),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('${r['when']}', style: context.type.bodySmall?.copyWith(color: c.muted)),
                  const SizedBox(height: 5),
                  Text('“${r['instruction']}”', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  if (snippet != null && snippet.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Glyph(G.check, size: 12, color: c.success),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text('Last time: $snippet', maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: context.type.bodySmall?.copyWith(color: c.faint)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (running)
                      const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    if (running) const SizedBox(width: 5),
                    Container(width: 6, height: 6, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    Text(status, style: context.type.labelMedium?.copyWith(color: statusColor)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Run now (test it)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => run(() async {
                        await core.runRoutine('${r['id']}');
                        set(await core.proactive());
                      }),
                      icon: const Glyph(G.play, size: 18),
                    ),
                    Switch(value: enabled, onChanged: (on) => run(() async => set(await core.setEnabled('${r['id']}', on)))),
                    PopupMenuButton<String>(
                      tooltip: 'More actions',
                      icon: Glyph(G.more, size: 20, color: c.muted),
                      onSelected: (choice) async {
                        if (choice == 'open') return onOpen();
                        if (choice == 'edit') return showRoutineEditor(context, core: core, set: set, routine: r);
                        if (choice == 'delete') return run(() async => set(await core.removePlan('${r['id']}')));
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'open', child: Text('Open')),
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        const PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// An offer Compii made because the same ask keeps coming back, with its two answers.
class HabitRow extends StatelessWidget {
  const HabitRow({
    super.key,
    required this.suggestion,
    required this.onAccept,
    required this.onDecline,
    this.busy = false,
    this.error,
  });

  final Map<String, dynamic> suggestion;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = suggestion;
    final routine = '${s['kind']}' == 'routine';
    final when = '${s['when'] ?? ''}';
    final count = s['count'] is num ? (s['count'] as num).toInt() : 0;
    final steps = (s['steps'] as List?)?.length ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphTile(glyph: routine ? G.routine : G.skill, size: 32, color: c.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${s['title'] ?? ''}', style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${s['why'] ?? ''}', style: context.type.bodySmall?.copyWith(color: c.muted)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Pill('$count times asked', color: c.muted, glyph: G.memory),
                        if (when.isNotEmpty) Pill(when, color: c.accent, glyph: G.clock),
                        if (!routine && steps > 0) Pill('$steps steps that worked', color: c.success, glyph: G.check),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AdaptiveRow(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : onDecline,
                child: const Text('Not now'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: busy ? null : onAccept,
                child: Text(routine ? 'Put it on the clock' : 'Save the steps'),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
          ],
        ],
      ),
    );
  }
}

/// The same offer, wired to Core: answering it is the only way anything gets scheduled.
class _HabitCard extends StatefulWidget {
  const _HabitCard({required this.core, required this.suggestion, required this.set});
  final CoreClient core;
  final Map<String, dynamic> suggestion;
  final void Function(Map<String, dynamic>) set;

  @override
  State<_HabitCard> createState() => _HabitCardState();
}

class _HabitCardState extends State<_HabitCard> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<Map<String, dynamic>> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.set(await action());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => HabitRow(
        suggestion: widget.suggestion,
        busy: _busy,
        error: _error,
        onAccept: () => _act(() => widget.core.acceptSuggestion('${widget.suggestion['id']}')),
        onDecline: () => _act(() => widget.core.declineSuggestion('${widget.suggestion['id']}')),
      );
}

/// What to add when there is nothing yet: one tap to a useful routine.
class _Starters extends StatelessWidget {
  const _Starters({required this.core, required this.set});
  final CoreClient core;
  final void Function(Map<String, dynamic>) set;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ideas = [
      (G.mail, 'Triage my inbox', 'Sort today’s mail, flag what needs me and leave replies ready to send.', {'kind': 'weekdays', 'at': '08:00'}, 'Weekday mornings'),
      (G.broom, 'Tidy Downloads', 'Sort new files in Downloads into folders by type and tell me what moved.', {'kind': 'daily', 'at': '18:00'}, 'Every evening'),
      (G.doc, 'Weekly review', 'Summarise what got done this week and list what is next.', {'kind': 'weekly', 'days': ['fri'], 'at': '16:00'}, 'Friday afternoons'),
    ];
    return PanelRows(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text('Nothing scheduled yet. Start with one of these, or tell Compii in your own words.',
              style: context.type.bodySmall?.copyWith(color: c.muted)),
        ),
        for (final (glyph, title, instruction, schedule, cadence) in ideas)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
            child: Row(
              children: [
                GlyphTile(glyph: glyph, size: 34, color: c.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.type.titleSmall),
                      Text('$cadence · $instruction', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => showRoutineEditor(context, core: core, set: set,
                      initialTitle: title, initialInstruction: instruction, initialSchedule: schedule),
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// The full picture of one routine: when it runs, what happened last time,
/// and every run it has made with a link to the actual conversation.
Future<void> showRoutineStudio(
  BuildContext context, {
  required CoreClient core,
  required void Function(Map<String, dynamic>) set,
  required Map<String, dynamic> routine,
  required Run run,
  void Function(String taskId)? onOpenTask,
}) =>
    showDialog<void>(
      context: context,
      barrierColor: context.c.canvas.withValues(alpha: .55),
      builder: (_) => _RoutineStudio(core: core, set: set, routine: routine, onOpenTask: onOpenTask),
    );

class _RoutineStudio extends StatefulWidget {
  const _RoutineStudio({required this.core, required this.set, required this.routine, this.onOpenTask});
  final CoreClient core;
  final void Function(Map<String, dynamic>) set;
  final Map<String, dynamic> routine;
  final void Function(String taskId)? onOpenTask;

  @override
  State<_RoutineStudio> createState() => _RoutineStudioState();
}

class _RoutineStudioState extends State<_RoutineStudio> {
  late Map<String, dynamic> _r = widget.routine;
  bool _busy = false;

  String get _id => '${_r['id']}';
  bool get _enabled => _r['enabled'] == true;

  Future<void> _reload() async {
    try {
      final v = await widget.core.proactive();
      if (!mounted) return;
      widget.set(v);
      for (final x in v['routines'] as List) {
        final r = Map<String, dynamic>.from(x as Map);
        if ('${r['id']}' == _id) {
          setState(() => _r = r);
          break;
        }
      }
    } on Object {
      // The dialog keeps the data it has; a refresh will come with the next update.
    }
  }

  Future<void> _runNow() async {
    setState(() => _busy = true);
    try {
      await widget.core.runRoutine(_id);
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool on) async {
    try {
      final v = await widget.core.setEnabled(_id, on);
      widget.set(v);
      await _reload();
    } on Object {
      // Leave the switch where it was; the next reload settles it.
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${_r['title']}”?'),
        content: const Text('It stops running and its history goes away. Conversations it already had stay in History.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;
    final v = await widget.core.removePlan(_id);
    widget.set(v);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final runs = [for (final x in _r['runs'] as List? ?? const []) Map<String, dynamic>.from(x as Map)];
    final last = runs.isEmpty ? null : runs.first;
    final running = _busy || last?['status'] == 'running' || widget.core.tasks['${last?['task_id']}']?.active == true;
    final next = _enabled ? _ago(_r['next_run']) : 'Off';
    final lastLabel = runs.isEmpty ? 'Never run' : _ago(last!['at']);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 700),
        child: Container(
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: Shapes.r20,
            border: Border.all(color: c.borderStrong),
            boxShadow: Shapes.float(c),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 12, 16),
                child: Row(
                  children: [
                    GlyphTile(glyph: G.routine, size: 46, color: _enabled ? c.accent : c.faint),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${_r['title']}', style: context.type.headlineSmall),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Text('${_r['when']}', style: context.type.bodySmall?.copyWith(color: c.muted)),
                              const SizedBox(width: 10),
                              _OwnerTag(core: widget.core, botId: _r['bot_id'] as String?),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Switch(value: _enabled, onChanged: _toggle),
                    IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Glyph(G.close, size: 20)),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _Stat(label: 'NEXT RUN', value: running ? 'Running' : next, accent: running),
                          const SizedBox(width: 10),
                          _Stat(label: 'LAST RUN', value: lastLabel),
                          const SizedBox(width: 10),
                          _Stat(label: 'KEPT RUNS', value: '${runs.length}'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
                        decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r12, border: Border.all(color: c.border)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('WHAT IT DOES', style: context.type.labelSmall?.copyWith(color: c.faint)),
                            const SizedBox(height: 5),
                            Text('${_r['instruction']}', style: context.type.bodyMedium?.copyWith(height: 1.4)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      AdaptiveRow(
                        children: [
                          FilledButton.icon(
                            onPressed: running ? null : _runNow,
                            icon: running
                                ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.onAccent))
                                : Glyph(G.play, size: 16, color: c.onAccent),
                            label: Text(running ? 'Running now' : 'Run now'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await showRoutineEditor(context, core: widget.core, set: widget.set, routine: _r);
                              await _reload();
                            },
                            icon: const Glyph(G.edit, size: 16),
                            label: const Text('Edit'),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _delete,
                            icon: Glyph(G.trash, size: 16, color: c.danger),
                            label: Text('Delete', style: context.type.labelLarge?.copyWith(color: c.danger)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      AdaptiveRow(
                        children: [
                          Text('RUN HISTORY', style: context.type.labelSmall),
                          const Spacer(),
                          if (runs.isNotEmpty)
                            Text('newest first', style: context.type.labelSmall?.copyWith(color: c.faint)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (runs.isEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r12),
                          child: Text('It hasn’t run yet. “Run now” tries it once, exactly as it will run on schedule.',
                              style: context.type.bodySmall?.copyWith(color: c.muted)),
                        )
                      else
                        for (final (i, run) in runs.indexed) ...[
                          if (i > 0) Divider(height: 1, color: c.border),
                          _RunRow(core: widget.core, run: run, onOpen: widget.onOpenTask),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.accent = false});
  final String label;
  final String value;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
        decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r10, border: Border.all(color: c.border)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: context.type.labelSmall?.copyWith(color: c.faint)),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: context.type.titleSmall?.copyWith(color: accent ? c.accent : c.text)),
          ],
        ),
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.core, required this.run, this.onOpen});
  final CoreClient core;
  final Map<String, dynamic> run;
  final void Function(String taskId)? onOpen;

  String get _status => '${run['status']}';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final task = core.tasks['${run['task_id']}'];
    final text = task?.finalText?.replaceAll(RegExp(r'\s+'), ' ').trim();
    final (GlyphData glyph, Color color) = switch (_status) {
      'done' => (G.check, c.success),
      'failed' => (G.close, c.danger),
      'running' => (G.play, c.accent),
      _ => (G.dot, c.faint),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(color: color.withValues(alpha: .12), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Glyph(glyph, size: 13, color: color),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveRow(
                  children: [
                    Text(_prettyWhen(run['at']), style: context.type.labelLarge),
                    const SizedBox(width: 8),
                    Text(_status, style: context.type.labelMedium?.copyWith(color: color)),
                    if (task != null) ...[
                      const Spacer(),
                      Text(_duration(task), style: context.type.labelSmall?.copyWith(color: c.faint)),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  text?.isNotEmpty == true
                      ? text!
                      : _status == 'running'
                          ? 'Working on it now…'
                          : _status == 'failed'
                              ? 'That run didn’t finish.'
                              : 'Finished.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.bodySmall?.copyWith(color: c.muted, height: 1.35),
                ),
              ],
            ),
          ),
          if (onOpen != null && task != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                onOpen!('${run['task_id']}');
              },
              child: const Text('Open'),
            ),
        ],
      ),
    );
  }
}

String _prettyWhen(Object? at) {
  if (at == null) return '—';
  final t = at is num ? DateTime.fromMillisecondsSinceEpoch((at * 1000).round()) : DateTime.tryParse('$at');
  if (t == null) return '—';
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  final days = day.difference(that).inDays;
  final label = days == 0 ? 'Today' : days == 1 ? 'Yesterday' : days < 7 ? _day(t) : '${t.day}/${t.month}';
  return '$label ${_hm(t)}';
}

num? _eventAt(TaskView task, String type) {
  for (final e in task.events.reversed) {
    if (e['type'] == type) return e['at'] as num?;
  }
  return null;
}

String _duration(TaskView task) {
  final start = _eventAt(task, 'task_started');
  final end = _eventAt(task, 'task_finished');
  if (start == null || end == null) return task.active ? 'now' : '';
  final d = Duration(milliseconds: ((end - start) * 1000).round());
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  return '${d.inMinutes}m ${d.inSeconds % 60}s';
}

/// The routines one teammate owns, shown on its home.
class BotRoutines extends StatelessWidget {
  const BotRoutines({super.key, required this.core, required this.run, required this.bot, this.onOpenTask});
  final CoreClient core;
  final Run run;
  final BotView bot;
  final void Function(String taskId)? onOpenTask;

  @override
  Widget build(BuildContext context) => _Plans(
        core: core,
        run: run,
        builder: (context, v, set, retry) {
          final c = context.c;
          final routines = [
            for (final r in v['routines'] as List)
              if ((r as Map)['bot_id'] == bot.id) Map<String, dynamic>.from(r)
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (retry != null) LoadFailure(onRetry: retry),
              Row(
                children: [
                  Expanded(child: Text('ROUTINES', style: context.type.labelSmall)),
                  TextButton.icon(
                    onPressed: () => showRoutineEditor(context, core: core, set: set, botId: bot.id, lockOwner: true),
                    icon: const Glyph(G.plus, size: 16),
                    label: const Text('New routine'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (routines.isEmpty)
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Text(
                    'Nothing scheduled for ${bot.name} yet. Give it a recurring job — it will run as ${bot.name}, '
                    'with its role and memory.',
                    style: context.type.bodySmall?.copyWith(color: c.faint),
                  ),
                )
              else
                PanelRows(
                  children: [
                    for (final r in routines)
                      _RoutineTile(
                        core: core,
                        routine: r,
                        run: run,
                        set: set,
                        showOwner: false,
                        onOpen: () => showRoutineStudio(context, core: core, set: set, routine: r, run: run, onOpenTask: onOpenTask),
                      ),
                  ],
                ),
            ],
          );
        },
      );
}

/// Create or edit a routine. `botId` (with `lockOwner`) fixes the owner, so a
/// bot's home always schedules work for that bot.
Future<void> showRoutineEditor(
  BuildContext context, {
  required CoreClient core,
  required void Function(Map<String, dynamic>) set,
  Map<String, dynamic>? routine,
  String? botId,
  bool lockOwner = false,
  String? initialTitle,
  String? initialInstruction,
  Map<String, dynamic>? initialSchedule,
}) async {
  final schedule = Map<String, dynamic>.from(
      routine?['schedule'] as Map? ?? initialSchedule ?? const {'kind': 'weekdays', 'at': '08:00'});
  final known = const {'daily', 'weekdays', 'weekly'};
  final title = TextEditingController(text: '${routine?['title'] ?? initialTitle ?? ''}');
  final instruction = TextEditingController(text: '${routine?['instruction'] ?? initialInstruction ?? ''}');
  var kind = known.contains('${schedule['kind']}') ? '${schedule['kind']}' : 'daily';
  final unusual = !known.contains('${schedule['kind']}');
  var at = TimeOfDay(hour: 8, minute: 0);
  final parts = '${schedule['at'] ?? '08:00'}'.split(':');
  if (parts.length == 2) {
    at = TimeOfDay(hour: int.tryParse(parts[0]) ?? 8, minute: int.tryParse(parts[1]) ?? 0);
  }
  final days = <String>{for (final d in schedule['days'] as List? ?? const ['mon']) '$d'};
  // A put-away teammate takes no new errand, but one it already owns keeps saying whose it is:
  // the schedule stops firing until it comes back, and hiding the owner would hide that reason.
  final runnable = [for (final b in core.bots) if (!b.archived) b];
  final ownerIds = {for (final b in runnable) b.id};
  final current = core.botFor('${routine?['bot_id'] ?? ''}');
  if (current != null && current.archived) ownerIds.add(current.id);
  var owner = '${routine?['bot_id'] ?? botId ?? core.primaryBotId ?? ''}';
  if (owner.isEmpty || !ownerIds.contains(owner)) owner = core.primaryBotId ?? (core.bots.isEmpty ? '' : core.bots.first.id);
  String? problem;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) {
        final c = context.c;
        return AlertDialog(
          title: Text(routine == null ? 'New routine' : 'Edit routine'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: title, decoration: const InputDecoration(labelText: 'Name', hintText: 'Tidy Downloads')),
                  const SizedBox(height: 12),
                  TextField(
                    controller: instruction,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'What should Compii do?', hintText: 'Sort my Downloads into folders by type and tell me what moved'),
                  ),
                  const SizedBox(height: 16),
                  if (unusual)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'This routine currently repeats ${'${schedule['kind']}' == 'every' ? 'every ${schedule['minutes']} minutes' : 'once'}. '
                        'Choosing a schedule below replaces that.',
                        style: context.type.bodySmall?.copyWith(color: c.warning),
                      ),
                    ),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'daily', label: Text('Every day')),
                      ButtonSegment(value: 'weekdays', label: Text('Weekdays')),
                      ButtonSegment(value: 'weekly', label: Text('Some days')),
                    ],
                    selected: {kind},
                    onSelectionChanged: (s) => setLocal(() => kind = s.first),
                  ),
                  if (kind == 'weekly') ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final d in const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'])
                          FilterChip(
                            label: Text(d[0].toUpperCase() + d.substring(1)),
                            selected: days.contains(d),
                            onSelected: (on) => setLocal(() => on ? days.add(d) : days.remove(d)),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: at);
                      if (t != null) setLocal(() => at = t);
                    },
                    icon: const Glyph(G.clock),
                    label: Text('At ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'),
                  ),
                  const SizedBox(height: 8),
                  if (!lockOwner && (runnable.length > 1 || ownerIds.length > 1)) ...[
                    Text('Who runs it', style: context.type.labelMedium),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: ownerIds.contains(owner) ? owner : null,
                      items: [
                        for (final b in core.bots)
                          if (ownerIds.contains(b.id))
                            DropdownMenuItem(
                              value: b.id,
                              child: Text(b.archived ? '${b.name} — archived, will not run' : b.name),
                            ),
                      ],
                      onChanged: (v) => setLocal(() => owner = v ?? owner),
                    ),
                  ] else if (lockOwner)
                    Text('Owned by ${core.botFor(botId)?.name ?? 'this teammate'}',
                        style: context.type.bodySmall?.copyWith(color: c.muted)),
                  if (problem != null) ...[
                    const SizedBox(height: 10),
                    Text(problem!, style: context.type.bodySmall?.copyWith(color: c.danger)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (instruction.text.trim().isEmpty) return;
                final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
                final when = {'kind': kind, 'at': hm, if (kind == 'weekly') 'days': days.toList()};
                final name = title.text.trim().isEmpty ? instruction.text.trim() : title.text.trim();
                try {
                  final v = routine == null
                      ? await core.addRoutine(name, instruction.text.trim(), when, botId: owner.isEmpty ? null : owner)
                      : await core.updateRoutine('${routine['id']}', name, instruction.text.trim(), when,
                          botId: owner.isEmpty ? null : owner);
                  set(v);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  setLocal(() => problem = '$e');
                }
              },
              child: Text(routine == null ? 'Schedule' : 'Save'),
            ),
          ],
        );
      },
    ),
  );
  title.dispose();
  instruction.dispose();
}

Future<void> _newWatch(BuildContext context, CoreClient core, Run run, void Function(Map<String, dynamic>) set) async {
  final title = TextEditingController();
  final where = TextEditingController();
  final what = TextEditingController();
  var kind = 'folder';
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('New watch'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'folder', label: Text('New files'), icon: Glyph(G.folder)),
                  ButtonSegment(value: 'web', label: Text('A web page'), icon: Glyph(G.globe)),
                ],
                selected: {kind},
                onSelectionChanged: (s) => setLocal(() => kind = s.first),
              ),
              const SizedBox(height: 12),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Name', hintText: 'New invoices')),
              const SizedBox(height: 12),
              TextField(
                controller: where,
                decoration: InputDecoration(
                  labelText: kind == 'folder' ? 'Folder' : 'Web address',
                  hintText: kind == 'folder' ? '~/Downloads' : 'https://shop.example/lamp',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: what,
                decoration: InputDecoration(
                  labelText: kind == 'folder' ? 'File names like (optional)' : 'Tell me when it says (optional)',
                  hintText: kind == 'folder' ? '*invoice*' : 'In stock — leave empty for any change',
                ),
              ),
              const SizedBox(height: 10),
              Text('Checked on this PC for free. For anything needing judgement, just ask Compii in a conversation.',
                  style: context.type.bodySmall),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (where.text.trim().isEmpty) return;
              final spec = kind == 'folder'
                  ? {'folder': where.text.trim(), if (what.text.trim().isNotEmpty) 'pattern': what.text.trim()}
                  : {'url': where.text.trim(), if (what.text.trim().isNotEmpty) 'contains': what.text.trim()};
              await run(() async => set(await core.addWatch(title.text.trim().isEmpty ? where.text.trim() : title.text.trim(), kind, spec)));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Start watching'),
          ),
        ],
      ),
    ),
  );
}

/// Everything Compii told you on its own, newest first.
class UpdatesPage extends StatelessWidget {
  const UpdatesPage({super.key, required this.core, required this.run, required this.onOpenTask});
  final CoreClient core;
  final Run run;
  final void Function(String taskId) onOpenTask;

  @override
  Widget build(BuildContext context) => _Plans(
    core: core,
    run: run,
    builder: (context, v, set, retry) {
      final inbox = [for (final u in v['inbox'] as List) Map<String, dynamic>.from(u as Map)];
      return _Page(
        title: 'Updates',
        subtitle: 'What Compii noticed or finished on its own: briefs, watches and routines.',
        action: (v['unread'] as int? ?? 0) > 0
            ? TextButton(onPressed: () => run(() async => set(await core.markRead())), child: const Text('Mark all read'))
            : null,
        children: [
          if (retry != null) LoadFailure(onRetry: retry),
          if (inbox.isEmpty)
            const EmptyState(
              glyph: G.bell,
              title: 'Nothing yet.',
              body: 'Your morning brief and anything your watches catch will show up here.',
            )
          else
            for (final u in inbox)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: UpdateCard(
                  update: u,
                  onOpenTask: u['task_id'] == null ? null : () => onOpenTask('${u['task_id']}'),
                  onRead: u['read'] == true ? null : () => run(() async => set(await core.markRead('${u['id']}'))),
                ),
              ),
        ],
      );
    },
  );
}

class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.update, this.onOpenTask, this.onRead});
  final Map<String, dynamic> update;
  final VoidCallback? onOpenTask;
  final VoidCallback? onRead;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final kind = '${update['kind']}';
    final (GlyphData icon, Color color) = switch (kind) {
      'brief' => (G.sun, c.accent),
      'watch' => (G.eye, c.success),
      'needs_you' => (G.hand, c.warning),
      'journal' => (G.note, c.accent),
      _ => (G.routine, c.accent),
    };
    final sections = [for (final s in update['sections'] as List? ?? const []) Map<String, dynamic>.from(s as Map)];
    final unread = update['read'] != true;
    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        border: Border.all(color: unread ? color.withValues(alpha: .5) : c.border, width: unread ? 1.4 : 1),
        borderRadius: Shapes.r14,
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlyphTile(glyph: icon, size: 34, color: color),
              const SizedBox(width: 10),
              Expanded(child: Text('${update['title']}', style: context.type.titleSmall)),
              Text(_ago(update['at']), style: context.type.labelMedium),
              if (onRead != null)
                IconButton(tooltip: 'Mark read', visualDensity: VisualDensity.compact, onPressed: onRead, icon: const Glyph(G.check, size: 18)),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText('${update['body']}', style: context.type.bodyMedium),
          for (final s in sections) ...[
            const SizedBox(height: 12),
            Text('${s['title']}'.toUpperCase(), style: context.type.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final item in s['items'] as List)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 7), child: Glyph(G.dot, size: 5, color: c.faint)),
                    const SizedBox(width: 8),
                    Expanded(child: Text('$item', style: context.type.bodyMedium)),
                  ],
                ),
              ),
          ],
          if (onOpenTask != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: onOpenTask, icon: const Glyph(G.chat, size: 16), label: const Text('Open conversation')),
            ),
        ],
      ),
    );
  }
}

/// Today's brief at the top of Home.
class BriefCard extends StatelessWidget {
  const BriefCard({super.key, required this.core, required this.run});
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) => _Plans(
    core: core,
    run: run,
    quiet: true,
    builder: (context, v, set, _) {
      final today = DateTime.now();
      final brief = [for (final u in v['inbox'] as List) Map<String, dynamic>.from(u as Map)]
          .where((u) => u['kind'] == 'brief')
          .where((u) {
            final at = DateTime.fromMillisecondsSinceEpoch(((u['at'] as num) * 1000).round());
            return at.year == today.year && at.month == today.month && at.day == today.day;
          })
          .firstOrNull;
      if (brief == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: UpdateCard(
          update: brief,
          onRead: brief['read'] == true ? null : () => run(() async => set(await core.markRead('${brief['id']}'))),
        ),
      );
    },
  );
}


/// A small card that slides in at the top right when Compii has news.
class UpdateNotices extends StatefulWidget {
  const UpdateNotices({super.key, required this.core, required this.onView, required this.child});
  final CoreClient core;
  final VoidCallback onView;
  final Widget child;
  @override
  State<UpdateNotices> createState() => _UpdateNoticesState();
}

class _UpdateNoticesState extends State<UpdateNotices> {
  Map<String, dynamic>? _current;
  Timer? _hide;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.core.updates.stream.listen((u) {
      _hide?.cancel();
      setState(() => _current = u);
      _hide = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _current = null);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = _current;
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 16,
          right: 16,
          child: AnimatedSwitcher(
            duration: context.motion(220),
            transitionBuilder: (child, anim) => SlideTransition(
              position: Tween(begin: const Offset(.15, 0), end: Offset.zero).animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: u == null
                ? const SizedBox.shrink()
                : Material(
                    key: ValueKey(u['id']),
                    elevation: 6,
                    color: Colors.transparent,
                    borderRadius: Shapes.r14,
                    child: SizedBox(
                      width: 360,
                      child: Stack(
                        children: [
                          UpdateCard(update: {...u, 'sections': const [], 'read': true}),
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: Row(
                              children: [
                                TextButton(
                                  onPressed: () {
                                    setState(() => _current = null);
                                    widget.onView();
                                  },
                                  child: const Text('View'),
                                ),
                                IconButton(
                                  tooltip: 'Dismiss',
                                  onPressed: () => setState(() => _current = null),
                                  icon: const Glyph(G.close, size: 18),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
