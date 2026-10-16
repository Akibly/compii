import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'pages.dart';
import 'proactive.dart';
import 'thread.dart';
import 'tokens.dart';
import 'voice.dart';

enum Section { home, chat, updates, routines, memory, settings }

/// App-wide UI state shared by the workspace and the quick bar.
class AppState extends ChangeNotifier {
  Section section = Section.home;
  String? selected;
  ThemeMode themeMode = ThemeMode.system;
  String? error;

  /// Free local voice; set by the app at start.
  VoiceController? voice;

  /// The user is typing a message: the character leans in and listens.
  bool typing = false;

  void setTyping(bool v) {
    if (v != typing) {
      typing = v;
      notifyListeners();
    }
  }

  /// The character's mood right now: voice first, then typing, then tasks.
  Mood moodWith(CoreClient core) {
    final base = moodOf(core);
    final withTyping = typing && (base == Mood.idle || base == Mood.happy) ? Mood.listening : base;
    return voice?.moodOver(withTyping) ?? withTyping;
  }

  void open(String taskId) {
    selected = taskId;
    section = Section.chat;
    notifyListeners();
  }

  void go(Section s) {
    section = s;
    if (s != Section.chat) selected = null;
    notifyListeners();
  }

  void setTheme(ThemeMode m) {
    themeMode = m;
    notifyListeners();
  }

  void fail(Object? e) {
    error = e?.toString();
    notifyListeners();
  }
}

/// Overall mood of the companion across every conversation.
Mood moodOf(CoreClient core) {
  if (core.status != CoreStatus.online) return Mood.offline;
  final tasks = core.ordered;
  if (tasks.any((t) => t.pendingApproval != null)) return Mood.waiting;
  final active = tasks.where((t) => t.active).toList();
  if (active.isNotEmpty) {
    return active.first.last?['type'] == 'action_started' ? Mood.acting : Mood.thinking;
  }
  if (tasks.isEmpty) return Mood.idle;
  final latest = tasks.first;
  final at = (latest.last?['at'] as num?)?.toDouble() ?? 0;
  if (DateTime.now().millisecondsSinceEpoch / 1000 - at > 8) return Mood.idle;
  return switch (latest.status) {
    'done' => Mood.happy,
    'failed' => Mood.problem,
    _ => Mood.idle,
  };
}

String titleOf(TaskView t) {
  final words = t.request.trim().split(RegExp(r'\s+'));
  final s = words.take(8).join(' ');
  return words.length > 8 ? '$s…' : s;
}

