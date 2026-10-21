import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'pages.dart';
import 'proactive.dart';
import 'thread.dart';
import 'tokens.dart';
import 'trust.dart';
import 'voice.dart';
import 'voice_dock.dart';
import 'stage.dart';
import 'chrome.dart';
import 'glyphs.dart';

enum Section { home, chat, updates, routines, skills, memory, safety, settings }

/// App-wide UI state shared by the workspace and the quick bar.
class AppState extends ChangeNotifier {
  Section section = Section.home;
  String? selected;
  ThemeMode themeMode = ThemeMode.system;

  /// Replies as a chat history instead of the character's speech bubble.
  bool chatView = false;

  void setChatView(bool v) {
    chatView = v;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool('chat_view', v)).ignore();
  }

  /// Restore saved preferences (chat view, theme).
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      chatView = p.getBool('chat_view') ?? false;
      themeMode = ThemeMode.values.byName(p.getString('theme') ?? 'system');
      notifyListeners();
    } on Object {
      // first run or no storage: defaults
    }
  }
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
    SharedPreferences.getInstance().then((p) => p.setString('theme', m.name)).ignore();
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

  String? _title(TaskView? task) => switch (state.section) {
    Section.chat when task != null => null, // the conversation has its own header
    _ => null,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([core, core.sight, state, ?state.voice]),
    builder: (context, _) {
      final c = context.c;
      final task = state.selected == null ? null : core.tasks[state.selected];
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => state.go(Section.home),
        },
        child: Scaffold(
          backgroundColor: c.canvas,
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
                        TitleBar(title: _title(task)),
                        _StatusLine(core: core, state: state),
                        LockdownBanner(run: _run),
                        const WalkthroughBar(),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: KeyedSubtree(
                              key: ValueKey('${state.section}-${state.selected}'),
                              child: switch (state.section) {
                                Section.memory => MemoryPage(core: core, run: _run),
                                Section.routines => RoutinesPage(core: core, run: _run),
                                Section.skills => SkillsPage(run: _run, onOpenTask: state.open),
                                Section.safety => SafetyPage(run: _run),
                                Section.updates => UpdatesPage(core: core, run: _run, onOpenTask: state.open),
                                Section.settings => SettingsPage(core: core, state: state, run: _run),
                                Section.chat when task != null && state.chatView => _Conversation(task: task, core: core, run: _run, state: state),
                                Section.chat when task != null => Stage(task: task, core: core, state: state, run: _run),
                                _ => _Home(core: core, state: state, run: _run),
                              },
                            ),
                          ),
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
    final jobs = tasks.where((t) => t.active).length;
    final (String status, Color statusColor) = switch (mood) {
      Mood.offline => ('Offline', c.danger),
      Mood.waiting => ('Needs you', c.warning),
      Mood.listening => ('Listening', c.listen),
      Mood.thinking || Mood.acting => (jobs > 1 ? 'Working on $jobs things' : 'Working', c.accent),
      Mood.speaking => ('Speaking', c.accent),
      _ => (voice?.wakeListening == true ? 'Say “Hey Compii”' : 'Ready', c.success),
    };
    return Container(
      width: 272,
      decoration: BoxDecoration(color: c.surface, border: Border(right: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DragStrip(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 10, 14),
              child: Row(
                children: [
                  if (voice != null)
                    TalkableOrbling(voice: voice, mood: mood, jobs: jobs, size: 40)
                  else
                    SizedBox.square(dimension: 38, child: Orbling(mood: mood, jobs: jobs)),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Compii', style: context.type.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.4)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(width: 7, height: 7, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle,
                                boxShadow: [BoxShadow(color: statusColor.withValues(alpha: .5), blurRadius: 6)])),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: context.type.labelMedium?.copyWith(color: mood == Mood.idle ? c.muted : statusColor)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (onFaceView != null)
                    IconButton(tooltip: 'Face view (for a phone or second screen)', onPressed: onFaceView, icon: const Glyph(G.pip, size: 18)),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _NewButton(selected: state.section == Section.home, onTap: () => state.go(Section.home)),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                _NavButton(glyph: G.bell, label: 'Updates', selected: state.section == Section.updates,
                    onTap: () => state.go(Section.updates), badge: core.unread),
                _NavButton(glyph: G.routine, label: 'Routines', selected: state.section == Section.routines,
                    onTap: () => state.go(Section.routines)),
                _NavButton(glyph: G.skill, label: 'Skills', selected: state.section == Section.skills,
                    onTap: () => state.go(Section.skills)),
                _NavButton(glyph: G.memory, label: 'Memory', selected: state.section == Section.memory,
                    onTap: () => state.go(Section.memory)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 16, 8),
            child: Text('RECENT', style: context.type.labelSmall),
          ),
          Expanded(
            child: tasks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text('Conversations you start appear here.', style: context.type.bodySmall?.copyWith(color: c.faint)),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      for (final t in tasks) _ConversationTile(task: t, selected: state.selected == t.id, onTap: () => state.open(t.id)),
                    ],
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
            child: Column(
              children: [
                _NavButton(glyph: G.shield, label: 'Safety', selected: state.section == Section.safety,
                    onTap: () => state.go(Section.safety)),
                _NavButton(glyph: G.sliders, label: 'Settings', selected: state.section == Section.settings,
                    onTap: () => state.go(Section.settings)),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Talk', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: context.type.labelMedium?.copyWith(color: c.faint)),
                      ),
                      const Kbd('Ctrl + Alt'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The main call to action at the top of the sidebar.
class _NewButton extends StatefulWidget {
  const _NewButton({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_NewButton> createState() => _NewButtonState();
}

class _NewButtonState extends State<_NewButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: Shapes.r12,
            border: Border.all(color: _hover || widget.selected ? c.accent.withValues(alpha: .45) : c.border),
            boxShadow: Shapes.card(c),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: c.accent, borderRadius: Shapes.r6),
                alignment: Alignment.center,
                child: Glyph(G.plus, size: 15, color: c.onAccent, weight: 2.2),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('New conversation', style: context.type.labelLarge)),
              const Kbd('Ctrl + N'),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({required this.glyph, required this.label, required this.selected, required this.onTap, this.badge = 0});
  final int badge;
  final GlyphData glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: on ? c.raised : (_hover ? c.hover.withValues(alpha: .7) : Colors.transparent),
            borderRadius: Shapes.r10,
            border: Border.all(color: on ? c.border : Colors.transparent),
            boxShadow: on ? Shapes.card(c) : null,
          ),
          child: Row(
            children: [
              Glyph(widget.glyph, size: 18, color: on ? c.accent : c.muted, duo: on),
              const SizedBox(width: 11),
              Expanded(
                child: Text(widget.label,
                    style: context.type.labelLarge?.copyWith(color: on ? c.text : c.muted, fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
              ),
              if (widget.badge > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(color: c.warning, borderRadius: BorderRadius.circular(10)),
                  child: Text('${widget.badge}', textAlign: TextAlign.center,
                      style: TextStyle(color: c.dark ? c.canvas : Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatefulWidget {
  const _ConversationTile({required this.task, required this.selected, required this.onTap});
  final TaskView task;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final task = widget.task;
    final selected = widget.selected;
    final waiting = task.pendingApproval != null;
    final at = (task.last?['at'] as num?)?.toDouble() ?? task.events.firstOrNull?['at'] as double? ?? 0;
    final (String label, Color color) = waiting
        ? ('Needs you', c.warning)
        : switch (task.status) {
            'running' => ('Working', c.accent),
            'failed' => ('Problem', c.danger),
            'stopped' => ('Stopped', c.faint),
            _ => ('Done', c.success),
          };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          decoration: BoxDecoration(
            color: selected ? c.raised : (_hover ? c.hover.withValues(alpha: .7) : Colors.transparent),
            borderRadius: Shapes.r10,
            border: Border.all(color: selected ? c.border : Colors.transparent),
            boxShadow: selected ? Shapes.card(c) : null,
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(color: waiting || task.active ? color : Colors.transparent, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (task.fromRoutine) ...[
                          Glyph(G.routine, size: 13, color: c.accent),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            task.fromRoutine ? '${task.origin!['title']}' : titleOf(task),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.bodyMedium?.copyWith(fontWeight: selected ? FontWeight.w600 : FontWeight.w500, height: 1.3),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (task.active && !waiting)
                          SizedBox.square(dimension: 9, child: CircularProgressIndicator(strokeWidth: 1.6, color: color))
                        else
                          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(label, style: context.type.labelMedium?.copyWith(color: waiting ? c.warning : c.muted, fontSize: 11.5)),
                        const Spacer(),
                        Text(ago(at), style: context.type.labelMedium?.copyWith(color: c.faint, fontSize: 11.5)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim notices for connection problems and errors; nothing when all is well.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.core, required this.state});
  final CoreClient core;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (GlyphData, String, Color)? line = switch (core.status) {
      CoreStatus.offline => (G.power, 'Compii Core isn’t running. Start it with “uv run compii-core” in compii_core — I’ll reconnect by myself.', c.danger),
      CoreStatus.connecting => (G.sync, 'Connecting to Compii Core…', c.muted),
      CoreStatus.online when core.brain == 'rehearsal' => (G.flask, 'Rehearsal mode — scripted test runs, not AI.', c.warning),
      CoreStatus.online when !core.credentialsFound => (G.key, 'No AI connected yet. Pick one in Settings → Brain — NVIDIA, Groq, Gemini and Ollama Cloud have free tiers.', c.warning),
      CoreStatus.online when core.sight.value['screen_aware'] == false =>
          (G.eyeOff, 'Compii isn’t seeing your screen. Screen reading is off, so it can’t help with the app in front '
              'of you — turn it on in Settings → Voice.', c.muted),
      _ => null,
    };
    final error = state.error;
    if (line == null && error == null) return const SizedBox.shrink();
    Widget notice(GlyphData g, String text, Color color, {VoidCallback? onClose}) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 8, onClose == null ? 12 : 4, 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: c.dark ? .14 : .09),
          borderRadius: Shapes.r12,
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Row(
          children: [
            Glyph(g, size: 16, color: color, duo: true),
            const SizedBox(width: 10),
            Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.bodySmall?.copyWith(color: c.text))),
            if (onClose != null)
              IconButton(onPressed: onClose, icon: const Glyph(G.close, size: 14), tooltip: 'Dismiss', visualDensity: VisualDensity.compact),
          ],
        ),
      ),
    );
    return Column(
      children: [
        if (line != null) notice(line.$1, line.$2, line.$3),
        if (error != null) notice(G.alert, error, c.danger, onClose: () => state.fail(null)),
      ],
    );
  }
}

/// The message box. Enter sends; Shift+Enter adds a line.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.core, required this.onSend, this.hint = 'Ask Compii to do something…', this.busyTask, this.run, this.autofocus = true, this.state, this.large = false, this.seed = '', this.onVoice});
  final CoreClient core;

  /// App state, for voice and the "typing" reaction.
  final AppState? state;
  final Future<void> Function(String text) onSend;
  final String hint;

  /// When set and working, the send button becomes Stop.
  final TaskView? busyTask;
  final Run? run;
  final bool autofocus;

  /// The big one on the home screen.
  final bool large;

  /// Text to start with (the key that opened the box).
  final String seed;

  /// Back to talking (voice-first screens); replaces the mic button.
  final VoidCallback? onVoice;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.seed.isNotEmpty) {
      _text.text = widget.seed;
      _text.selection = TextSelection.collapsed(offset: widget.seed.length);
    }
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
    final focused = _focus.hasFocus || hearing;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(widget.large ? 22 : 18),
        border: Border.all(color: hearing ? c.listen : focused ? c.accent.withValues(alpha: .7) : c.borderStrong, width: focused ? 1.5 : 1),
        boxShadow: [
          ...Shapes.float(c),
          if (focused) BoxShadow(color: (hearing ? c.listen : c.accent).withValues(alpha: .14), blurRadius: 0, spreadRadius: 4),
        ],
      ),
      padding: EdgeInsets.fromLTRB(widget.large ? 20 : 18, widget.large ? 10 : 6, 8, widget.large ? 10 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: hearing
                ? LiveTranscript(voice: voice)
                : Focus(
              onFocusChange: (_) => setState(() {}),
              onKeyEvent: (node, e) {
                if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && widget.onVoice != null) {
                  widget.onVoice!();
                  return KeyEventResult.handled;
                }
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
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          if (widget.onVoice != null)
            IconButton(tooltip: 'Back to talking (Esc)', onPressed: widget.onVoice, icon: const Glyph(G.wave, size: 19))
          else
            const SizedBox(width: 4),
          const SizedBox(width: 2),
          if (busy)
            _RoundButton(
              tooltip: 'Stop',
              color: c.danger,
              onPressed: () => widget.run?.call(() => widget.core.stop(widget.busyTask!.id)),
              child: const Glyph(G.stop, size: 16, color: Colors.white, duo: true, duoColor: Colors.white),
            )
          else
            _RoundButton(
              tooltip: 'Send (Enter)',
              color: c.accent,
              onPressed: online && _text.text.trim().isNotEmpty ? _send : null,
              child: Glyph(G.arrowUp, size: 18, color: c.onAccent, weight: 2.2),
            ),
        ],
      ),
    );
  }
}

/// The send / stop button on the composer.
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.color, required this.onPressed, required this.child});
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: on ? color : c.sunken,
              shape: BoxShape.circle,
              boxShadow: on ? [BoxShadow(color: color.withValues(alpha: .35), blurRadius: 12, offset: const Offset(0, 4))] : null,
            ),
            alignment: Alignment.center,
            child: on ? child : Glyph(G.arrowUp, size: 18, color: c.faint, weight: 2.2),
          ),
        ),
      ),
    );
  }
}

