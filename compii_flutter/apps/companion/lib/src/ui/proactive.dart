import 'dart:async';

import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'thread.dart';
import 'tokens.dart';

/// Loads Compii's routines, watches, brief settings and inbox, and reloads
/// when something new arrives.
class _Plans extends StatefulWidget {
  const _Plans({required this.core, required this.run, required this.builder});
  final CoreClient core;
  final Run run;
  final Widget Function(BuildContext, Map<String, dynamic>, void Function(Map<String, dynamic>)) builder;
  @override
  State<_Plans> createState() => _PlansState();
}

class _PlansState extends State<_Plans> {
  Map<String, dynamic>? _v;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.core.updates.stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() => widget.run(() async {
    final v = await widget.core.proactive();
    if (mounted) setState(() => _v = v);
  });

  void _set(Map<String, dynamic> v) {
    if (mounted) setState(() => _v = v);
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    if (v == null) return const Center(child: CircularProgressIndicator());
    return widget.builder(context, v, _set);
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.subtitle, required this.children, this.action});
  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.type.headlineMedium),
                        const SizedBox(height: 6),
                        Text(subtitle, style: context.type.bodyLarge?.copyWith(color: context.c.muted)),
                      ],
                    ),
                  ),
                  ?action,
                ],
              ),
              const SizedBox(height: 24),
              ...children,
            ],
          ),
        ),
      ),
    ],
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      decoration: BoxDecoration(color: c.raised, border: Border.all(color: c.border), borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          for (final (i, w) in children.indexed) ...[
            if (i > 0) Divider(height: 1, color: c.border),
            w,
          ],
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
  const RoutinesPage({super.key, required this.core, required this.run});
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) => _Plans(
    core: core,
    run: run,
    builder: (context, v, set) {
      final c = context.c;
      final brief = Map<String, dynamic>.from(v['brief'] as Map);
      final routines = [for (final r in v['routines'] as List) Map<String, dynamic>.from(r as Map)];
      final watches = [for (final w in v['watches'] as List) Map<String, dynamic>.from(w as Map)];
      Future<void> apply(Future<Map<String, dynamic>> Function() f) => run(() async => set(await f()));

      return _Page(
        title: 'Routines',
        subtitle: 'Things Compii does on its own schedule, and things it keeps an eye on for you. You can also just ask: “every Friday at 5, tidy my Downloads”.',
        children: [
          Text('Daily brief', style: context.type.titleLarge),
          const SizedBox(height: 10),
          _Card(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.wb_sunny_outlined, color: c.accent),
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
                      icon: const Icon(Icons.play_circle_outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: Text('Scheduled', style: context.type.titleLarge)),
              OutlinedButton.icon(
                onPressed: () => _newRoutine(context, core, run, set),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New routine'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (routines.isEmpty)
            _Empty(icon: Icons.event_repeat, text: 'No routines yet. Try asking: “Every weekday at 8, summarise my new Downloads.”')
          else
            _Card(
              children: [
                for (final r in routines)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        Icon(Icons.event_repeat, color: r['enabled'] == true ? c.accent : c.faint),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r['title']}', style: context.type.titleSmall),
                              Text('${r['when']} · ${r['enabled'] == true ? 'next ${_ago(r['next_run'])}' : 'paused'} · last ${_ago(r['last_run'])}',
                                  style: context.type.bodySmall),
                              Text('“${r['instruction']}”', maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: context.type.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                            ],
                          ),
                        ),
                        IconButton(tooltip: 'Run now', onPressed: () => run(() => core.runRoutine('${r['id']}')), icon: const Icon(Icons.play_arrow_rounded)),
                        Switch(value: r['enabled'] == true, onChanged: (on) => apply(() => core.setEnabled('${r['id']}', on))),
                        IconButton(tooltip: 'Delete', onPressed: () => apply(() => core.removePlan('${r['id']}')), icon: const Icon(Icons.delete_outline)),
                      ],
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: Text('Watching', style: context.type.titleLarge)),
              OutlinedButton.icon(
                onPressed: () => _newWatch(context, core, run, set),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New watch'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (watches.isEmpty)
            _Empty(icon: Icons.visibility_outlined, text: 'Nothing watched yet. Try: “Tell me when an invoice lands in Downloads.”')
          else
            _Card(
              children: [
                for (final w in watches)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        Icon(switch ('${w['kind']}') {
                          'folder' => Icons.folder_outlined,
                          'web' => Icons.public,
                          _ => Icons.auto_awesome_outlined,
                        }, color: w['enabled'] == true ? c.accent : c.faint),
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
                        IconButton(tooltip: 'Delete', onPressed: () => apply(() => core.removePlan('${w['id']}')), icon: const Icon(Icons.delete_outline)),
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

String _watchWhat(Map<String, dynamic> w) {
  final spec = Map<String, dynamic>.from(w['spec'] as Map);
  return switch ('${w['kind']}') {
    'folder' => 'New ${spec['pattern'] ?? 'files'} in ${'${spec['folder']}'.split(RegExp(r'[\\/]')).last}',
    'web' => spec['contains'] != null ? '“${spec['contains']}” on ${Uri.tryParse('${spec['url']}')?.host ?? spec['url']}' : 'Changes to ${spec['url']}',
    _ => '${spec['check']}',
  };
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => _Card(
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, color: context.c.faint),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: context.type.bodyMedium?.copyWith(color: context.c.muted))),
          ],
        ),
      ),
    ],
  );
}