String ago(double at) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((at * 1000).round()));
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Desktop workspace: sidebar · conversation · progress.
class Workspace extends StatelessWidget {
  const Workspace({super.key, required this.core, required this.state, this.onFaceView});
  final CoreClient core;
  final AppState state;
  final VoidCallback? onFaceView;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      state.fail(null);
    } catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([core, state, ?state.voice]),
    builder: (context, _) {
      final task = state.selected == null ? null : core.tasks[state.selected];
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => state.go(Section.home),
        },
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, box) {
              final showProgress = task != null && box.maxWidth >= 1180;
              final showSidebar = box.maxWidth >= 760;
              return Row(
                children: [
                  if (showSidebar) _Sidebar(core: core, state: state, onFaceView: onFaceView),
                  Expanded(
                    child: Column(
                      children: [
                        _StatusLine(core: core, state: state),
                        Expanded(
                          child: switch (state.section) {
                            Section.memory => MemoryPage(core: core, run: _run),
                            Section.routines => RoutinesPage(core: core, run: _run),
                            Section.updates => UpdatesPage(core: core, run: _run, onOpenTask: state.open),
                            Section.settings => SettingsPage(core: core, state: state, run: _run),
                            Section.chat when task != null => _Conversation(task: task, core: core, run: _run, state: state),
                            _ => _Home(core: core, state: state, run: _run),
                          },
                        ),
                      ],
                    ),
                  ),
                  if (showProgress) ProgressPanel(task: task, core: core, run: _run),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.core, required this.state, this.onFaceView});
  final CoreClient core;
  final AppState state;
  final VoidCallback? onFaceView;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mood = state.moodWith(core);
    final tasks = core.ordered;
    final voice = state.voice;
    return Container(
      width: 264,
      decoration: BoxDecoration(color: c.surface, border: Border(right: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 10, 10),
            child: Row(
              children: [
                if (voice != null)
                  TalkableOrbling(voice: voice, mood: mood, jobs: tasks.where((t) => t.active).length, size: 38)
                else
                  SizedBox.square(dimension: 34, child: Orbling(mood: mood, jobs: tasks.where((t) => t.active).length)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Compii', style: context.type.titleMedium),
                      Text(moodLabel(mood), style: context.type.labelMedium),
                    ],
                  ),
                ),
                if (onFaceView != null)
                  IconButton(
                    tooltip: 'Phone face view',
                    onPressed: onFaceView,
                    icon: const Icon(Icons.smartphone_outlined, size: 19),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _NavButton(
              icon: Icons.add,
              label: 'New conversation',
              trailing: 'Ctrl N',
              selected: state.section == Section.home,
              onTap: () => state.go(Section.home),
              strong: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 6),
            child: Text('Conversations', style: context.type.labelMedium),
          ),
          Expanded(
            child: tasks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text('Your conversations will show up here.', style: context.type.bodySmall),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final t in tasks) _ConversationTile(task: t, selected: state.selected == t.id, onTap: () => state.open(t.id)),
                    ],
                  ),
          ),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                _NavButton(
                  icon: Icons.notifications_none,
                  label: 'Updates',
                  selected: state.section == Section.updates,
                  onTap: () => state.go(Section.updates),
                  badge: core.unread,
                ),
                _NavButton(
                  icon: Icons.event_repeat,
                  label: 'Routines',
                  selected: state.section == Section.routines,
                  onTap: () => state.go(Section.routines),
                ),
                _NavButton(
                  icon: Icons.auto_awesome_outlined,
                  label: 'Memory',
                  selected: state.section == Section.memory,
                  onTap: () => state.go(Section.memory),
                ),
                _NavButton(
                  icon: Icons.tune,
                  label: 'Settings',
                  selected: state.section == Section.settings,
                  onTap: () => state.go(Section.settings),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.keyboard_outlined, size: 15, color: c.faint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Alt + Space opens the quick bar', style: context.type.labelMedium?.copyWith(color: c.faint)),
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
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.label, required this.selected, required this.onTap, this.trailing, this.strong = false, this.badge = 0});
  final int badge;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? trailing;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.raised : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 18, color: strong ? c.accent : c.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, style: context.type.labelLarge?.copyWith(color: strong ? c.accent : c.text)),
              ),
              if (trailing != null) Text(trailing!, style: context.type.labelMedium?.copyWith(color: c.faint)),
              if (badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(10)),
                  child: Text('$badge', style: TextStyle(color: c.onAccent, fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.task, required this.selected, required this.onTap});
  final TaskView task;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final waiting = task.pendingApproval != null;
    final at = (task.last?['at'] as num?)?.toDouble() ?? task.events.firstOrNull?['at'] as double? ?? 0;
    final (String label, Color color) = waiting
        ? ('Needs you', c.warning)
        : switch (task.status) {
            'running' => ('Working', c.accent),
            'failed' => ('Problem', c.danger),
            'stopped' => ('Stopped', c.faint),
            _ => ('Done', c.faint),
          };
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? c.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (task.fromRoutine) ...[
                            Icon(Icons.event_repeat, size: 14, color: c.accent),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              task.fromRoutine ? '${task.origin!['title']}' : titleOf(task),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (task.active && !waiting)
                            SizedBox.square(dimension: 9, child: CircularProgressIndicator(strokeWidth: 1.6, color: color))
                          else
                            Icon(Icons.circle, size: 7, color: color),
                          const SizedBox(width: 6),
                          Text(label, style: context.type.labelMedium?.copyWith(color: waiting ? c.warning : c.muted)),
                          const Spacer(),
                          Text(ago(at), style: context.type.labelMedium?.copyWith(color: c.faint)),
                        ],
                      ),
                    ],
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