const suggestions = [
  (G.receipt, 'Invoices → spreadsheet', 'Last month’s invoices from Downloads, totalled and emailed', "Find last month's invoices in Downloads, put them in a spreadsheet and email it to me"),
  (G.broom, 'Tidy my Downloads', 'Sort every file into folders by type', 'Tidy my Downloads folder: sort files into folders by type'),
  (G.doc, 'Summarize a PDF', 'The newest PDF in Downloads, in five bullets', 'Summarize the newest PDF in my Downloads in five bullet points'),
  (G.search, 'Research something', 'Three best budget laptops, as a comparison table', 'Research the three best budget laptops this month and save a comparison table'),
];

class _Home extends StatelessWidget {
  const _Home({required this.core, required this.state, required this.run});
  final CoreClient core;
  final AppState state;
  final Run run;

  String get _greeting {
    final h = DateTime.now().hour;
    return h < 5 ? 'Up late' : h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
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
    final mood = state.moodWith(core);
    final jobs = core.ordered.where((t) => t.active).length;
    // The character is the star: big on a normal window, smaller when space is tight.
    final hero = (MediaQuery.sizeOf(context).height * .3).clamp(150.0, 270.0);
    final online = core.status == CoreStatus.online;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Aura(
                size: hero * 1.55,
                color: switch (mood) {
                  Mood.listening => c.listen,
                  Mood.waiting => c.warning,
                  Mood.problem || Mood.offline => c.danger,
                  _ => c.accent,
                },
                child: state.voice != null
                    ? TalkableOrbling(voice: state.voice!, mood: mood, jobs: jobs, size: hero)
                    : SizedBox.square(dimension: hero, child: Orbling(mood: mood, jobs: jobs)),
              ),
              Text('$_greeting.', style: context.type.displaySmall, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('What should we get done?', style: context.type.bodyLarge?.copyWith(color: c.muted), textAlign: TextAlign.center),
              const SizedBox(height: 22),
              VoiceDock(core: core, state: state, onSend: _start, run: run, showCharacter: false),
              const SizedBox(height: 26),
              TrySaying(
                items: [for (final (g, title, _, prompt) in suggestions) (g, title, prompt)],
                onPick: online ? _start : null,
              ),
              const SizedBox(height: 22),
              BriefCard(core: core, run: run),
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
    final waiting = task.pendingApproval != null;
    final (String label, Color color) = waiting
        ? ('Needs you', c.warning)
        : switch (task.status) {
            'running' => ('Working', c.accent),
            'failed' => ('Problem', c.danger),
            'stopped' => ('Stopped', c.faint),
            _ => ('Done', c.success),
          };
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(28, 4, 20, 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titleOf(task), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.headlineSmall),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Pill(label, color: color),
                        if (core.sight.value['looking'] == true) ...[
                          const SizedBox(width: 6),
                          Pill('Seeing your screen', color: c.accent, glyph: G.eye),
                        ],
                        if (task.fromRoutine) ...[
                          const SizedBox(width: 6),
                          Pill('Routine', color: c.accent, glyph: G.routine),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (task.status == 'done' && !task.fromRoutine) SaveSkillButton(task: task, run: run),
              TextButton.icon(
                onPressed: () => state.setChatView(false),
                icon: const Glyph(G.memory, size: 16),
                label: const Text('Character view'),
              ),
              if (task.active)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: c.danger, side: BorderSide(color: c.danger.withValues(alpha: .4))),
                  onPressed: () => run(() => core.stop(task.id)),
                  icon: const Glyph(G.stop, size: 16, duo: true),
                  label: const Text('Stop'),
                ),
            ],
          ),
        ),
        Expanded(child: ThreadView(task: task, core: core, run: run)),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: VoiceDock(
              core: core,
              state: state,
              hint: 'Follow up…',
              task: task,
              run: run,
              onSend: (text) => run(() => core.reply(task.id, text)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Right panel: the live plan, every file touched, and the action count.
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
    final failed = steps.where((s) => s['ok'] != true).length;
    Widget heading(String s, [String? count]) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(s, style: context.type.labelSmall),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(count, style: context.type.labelSmall?.copyWith(color: c.muted)),
          ],
        ],
      ),
    );
    final done = plan?.where((s) => s['status'] == 'done').length ?? 0;
    return Container(
      width: 320,
      decoration: BoxDecoration(color: c.surface, border: Border(left: BorderSide(color: c.border))),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        children: [
          Text('Progress', style: context.type.titleLarge),
          const SizedBox(height: 14),
          if (plan != null && plan.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: done / plan.length, minHeight: 5),
            ),
            const SizedBox(height: 6),
            Text('$done of ${plan.length} steps', style: context.type.labelMedium),
            const SizedBox(height: 18),
          ],
          heading('PLAN'),
          if (plan == null)
            Text('For anything with several steps, Compii lays out a plan here and ticks it off as it goes.', style: context.type.bodySmall)
          else
            PlanList(steps: plan),
          const SizedBox(height: 24),
          heading('FILES', files.isEmpty ? null : '${files.length}'),
          if (files.isEmpty)
            Text('Files Compii creates or changes show up here, ready to open.', style: context.type.bodySmall)
          else
            for (final f in files)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: FileChip(file: f, core: core, run: run)),
          const SizedBox(height: 24),
          heading('ACTIVITY'),
          Panel(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                _Stat(value: '${steps.length}', label: steps.length == 1 ? 'action' : 'actions'),
                Container(width: 1, height: 28, color: c.border, margin: const EdgeInsets.symmetric(horizontal: 14)),
                _Stat(value: '$failed', label: 'failed', color: failed > 0 ? c.danger : null),
                const Spacer(),
                Tooltip(
                  message: 'Every action is in the journal and the tamper-evident activity record (Safety).',
                  child: Glyph(G.shieldCheck, size: 18, color: c.success, duo: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.color});
  final String value;
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: context.type.titleLarge?.copyWith(color: color)),
      Text(label, style: context.type.labelMedium),
    ],
  );
}