Future<void> _newRoutine(BuildContext context, CoreClient core, Run run, void Function(Map<String, dynamic>) set) async {
  final title = TextEditingController();
  final instruction = TextEditingController();
  var kind = 'weekdays';
  var at = const TimeOfDay(hour: 8, minute: 0);
  final days = <String>{'mon'};
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('New routine'),
        content: SizedBox(
          width: 460,
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
                icon: const Icon(Icons.schedule),
                label: Text('At ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (instruction.text.trim().isEmpty) return;
              final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
              await run(() async => set(await core.addRoutine(
                title.text.trim().isEmpty ? instruction.text.trim() : title.text.trim(),
                instruction.text.trim(),
                {'kind': kind, 'at': hm, if (kind == 'weekly') 'days': days.toList()},
              )));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Schedule'),
          ),
        ],
      ),
    ),
  );
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
                  ButtonSegment(value: 'folder', label: Text('New files'), icon: Icon(Icons.folder_outlined)),
                  ButtonSegment(value: 'web', label: Text('A web page'), icon: Icon(Icons.public)),
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
    builder: (context, v, set) {
      final inbox = [for (final u in v['inbox'] as List) Map<String, dynamic>.from(u as Map)];
      return _Page(
        title: 'Updates',
        subtitle: 'What Compii noticed or finished on its own: briefs, watches and routines.',
        action: (v['unread'] as int? ?? 0) > 0
            ? TextButton(onPressed: () => run(() async => set(await core.markRead())), child: const Text('Mark all read'))
            : null,
        children: [
          if (inbox.isEmpty)
            const _Empty(icon: Icons.notifications_none, text: 'Nothing yet. Your morning brief and anything your watches catch will show up here.')
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
    final (IconData icon, Color color) = switch (kind) {
      'brief' => (Icons.wb_sunny_outlined, c.accent),
      'watch' => (Icons.visibility_outlined, c.success),
      'needs_you' => (Icons.front_hand_outlined, c.warning),
      _ => (Icons.event_repeat, c.accent),
    };
    final sections = [for (final s in update['sections'] as List? ?? const []) Map<String, dynamic>.from(s as Map)];
    final unread = update['read'] != true;
    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        border: Border.all(color: unread ? color.withValues(alpha: .5) : c.border, width: unread ? 1.4 : 1),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('${update['title']}', style: context.type.titleSmall)),
              Text(_ago(update['at']), style: context.type.labelMedium),
              if (onRead != null)
                IconButton(tooltip: 'Mark read', visualDensity: VisualDensity.compact, onPressed: onRead, icon: const Icon(Icons.check, size: 18)),
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
                    Padding(padding: const EdgeInsets.only(top: 7), child: Icon(Icons.circle, size: 5, color: c.faint)),
                    const SizedBox(width: 8),
                    Expanded(child: Text('$item', style: context.type.bodyMedium)),
                  ],
                ),
              ),
          ],
          if (onOpenTask != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: onOpenTask, icon: const Icon(Icons.forum_outlined, size: 16), label: const Text('Open conversation')),
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
    builder: (context, v, set) {
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
            duration: const Duration(milliseconds: 220),
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
                    borderRadius: BorderRadius.circular(14),
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
                                  icon: const Icon(Icons.close, size: 18),
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