/// Slim line for connection problems; nothing when all is well.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.core, required this.state});
  final CoreClient core;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (IconData, String, Color)? line = switch (core.status) {
      CoreStatus.offline => (Icons.power_off_outlined, 'Compii Core isn’t running. In compii_core run: uv run compii-core — I’ll reconnect by myself.', c.danger),
      CoreStatus.connecting => (Icons.sync, 'Connecting to Compii Core…', c.muted),
      CoreStatus.online when core.brain == 'rehearsal' => (Icons.theater_comedy_outlined, 'Rehearsal mode: scripted test runs, not AI.', c.warning),
      CoreStatus.online when !core.credentialsFound => (Icons.key_off_outlined, 'No Anthropic API key found. Set ANTHROPIC_API_KEY and restart Compii Core.', c.warning),
      _ => null,
    };
    final error = state.error;
    if (line == null && error == null) return const SizedBox.shrink();
    return Column(
      children: [
        if (line != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: line.$3.withValues(alpha: .1),
            child: Row(
              children: [
                Icon(line.$1, size: 16, color: line.$3),
                const SizedBox(width: 8),
                Expanded(child: Text(line.$2, style: context.type.bodySmall?.copyWith(color: c.text))),
              ],
            ),
          ),
        if (error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            color: c.dangerSoft,
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: c.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.bodySmall?.copyWith(color: c.text))),
                IconButton(onPressed: () => state.fail(null), icon: const Icon(Icons.close, size: 16), tooltip: 'Dismiss'),
              ],
            ),
          ),
      ],
    );
  }
}

