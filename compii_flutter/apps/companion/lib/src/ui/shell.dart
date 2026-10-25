import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../art/halo.dart';
import '../console/character.dart';
import '../console/core_client.dart';
import 'bots.dart';
import 'clips.dart';
import 'conversation_io.dart';
import 'pages.dart';
import 'proactive.dart';
import 'thread.dart';
import 'timeline.dart';
import 'tokens.dart';
import 'trust.dart';
import 'voice.dart';
import 'voice_dock.dart';
import 'stage.dart';
import 'team.dart';
import 'library.dart';
import 'knowledge.dart';
import 'research.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'palette.dart';

enum Section { home, chat, team, updates, routines, skills, library, knowledge, research, memory, timeline, clips, safety, settings }

/// App-wide UI state shared by the workspace and the quick bar.
class AppState extends ChangeNotifier {
  Section section = Section.home;
  String? selected;

  /// Which bot new conversations go to; null means Compii itself.
  String? botId;

  /// A team chosen for the next conversation (2–6 bot ids). Empty for a normal chat.
  List<String> team = [];
  ThemeMode themeMode = ThemeMode.system;

  /// A particular thing inside a page that search asked to show (a memory, a
  /// moment, a routine). Cleared whenever the user navigates themselves.
  String? focusKind;
  String? focusId;
  String? focusQuery;
  String? focusTab;

  /// When each teammate's threads were last opened, to show what is new.
  final Map<String, double> botSeen = {};
  final double _started = DateTime.now().millisecondsSinceEpoch / 1000;

  /// Finished work this bot did since its list was last opened.
  int unreadFor(CoreClient core, String botId) => core.ordered
      .where((t) =>
          t.botId == botId &&
          ((t.last?['at'] as num?)?.toDouble() ?? 0) > (botSeen[botId] ?? _started))
      .length;

  void markBotSeen(String? id) {
    if (id == null) return;
    botSeen[id] = DateTime.now().millisecondsSinceEpoch / 1000;
    notifyListeners();
    _saveSeen();
  }