/// The message box. Enter sends; Shift+Enter adds a line.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.core, required this.onSend, this.hint = 'Ask Compii to do something…', this.busyTask, this.run, this.autofocus = true, this.state});
  final CoreClient core;

  /// App state, for voice and the "typing" reaction.
  final AppState? state;
  final Future<void> Function(String text) onSend;
  final String hint;

  /// When set and working, the send button becomes Stop.
  final TaskView? busyTask;
  final Run? run;
  final bool autofocus;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() {
    setState(() {});
    widget.state?.setTyping(_text.text.trim().isNotEmpty);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || widget.core.status != CoreStatus.online) return;
    _text.clear();
    widget.state?.setTyping(false);
    await widget.onSend(t);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final online = widget.core.status == CoreStatus.online;
    final busy = widget.busyTask?.active ?? false;
    final voice = widget.state?.voice;
    final hearing = voice != null && (voice.listening || voice.busy);
    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _focus.hasFocus ? c.accent.withValues(alpha: .6) : c.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: hearing
                ? LiveTranscript(voice: voice)
                : Focus(
              onFocusChange: (_) => setState(() {}),
              onKeyEvent: (node, e) {
                if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
                  _send();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _text,
                focusNode: _focus,
                autofocus: widget.autofocus,
                enabled: online,
                minLines: 1,
                maxLines: 6,
                style: context.type.bodyLarge,
                decoration: InputDecoration(
                  hintText: online ? (busy ? 'Compii is working — you can stop it any time' : widget.hint) : 'Waiting for Compii Core…',
                  hintStyle: context.type.bodyLarge?.copyWith(color: c.faint),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          if (voice != null)
            MicButton(voice: voice, onSetup: () => widget.state?.go(Section.settings))
          else
            const SizedBox(width: 4),
          const SizedBox(width: 2),
          if (busy)
            IconButton.filled(
              tooltip: 'Stop',
              style: IconButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white),
              onPressed: () => widget.run?.call(() => widget.core.stop(widget.busyTask!.id)),
              icon: const Icon(Icons.stop_rounded, size: 20),
            )
          else
            IconButton.filled(
              tooltip: 'Send (Enter)',
              style: IconButton.styleFrom(backgroundColor: c.accent, foregroundColor: c.onAccent, disabledBackgroundColor: c.sunken),
              onPressed: online && _text.text.trim().isNotEmpty ? _send : null,
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}

const suggestions = [
  (Icons.receipt_long_outlined, 'Invoices to a spreadsheet', "Find last month's invoices in Downloads, put them in a spreadsheet and email it to me"),
  (Icons.cleaning_services_outlined, 'Tidy my Downloads', 'Tidy my Downloads folder: sort files into folders by type'),
  (Icons.summarize_outlined, 'Summarize a PDF', 'Summarize the newest PDF in my Downloads in five bullet points'),
  (Icons.travel_explore_outlined, 'Research something', 'Research the three best budget laptops this month and save a comparison table'),
];

class _Home extends StatelessWidget {
  const _Home({required this.core, required this.state, required this.run});
  final CoreClient core;
  final AppState state;
  final Run run;

  String get _greeting {
    final h = DateTime.now().hour;
    return h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
  }

  Future<void> _start(String text) async {
    try {
      final id = await core.startConversation(text);
      state.open(id);
    } catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.voice != null)
                TalkableOrbling(voice: state.voice!, mood: state.moodWith(core), jobs: core.ordered.where((t) => t.active).length)
              else
                SizedBox.square(dimension: 150, child: Orbling(mood: moodOf(core), jobs: core.ordered.where((t) => t.active).length)),
              const SizedBox(height: 8),
              Text(_greeting, style: context.type.headlineMedium),
              const SizedBox(height: 6),
              Text(
                state.voice?.canListen == true
                    ? 'What should we get done? Type, or click me and just say it.'
                    : 'What should we get done?',
                style: context.type.bodyLarge?.copyWith(color: c.muted),
              ),
              const SizedBox(height: 24),
              Composer(core: core, onSend: _start, state: state),
              const SizedBox(height: 22),
              BriefCard(core: core, run: run),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  for (final (icon, label, prompt) in suggestions)
                    ActionChip(
                      avatar: Icon(icon, size: 17, color: c.accent),
                      label: Text(label),
                      labelStyle: context.type.labelLarge?.copyWith(color: c.text),
                      backgroundColor: c.raised,
                      side: BorderSide(color: c.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      onPressed: core.status == CoreStatus.online ? () => _start(prompt) : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation({required this.task, required this.core, required this.run, required this.state});
  final AppState state;
  final TaskView task;
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
          child: Row(
            children: [
              Expanded(child: Text(titleOf(task), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.titleMedium)),
              if (task.active)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: c.danger, side: BorderSide(color: c.danger.withValues(alpha: .4))),
                  onPressed: () => run(() => core.stop(task.id)),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('Stop'),
                ),
            ],
          ),
        ),
        Expanded(child: ThreadView(task: task, core: core, run: run)),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Composer(
              core: core,
              state: state,
              hint: 'Follow up…',
              busyTask: task,
              run: run,
              onSend: (text) => run(() => core.reply(task.id, text)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Right panel (Claude Cowork-style): the live plan and every file touched.
class ProgressPanel extends StatelessWidget {
  const ProgressPanel({super.key, required this.task, required this.core, required this.run});
  final TaskView task;
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final turns = turnsOf(task);
    final plan = turns.reversed.map((t) => t.plan).whereType<List<Map<String, dynamic>>>().firstOrNull;
    final files = [for (final t in turns) ...t.files];
    final steps = [for (final t in turns) ...t.finished];
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(s, style: context.type.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
    );
    return Container(
      width: 320,
      decoration: BoxDecoration(color: c.surface, border: Border(left: BorderSide(color: c.border))),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Progress', style: context.type.titleMedium),
          const SizedBox(height: 16),
          heading('PLAN'),
          if (plan == null)
            Text('Compii shows a plan here for anything with several steps.', style: context.type.bodySmall)
          else
            PlanList(steps: plan),
          const SizedBox(height: 22),
          heading('FILES'),
          if (files.isEmpty)
            Text('Files Compii creates or changes appear here.', style: context.type.bodySmall)
          else
            for (final f in files)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: FileChip(file: f, core: core, run: run)),
          const SizedBox(height: 22),
          heading('ACTIVITY'),
          Text(
            steps.isEmpty
                ? 'Nothing done yet.'
                : '${steps.length} ${steps.length == 1 ? 'action' : 'actions'} · ${steps.where((s) => s['ok'] != true).length} failed · every one is in the action journal',
            style: context.type.bodySmall,
          ),
        ],
      ),
    );
  }
}