  void _saveSeen() {
    SharedPreferences.getInstance()
        .then((p) => p.setString('bot_seen', jsonEncode(botSeen)))
        .ignore();
  }

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
      restoreCompiiLook(p);
      final seen = p.getString('bot_seen');
      if (seen != null) {
        final decoded = jsonDecode(seen);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            if (e.value is num) botSeen['${e.key}'] = (e.value as num).toDouble();
          }
        }
      }
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
    focusKind = focusId = focusQuery = focusTab = null;
    notifyListeners();
  }

  void go(Section s) {
    section = s;
    if (s != Section.chat) selected = null;
    focusKind = focusId = focusQuery = focusTab = null;
    if (s == Section.home) {
      botId = null;
      team = [];
    }
    notifyListeners();
  }

  /// Open a page straight onto something search found (a memory, a moment, a routine…).
  void goDeep(Section s, {String? kind, String? id, String? query, String? tab}) {
    section = s;
    selected = null;
    focusKind = kind;
    focusId = id;
    focusQuery = query;
    focusTab = tab;
    notifyListeners();
  }

  /// Start a new conversation as this bot (null: Compii itself).
  void pickBot(String? id) {
    botId = id;
    team = [];
    selected = null;
    section = Section.home;
    focusKind = focusId = focusQuery = focusTab = null;
    markBotSeen(id);
    notifyListeners();
  }

  /// Start a new conversation shared by several teammates; the first speaks first.
  void pickTeam(List<String> ids) {
    team = List.of(ids.take(6));
    botId = team.isEmpty ? null : team.first;
    selected = null;
    section = Section.home;
    focusKind = focusId = focusQuery = focusTab = null;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    for (final id in team) {
      botSeen[id] = now;
    }
    notifyListeners();
    _saveSeen();
  }

  void setTheme(ThemeMode m) {
    themeMode = m;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString('theme', m.name)).ignore();
  }

  /// Which body Compii wears. The face and the moods are the same either way, so
  /// this is taste rather than a setting the PC needs to know about.
  CompiiBody get body => compiiBody.value;

  void setBody(CompiiBody b) {
    if (compiiBody.value == b) return;
    compiiBody.value = b;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString('compii_form', b.name)).ignore();
  }

  /// The colour Compii's fur is brushed in: any colour at all. Taste, not state.
  Color get color => compiiColor.value;

  void setColor(Color c) {
    if (compiiColor.value == c) return;
    compiiColor.value = c;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString('compii_coat', colorHex(c))).ignore();
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
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showCommandPalette(
                context: context,
                core: core,
                state: state,
                run: _run,
              ),
        },
        child: Scaffold(
          backgroundColor: c.canvas,
          drawerScrimColor: c.scrim,
          drawer: Drawer(
            backgroundColor: c.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
            ),
            child: SafeArea(child: _Sidebar(core: core, state: state, onFaceView: onFaceView)),
          ),
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
                        TitleBar(
                          title: _title(task),
                          leading: showSidebar ? null : IconButton(
                            tooltip: 'Open navigation', icon: const Glyph(G.menu, size: 22),
                            onPressed: () => Scaffold.of(context).openDrawer()),
                          actions: [
                            PaletteButton(
                              onTap: () => showCommandPalette(
                                context: context,
                                core: core,
                                state: state,
                                run: _run,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                        ),
                        _StatusLine(core: core, state: state),
                        LockdownBanner(run: _run),
                        const WalkthroughBar(),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: context.motion(Motion.page),
                            switchInCurve: Motion.out,
                            switchOutCurve: Motion.standard,
                            transitionBuilder: (child, animation) {
                              final arrive = CurvedAnimation(parent: animation, curve: Motion.out);
                              return FadeTransition(
                                opacity: arrive,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, .016),
                                    end: Offset.zero,
                                  ).animate(arrive),
                                  child: ScaleTransition(
                                    scale: Tween<double>(begin: .996, end: 1).animate(arrive),
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: KeyedSubtree(
                              key: ValueKey('${state.section}-${state.selected}'),
                              child: switch (state.section) {
                                Section.memory => MemoryPage(core: core, run: _run,
                                    focusId: state.focusKind == 'memory' ? state.focusId : null),
                                Section.timeline => TimelinePage(core: core, run: _run,
                                    focusQuery: state.focusKind == 'moment' ? state.focusQuery : null),
                                Section.clips => ClipsPage(core: core, run: _run,
                                    focusQuery: (state.focusKind == 'clip' || state.focusKind == 'snippet')
                                        ? state.focusQuery : null,
                                    focusSnippets: state.focusTab == 'snippets'),
                                Section.routines => RoutinesPage(core: core, run: _run, onOpenTask: state.open,
                                    focusId: state.focusKind == 'routine' ? state.focusId : null),
                                Section.skills => SkillsPage(run: _run, onOpenTask: state.open),
                                Section.library => LibraryPage(run: _run),
                                Section.knowledge => KnowledgePage(run: _run),
                                Section.research => ResearchPage(run: _run),
                                Section.team => TeamPage(core: core, state: state, run: _run),
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

  void _newTeammate(BuildContext context) {
    Future<void> act(Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        state.fail(e);
      }
    }

    showBotEditor(context, core: core, state: state, run: act);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mood = state.moodWith(core);
    final tasks = core.ordered;
    final voice = state.voice;
    // A teammate the user put away keeps a lane here — its conversations have to stay reachable —
    // but it sits under the team and asks for nothing: no waiting count, no new work.
    final team = [for (final b in core.bots) if (!b.archived) b].take(8).toList();
    final away = [for (final b in core.bots) if (b.archived) b];
    final jobs = tasks.where((t) => t.active).length;
    final (String status, Color statusColor) = switch (mood) {
      Mood.offline => ('Offline', c.danger),
      Mood.waiting => ('Needs you', c.warning),
      Mood.listening => ('Listening', c.listen),
      Mood.thinking || Mood.acting => (jobs > 1 ? 'Working on $jobs things' : 'Working', c.accent),
      Mood.speaking => ('Speaking', c.accent),
      _ => (voice?.wakeListening == true ? 'Say “Hey Compii”' : 'Ready', c.success),
    };
    Widget group(String label, {List<Widget> actions = const []}) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 2, 4),
      child: Row(
        children: [
          Expanded(child: Eyebrow(label)),
          ...actions,
        ],
      ),
    );
    return Container(
      width: 276,
      decoration: BoxDecoration(color: c.surface, border: Border(right: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DragStrip(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 10, 12),
              child: Row(
                children: [
                  if (voice != null)
                    TalkableCompii(voice: voice, mood: mood, jobs: jobs, size: 40)
                  else
                    SizedBox.square(dimension: 38, child: Ember(mood: mood, jobs: jobs)),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Compii', style: context.type.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.4)),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            AnimatedContainer(
                              duration: context.motion(Motion.base),
                              curve: Motion.standard,
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                                boxShadow: [BoxShadow(color: statusColor.withValues(alpha: .5), blurRadius: 6)],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: AnimatedSwitcher(
                                duration: context.motion(Motion.quick),
                                child: Text(status,
                                    key: ValueKey(status),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.type.labelMedium?.copyWith(color: mood == Mood.idle ? c.muted : statusColor)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (onFaceView != null)
                    IconButton(tooltip: 'Presence view (for a phone or second screen)', onPressed: onFaceView, icon: const Glyph(G.pip, size: 18)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                  child: _NewButton(
                    selected: state.section == Section.home && state.botId == null,
                    onTap: () => state.go(Section.home),
                  ),
                ),
                if (core.bots.isNotEmpty) ...[
                  group('Team', actions: [
                    IconButton(
                      tooltip: 'New team chat',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => showTeamPicker(context, core: core, state: state),
                      icon: const Glyph(G.team, size: 15),
                    ),
                    IconButton(
                      tooltip: 'New teammate',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _newTeammate(context),
                      icon: const Glyph(G.plus, size: 14),
                    ),
                  ]),
                  for (final bot in team)
                    _TeamRow(
                      bot: bot,
                      core: core,
                      state: state,
                      unread: state.unreadFor(core, bot.id),
                      selected: state.section == Section.home &&
                          (state.botId == bot.id || (bot.primary && state.botId == null)),
                      onTap: () {
                        state.markBotSeen(bot.id);
                        state.pickBot(bot.primary ? null : bot.id);
                      },
                    ),
                  for (final bot in away.take(3))
                    _TeamRow(
                      bot: bot,
                      core: core,
                      state: state,
                      selected: state.section == Section.home && state.botId == bot.id,
                      onTap: () => state.pickBot(bot.id),
                    ),
                  if (away.length > 3)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 2, 6, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => state.go(Section.team),
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                          icon: Glyph(G.box, size: 12, color: c.faint),
                          label: Text('${away.length} put away',
                              style: context.type.labelMedium?.copyWith(color: c.faint)),
                        ),
                      ),
                    ),
                ],
                group('Workspace'),
                _NavButton(glyph: G.team, label: 'Team', selected: state.section == Section.team,
                    onTap: () => state.go(Section.team)),
                _NavButton(glyph: G.bell, label: 'Updates', selected: state.section == Section.updates,
                    onTap: () => state.go(Section.updates), badge: core.unread),
                _NavButton(glyph: G.routine, label: 'Routines', selected: state.section == Section.routines,
                    onTap: () => state.go(Section.routines)),
                _NavButton(glyph: G.skill, label: 'Skills', selected: state.section == Section.skills,
                    onTap: () => state.go(Section.skills)),
                const SizedBox(height: 6),
                _NavButton(glyph: G.box, label: 'Library', selected: state.section == Section.library,
                    onTap: () => state.go(Section.library)),
                _NavButton(glyph: G.search, label: 'Knowledge', selected: state.section == Section.knowledge,
                    onTap: () => state.go(Section.knowledge)),
                _NavButton(glyph: G.globe, label: 'Research', selected: state.section == Section.research,
                    onTap: () => state.go(Section.research)),
                const SizedBox(height: 6),
                _NavButton(glyph: G.memory, label: 'Memory', selected: state.section == Section.memory,
                    onTap: () => state.go(Section.memory)),
                _NavButton(glyph: G.clock, label: 'Timeline', selected: state.section == Section.timeline,
                    onTap: () => state.go(Section.timeline)),
                _NavButton(glyph: G.clipboard, label: 'Clips', selected: state.section == Section.clips,
                    onTap: () => state.go(Section.clips)),
                group('Recent'),
                if (tasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
                    child: Text('Conversations you start appear here.', style: context.type.bodySmall?.copyWith(color: c.faint)),
                  )
                else
                  for (final t in tasks)
                    _ConversationTile(
                      task: t,
                      bot: core.botFor(t.botId),
                      selected: state.selected == t.id,
                      onTap: () {
                        state.markBotSeen(t.botId);
                        state.open(t.id);
                      },
                    ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
            child: Column(
              children: [
                _NavButton(glyph: G.shield, label: 'Safety', selected: state.section == Section.safety,
                    onTap: () => state.go(Section.safety)),
                _NavButton(glyph: G.sliders, label: 'Settings', selected: state.section == Section.settings,
                    onTap: () => state.go(Section.settings)),
                const SizedBox(height: 8),
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
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final lit = _hover || widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (v) => setState(() => _down = v),
        child: AnimatedScale(
          scale: _down ? .988 : 1,
          duration: context.motion(_down ? Motion.tap : Motion.base),
          curve: Motion.spring,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            curve: Motion.standard,
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.selected ? c.accentSoft : c.raised,
              borderRadius: Shapes.r12,
              border: Border.all(color: lit ? c.accent.withValues(alpha: .35) : c.border),
              boxShadow: _hover ? Shapes.lift(c) : Shapes.card(c),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: context.motion(Motion.quick),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(color: c.accent, borderRadius: Shapes.r8),
                  alignment: Alignment.center,
                  child: Glyph(G.plus, size: 15, color: c.onAccent, weight: 2.2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('New conversation',
                      style: context.type.labelLarge?.copyWith(color: widget.selected ? c.accent : c.text)),
                ),
                const Kbd('Ctrl + N'),
              ],
            ),
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
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: Shapes.r10,
        child: AnimatedContainer(
          duration: context.motion(Motion.quick),
          curve: Motion.standard,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: on ? c.accentSoft : (_hover ? c.hover.withValues(alpha: .65) : Colors.transparent),
            borderRadius: Shapes.r10,
          ),
          child: Row(
            children: [
              Glyph(widget.glyph, size: 18, color: on ? c.accent : c.muted, duo: on),
              const SizedBox(width: 11),
              Expanded(
                child: Text(widget.label,
                    style: context.type.labelLarge?.copyWith(
                      color: on ? c.accent : (_hover ? c.text : c.muted),
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                    )),
              ),
              if (widget.badge > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(color: c.warning, borderRadius: Shapes.pill),
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

/// One teammate in the sidebar: its face, name, and a small menu.
class _TeamRow extends StatefulWidget {
  const _TeamRow({required this.bot, required this.core, required this.state, required this.selected, required this.onTap, this.unread = 0});
  final BotView bot;
  final CoreClient core;
  final AppState state;
  final int unread;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TeamRow> createState() => _TeamRowState();
}

class _TeamRowState extends State<_TeamRow> {
  bool _hover = false;

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      widget.state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bot = widget.bot;
    final on = widget.selected;
    // Retired, not gone: the lane stays so its history is one tap away, but it is visibly out of
    // the team and it never claims anything is waiting on it.
    final away = bot.archived;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: context.motion(Motion.quick),
        curve: Motion.standard,
        margin: const EdgeInsets.only(bottom: 1),
        padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
        decoration: BoxDecoration(
          color: on ? c.accentSoft : (_hover ? c.hover.withValues(alpha: .65) : Colors.transparent),
          borderRadius: Shapes.r10,
        ),
        child: Row(
          children: [
            Expanded(
              child: Keyable(
                radius: Shapes.r10,
                selected: on,
                label: [
                  bot.name,
                  if (away) 'archived',
                  if (bot.job.isNotEmpty) bot.job,
                  if (!away && widget.unread > 0) '${widget.unread} waiting',
                ].join(', '),
                onTap: widget.onTap,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onTap,
                    child: Row(
                      children: [
                        if (away)
                          Opacity(opacity: .45, child: BotAvatar(bot: bot, size: 22))
                        else
                          BotAvatar(bot: bot, size: 22),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Tooltip(
                            message: away
                                ? '${bot.name} — archived. Its conversations stay; bring it back for new work.'
                                : (bot.job.isEmpty ? bot.name : '${bot.name} — ${bot.job}'),
                            waitDuration: const Duration(milliseconds: 500),
                            child: Text(
                              bot.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.labelLarge?.copyWith(
                                color: away ? c.faint : (on ? c.accent : (_hover ? c.text : c.muted)),
                                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        if (away)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Glyph(G.box, size: 11, color: c.faint),
                          )
                        else if (widget.unread > 0)
                          Container(
                            constraints: const BoxConstraints(minWidth: 17),
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: c.warning, borderRadius: Shapes.pill),
                            child: Text(
                              '${widget.unread}',
                              textAlign: TextAlign.center,
                              style: context.type.labelSmall?.copyWith(
                                color: c.dark ? c.canvas : Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        else if (bot.pinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Glyph(G.flag, size: 11, color: botColor(bot, c.accent)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 24,
              child: _hover || on
                  ? PopupMenuButton<String>(
                      tooltip: 'Teammate options',
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      icon: const Glyph(G.expand, size: 13),
                      onSelected: (v) {
                        if (v == 'pin') {
                          _act(() => widget.core.editBot(bot.id, {'pinned': !bot.pinned}));
                        } else if (v == 'back') {
                          _act(() => widget.core.editBot(bot.id, {'archived': false}));
                        } else if (v == 'edit') {
                          showBotEditor(context, core: widget.core, state: widget.state, run: _act, bot: bot);
                        }
                      },
                      itemBuilder: (_) => [
                        if (!away)
                          PopupMenuItem(value: 'pin', child: Text(bot.pinned ? 'Unpin from top' : 'Pin to top')),
                        if (away) const PopupMenuItem(value: 'back', child: Text('Bring back to the team')),
                        const PopupMenuItem(value: 'edit', child: Text('Edit teammate…')),
                      ],
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends StatefulWidget {
  const _ConversationTile({required this.task, required this.selected, required this.onTap, this.bot});
  final TaskView task;
  final BotView? bot;
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
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: Shapes.r10,
        child: AnimatedContainer(
          duration: context.motion(Motion.quick),
          curve: Motion.standard,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
          decoration: BoxDecoration(
            color: selected
                ? c.accentSoft
                : (_hover ? c.hover.withValues(alpha: .65) : Colors.transparent),
            borderRadius: Shapes.r10,
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(color: waiting || task.active ? color : Colors.transparent, borderRadius: Shapes.pill),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (task.isTeam) ...[
                          Glyph(G.team, size: 14, color: c.accent),
                          const SizedBox(width: 5),
                        ] else if (widget.bot != null) ...[
                          BotAvatar(bot: widget.bot!, size: 15),
                          const SizedBox(width: 5),
                        ],
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
  const Composer({super.key, required this.core, required this.onSend, this.onSendFiles, this.hint = 'Ask Compii to do something…', this.busyTask, this.run, this.autofocus = true, this.state, this.large = false, this.seed = '', this.onVoice, this.allowOffline = false});
  final CoreClient core;

  /// App state, for voice and the "typing" reaction.
  final AppState? state;
  final Future<void> Function(String text) onSend;

  /// When set, a paperclip appears: picked files are sent to Core, then this gets their paths.
  final Future<void> Function(String text, List<String> files)? onSendFiles;
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

  /// On a paired phone: typing while the PC is away is kept and sent later.
  final bool allowOffline;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _files = <_PickedFile>[];
  bool _uploading = false;

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

  Future<void> _pick() async {
    try {
      final picked = await FilePicker.pickFiles(dialogTitle: 'Attach to Compii');
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final path = f.path;
          if (path == null || _files.length >= 10 || _files.any((x) => x.path == path)) continue;
          _files.add(_PickedFile(path, f.name, f.lengthSync() ?? 0));
        }
      });
    } catch (e) {
      widget.state?.fail(e);
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    final reachable = widget.core.status == CoreStatus.online;
    if ((t.isEmpty && _files.isEmpty) || (!reachable && !widget.allowOffline) || _uploading) return;
    if (_files.isNotEmpty && widget.onSendFiles != null) {
      final pending = List.of(_files);
      setState(() => _uploading = true);
      try {
        final paths = <String>[];
        for (final f in pending) {
          paths.add((await widget.core.uploadFile(f.path))['path'] as String);
        }
        _text.clear();
        setState(() => _files.clear());
        widget.state?.setTyping(false);
        await widget.onSendFiles!(t.isEmpty ? 'Take a look at the attached file(s).' : t, paths);
      } catch (e) {
        widget.state?.fail(e);
      } finally {
        if (mounted) setState(() => _uploading = false);
      }
    } else {
      _text.clear();
      widget.state?.setTyping(false);
      await widget.onSend(t);
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final online = widget.core.status == CoreStatus.online;
    final canType = online || widget.allowOffline;
    final busy = widget.busyTask?.active ?? false;
    final voice = widget.state?.voice;
    final hearing = voice != null && (voice.listening || voice.busy);
    final focused = _focus.hasFocus || hearing;
    final canSend = canType && !_uploading && (_text.text.trim().isNotEmpty || _files.isNotEmpty);
    return AnimatedContainer(
      duration: context.motion(Motion.base),
      curve: Motion.standard,
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: widget.large ? Shapes.r24 : Shapes.r20,
        border: Border.all(color: hearing ? c.listen : focused ? c.accent.withValues(alpha: .7) : c.borderStrong, width: focused ? 1.5 : 1),
        boxShadow: [
          ...Shapes.float(c),
          if (focused) BoxShadow(color: (hearing ? c.listen : c.accent).withValues(alpha: .14), blurRadius: 0, spreadRadius: 4),
        ],
      ),
      padding: EdgeInsets.fromLTRB(widget.large ? 20 : 18, widget.large ? 10 : 6, 8, widget.large ? 10 : 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final f in _files)
                      _FileChip(
                        file: f,
                        onRemove: _uploading ? null : () => setState(() => _files.remove(f)),
                      ),
                  ],
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.onSendFiles != null) ...[
                _GhostIconButton(
                  tooltip: 'Attach files',
                  glyph: G.clip,
                  size: 19,
                  onTap: canType && !_uploading ? _pick : null,
                  color: canType ? c.muted : c.faint,
                ),
                const SizedBox(width: 2),
              ],
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
                enabled: canType,
                minLines: 1,
                maxLines: 6,
                style: context.type.bodyLarge,
                decoration: InputDecoration(
                  hintText: online
                      ? (busy ? 'Compii is working — you can stop it any time' : widget.hint)
                      : widget.allowOffline
                          ? 'Your PC is away — this will wait and send when it’s back'
                          : 'Waiting for Compii Core…',
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
            _GhostIconButton(tooltip: 'Back to talking (Esc)', glyph: G.wave, size: 19, onTap: widget.onVoice)
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
              tooltip: _uploading ? 'Sending files…' : 'Send (Enter)',
              color: c.accent,
              onPressed: canSend ? _send : null,
              child: _uploading
                  ? SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.onAccent),
                    )
                  : Glyph(G.arrowUp, size: 18, color: c.onAccent, weight: 2.2),
            ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PickedFile {
  const _PickedFile(this.path, this.name, this.size);
  final String path;
  final String name;
  final int size;
}

/// A file waiting to be sent, above the message box.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.file, this.onRemove});
  final _PickedFile file;
  final VoidCallback? onRemove;

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static GlyphData _icon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'}.contains(ext)) return G.image;
    if (const {'pdf', 'doc', 'docx', 'rtf', 'txt', 'md'}.contains(ext)) return G.doc;
    if (const {'xls', 'xlsx', 'csv'}.contains(ext)) return G.sheet;
    return G.file;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: Shapes.r10,
        border: Border.all(color: c.accent.withValues(alpha: .25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Glyph(_icon(file.name), size: 14, color: c.accent),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: c.text)),
          ),
          const SizedBox(width: 5),
          Text(_size(file.size), style: context.type.labelSmall?.copyWith(color: c.faint)),
          const SizedBox(width: 2),
          if (onRemove != null)
            Tooltip(
              message: 'Remove',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Glyph(G.close, size: 11, color: c.muted),
                ),
              ),
            )
          else
            const Padding(padding: EdgeInsets.all(4), child: SizedBox.square(dimension: 11)),
        ],
      ),
    );
  }
}

/// A quiet round button for the composer: a soft tint under the pointer, and
/// nothing painted when it is at rest.
class _GhostIconButton extends StatefulWidget {
  const _GhostIconButton({required this.tooltip, required this.glyph, this.size = 18, this.onTap, this.color});
  final String tooltip;
  final GlyphData glyph;
  final double size;
  final VoidCallback? onTap;
  final Color? color;

  @override
  State<_GhostIconButton> createState() => _GhostIconButtonState();
}

class _GhostIconButtonState extends State<_GhostIconButton> {
  bool _over = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            curve: Motion.standard,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _over && on ? c.hover.withValues(alpha: .8) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Glyph(widget.glyph, size: widget.size, color: widget.color ?? (on ? c.muted : c.faint)),
          ),
        ),
      ),
    );
  }
}

/// The send / stop button on the composer.
class _RoundButton extends StatefulWidget {
  const _RoundButton({required this.tooltip, required this.color, required this.onPressed, required this.child});
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _down = false;
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.onPressed != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() {
          _over = false;
          _down = false;
        }),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onPressed,
          onHighlightChanged: (v) => setState(() => _down = v),
          child: AnimatedScale(
            scale: _down ? .92 : 1,
            duration: context.motion(_down ? Motion.tap : Motion.base),
            curve: Motion.spring,
            child: AnimatedContainer(
              duration: context.motion(Motion.quick),
              curve: Motion.standard,
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: on ? widget.color : c.sunken,
                shape: BoxShape.circle,
                boxShadow: on
                    ? [
                        BoxShadow(
                          color: widget.color.withValues(alpha: _over ? .42 : .3),
                          blurRadius: _over ? 16 : 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: on ? widget.child : Glyph(G.arrowUp, size: 18, color: c.faint, weight: 2.2),
            ),
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

  Future<void> _start(String text, [List<String> files = const []]) async {
    try {
      final id = await core.startConversation(text, botId: state.botId,
          team: state.team.length > 1 ? state.team : null, attachments: files);
      state.open(id);
    } catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final team = [for (final id in state.team) core.botFor(id)].whereType<BotView>().toList();
    if (team.length > 1) return TeamHome(core: core, state: state, run: run, bots: team);
    final bot = core.botFor(state.botId);
    if (bot != null && !bot.primary) return BotHome(core: core, state: state, run: run, bot: bot);
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
                    ? TalkableCompii(voice: state.voice!, mood: mood, jobs: jobs, size: hero)
                    : SizedBox.square(dimension: hero, child: Ember(mood: mood, jobs: jobs)),
              ),
              Text('$_greeting.', style: context.type.displaySmall, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('What should we get done?', style: context.type.bodyLarge?.copyWith(color: c.muted), textAlign: TextAlign.center),
              const SizedBox(height: 22),
              VoiceDock(core: core, state: state, onSend: _start, onSendFiles: _start, run: run, showCharacter: false),
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
    final bot = core.botFor(task.botId);
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
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (task.isTeam)
                          TeamStrip(task: task, core: core)
                        else if (bot != null && !bot.primary)
                          BotChip(bot: bot),
                        Pill(label, color: color),
                        if (task.answersWith.isNotEmpty)
                          Tooltip(
                            message: 'The AI thinking behind this conversation: ${task.answersWith}',
                            waitDuration: const Duration(milliseconds: 350),
                            child: ConstrainedBox(
                              // A model id is long; on a narrow pane or at 2x type it shortens
                              // rather than pushing the header off the screen.
                              constraints: const BoxConstraints(maxWidth: 200),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Glyph(G.memory, size: 12, color: c.faint),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(task.answersWith,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.type.labelSmall?.copyWith(color: c.faint)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (core.sight.value['looking'] == true) Pill('Seeing your screen', color: c.accent, glyph: G.eye),
                        if (task.fromRoutine) Pill('Routine', color: c.accent, glyph: G.routine),
                        if (task.delegated) Pill('Delegated job', color: c.accent, glyph: G.team),
                        if (task.probation || (task.delegated && core.botFor(task.botId)?.trust == 'probation'))
                          Pill('On probation', color: c.warning, glyph: G.warning),
                      ],
                    ),
                  ],
                ),
              ),
              // Five controls beside a long title: they flow onto a second line rather
              // than pushing the header out of a narrow pane or at enlarged type.
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!task.active && core.bots.length > 1)
                      TextButton.icon(
                        onPressed: () => showHandover(context, core: core, state: state, run: run, task: task),
                        icon: const Glyph(G.hand, size: 15),
                        label: const Text('Hand over'),
                      ),
                    if (task.status == 'done' && !task.fromRoutine) SaveSkillButton(task: task, run: run),
                    TextButton.icon(
                      onPressed: () => state.setChatView(false),
                      icon: const Glyph(G.memory, size: 16),
                      label: const Text('Character view'),
                    ),
                    if (task.active)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            foregroundColor: c.danger, side: BorderSide(color: c.danger.withValues(alpha: .4))),
                        onPressed: () => run(() => core.stop(task.id)),
                        icon: const Glyph(G.stop, size: 16, duo: true),
                        label: const Text('Stop'),
                      ),
                    ConversationMenu(task: task, core: core, state: state),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(child: ThreadView(task: task, core: core, run: run, onOpenTask: state.open)),
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
              onSendFiles: (text, files) => run(() => core.reply(task.id, text, attachments: files)),
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
      child: Eyebrow(
        s,
        trailing: count == null
            ? null
            : Text(count, style: context.type.labelSmall?.copyWith(color: c.muted)),
      ),
    );
    final done = plan?.where((s) => s['status'] == 'done').length ?? 0;
    return Container(
      width: 312,
      decoration: BoxDecoration(color: c.surface, border: Border(left: BorderSide(color: c.border))),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        children: [
          Text('Progress', style: context.type.titleLarge),
          const SizedBox(height: 14),
          if (plan != null && plan.isNotEmpty) ...[
            ClipRRect(
              borderRadius: Shapes.pill,
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
