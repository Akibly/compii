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
import 'team_halo.dart';
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

  /// Replies as the thread (the default since v5) or as the character's speech bubble.
  bool chatView = true;

  void setChatView(bool v) {
    chatView = v;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool('chat_view_v5', v)).ignore();
  }

  /// Restore saved preferences (chat view, theme).
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      chatView = p.getBool('chat_view_v5') ?? true;
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

  /// The page for the current section. The old destinations sit inside two hubs, so the
  /// sidebar keeps four places while every page stays one click (or Ctrl+K) away.
  Widget _page(BuildContext context, TaskView? task) {
    final page = switch (state.section) {
      Section.memory => MemoryPage(core: core, run: _run,
          focusId: state.focusKind == 'memory' ? state.focusId : null),
      Section.timeline => TimelinePage(core: core, run: _run,
          focusQuery: state.focusKind == 'moment' ? state.focusQuery : null),
      Section.clips => ClipsPage(core: core, run: _run,
          focusQuery: (state.focusKind == 'clip' || state.focusKind == 'snippet') ? state.focusQuery : null,
          focusSnippets: state.focusTab == 'snippets'),
      Section.routines => RoutinesPage(core: core, run: _run, onOpenTask: state.open,
          focusId: state.focusKind == 'routine' ? state.focusId : null),
      Section.skills => SkillsPage(run: _run, onOpenTask: state.open),
      Section.library => LibraryPage(run: _run),
      Section.knowledge => KnowledgePage(run: _run),
      Section.research => ResearchPage(run: _run),
      Section.team => TeamHaloPage(core: core, state: state, run: _run),
      Section.safety => SafetyPage(run: _run),
      Section.updates => UpdatesPage(core: core, run: _run, onOpenTask: state.open),
      Section.settings => SettingsPage(core: core, state: state, run: _run),
      Section.chat when task != null && state.chatView => _Conversation(task: task, core: core, run: _run, state: state),
      Section.chat when task != null => Stage(task: task, core: core, state: state, run: _run),
      _ => _Home(core: core, state: state, run: _run),
    };
    if (_activitySections.contains(state.section)) {
      return _Hub(title: 'Activity', tabs: _activitySections, current: state.section, onPick: state.go,
          badges: {Section.updates: core.unread}, child: page);
    }
    if (_toolSections.contains(state.section)) {
      return _Hub(title: 'Tools & settings', tabs: _toolSections, current: state.section, onPick: state.go,
          child: page);
    }
    return page;
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
      void palette() => showCommandPalette(context: context, core: core, state: state, run: _run);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => state.go(Section.home),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): palette,
          const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => state.go(Section.home),
          const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => state.go(Section.team),
          const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => state.go(Section.updates),
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () => state.go(Section.settings),
        },
        child: Scaffold(
          backgroundColor: c.canvas,
          drawerScrimColor: c.scrim,
          drawer: Drawer(
            backgroundColor: c.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
            ),
            child: SafeArea(child: _Sidebar(core: core, state: state, onFaceView: onFaceView, onSearch: palette)),
          ),
          body: LayoutBuilder(
            builder: (context, box) {
              final showProgress = task != null && box.maxWidth >= 1180;
              final showSidebar = box.maxWidth >= 760;
              return Row(
                children: [
                  if (showSidebar) _Sidebar(core: core, state: state, onFaceView: onFaceView, onSearch: palette),
                  Expanded(
                    child: Column(
                      children: [
                        TitleBar(
                          title: _title(task),
                          center: state.section == Section.chat && task != null && state.chatView
                              ? _ChatHeader(task: task, core: core, state: state, run: _run)
                              : null,
                          leading: showSidebar ? null : IconButton(
                            tooltip: 'Open navigation', icon: const Glyph(G.menu, size: 22),
                            onPressed: () => Scaffold.of(context).openDrawer()),
                          actions: [
                            // The sidebar carries the search box; without it, the palette needs a way in.
                            if (!showSidebar) ...[PaletteButton(onTap: palette), const SizedBox(width: 10)],
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
                              child: _page(context, task),
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

/// The four places, in the order people use them. Every old page lives inside one of them.
enum Place { chats, agents, activity, tools }

const _activitySections = [Section.updates, Section.timeline, Section.clips];
const _toolSections = [
  Section.routines, Section.skills, Section.library, Section.knowledge,
  Section.research, Section.memory, Section.safety, Section.settings,
];

Place placeOf(AppState state) => switch (state.section) {
      Section.team => Place.agents,
      Section.home when state.botId != null || state.team.isNotEmpty => Place.agents,
      Section.home || Section.chat => Place.chats,
      final s when _activitySections.contains(s) => Place.activity,
      _ => Place.tools,
    };

String sectionLabel(Section s) => switch (s) {
      Section.home => 'New chat',
      Section.chat => 'Chat',
      Section.team => 'Agents',
      Section.updates => 'Updates',
      Section.routines => 'Routines',
      Section.skills => 'Skills',
      Section.library => 'Library',
      Section.knowledge => 'Knowledge',
      Section.research => 'Research',
      Section.memory => 'Memory',
      Section.timeline => 'Timeline',
      Section.clips => 'Clips',
      Section.safety => 'Safety',
      Section.settings => 'Settings',
    };

/// Which bucket of the chat list a conversation falls in.
String _day(double at) {
  if (at <= 0) return 'Earlier';
  final then = DateTime.fromMillisecondsSinceEpoch((at * 1000).round());
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(then.year, then.month, then.day);
  final gap = today.difference(day).inDays;
  if (gap <= 0) return 'Today';
  if (gap == 1) return 'Yesterday';
  if (gap < 7) return 'This week';
  return 'Earlier';
}

double _lastAt(TaskView t) =>
    (t.last?['at'] as num?)?.toDouble() ?? (t.events.firstOrNull?['at'] as num?)?.toDouble() ?? 0;

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.core, required this.state, this.onFaceView, this.onSearch});
  final CoreClient core;
  final AppState state;
  final VoidCallback? onFaceView;
  final VoidCallback? onSearch;

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
    // Teammates show as faces on Team at the foot; a put-away one is left out (its chats stay listed).
    final team = [for (final b in core.bots) if (!b.archived) b].take(8).toList();
    final jobs = tasks.where((t) => t.active).length;
    final waiting = tasks.where((t) => t.pendingApproval != null).length;
    final (String status, Color statusColor) = switch (mood) {
      Mood.offline => ('Offline', c.danger),
      Mood.waiting => ('Needs you', c.warning),
      Mood.listening => ('Listening', c.listen),
      Mood.thinking || Mood.acting => (jobs > 1 ? 'Working on $jobs things' : 'Working', c.accent),
      Mood.speaking => ('Speaking', c.accent),
      _ => (voice?.wakeListening == true ? 'Say “Hey Compii”' : 'Ready', c.success),
    };
    final place = placeOf(state);
    Widget group(String label, {List<Widget> actions = const []}) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 0, 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: context.type.labelSmall?.copyWith(color: c.faint))),
          ...actions,
        ],
      ),
    );
    final buckets = <String, List<TaskView>>{};
    for (final t in tasks) {
      buckets.putIfAbsent(_day(_lastAt(t)), () => []).add(t);
    }
    return Container(
      width: 248,
      decoration: BoxDecoration(color: c.surface, border: Border(right: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DragStrip(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 6),
              child: Row(
                children: [
                  if (voice != null)
                    TalkableCompii(voice: voice, mood: mood, jobs: jobs, size: 26)
                  else
                    SizedBox.square(dimension: 24, child: Ember(mood: mood, jobs: jobs)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Compii', style: context.type.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.type.labelMedium?.copyWith(
                                      fontSize: 11.5, color: mood == Mood.idle ? c.faint : statusColor)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (onFaceView != null)
                    IconButton(
                        tooltip: 'Presence view (for a phone or second screen)',
                        onPressed: onFaceView,
                        visualDensity: VisualDensity.compact,
                        icon: const Glyph(G.pip, size: 16)),
                  IconButton(
                    tooltip: 'New chat (Ctrl+N)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => state.go(Section.home),
                    icon: const Glyph(G.plus, size: 16),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
            child: _SearchField(onTap: onSearch),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
              children: [
                if (tasks.isEmpty) ...[
                  group('Chats'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Text('Chats you start appear here.', style: context.type.bodySmall?.copyWith(color: c.faint)),
                  ),
                ] else
                  for (final day in const ['Today', 'Yesterday', 'This week', 'Earlier'])
                    if (buckets[day] case final list?) ...[
                      group(day),
                      for (final t in list)
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
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
            child: Column(
              children: [
                _TeamFoot(
                  bots: [for (final b in team) if (!b.primary) b],
                  working: tasks.where((t) => t.active && !(core.botFor(t.botId)?.primary ?? true)).length,
                  selected: place == Place.agents,
                  onTap: () => state.go(Section.team),
                  onNew: () => _newTeammate(context),
                ),
                _NavButton(glyph: G.bell, label: 'Activity', keys: 'Ctrl+3', selected: place == Place.activity,
                    onTap: () => state.go(Section.updates), badge: core.unread + waiting),
                _NavButton(glyph: G.sliders, label: 'Settings', keys: 'Ctrl+,',
                    selected: place == Place.tools, onTap: () => state.go(Section.settings)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Team at the foot of the sidebar: the teammates' faces and how many are working right now.
class _TeamFoot extends StatefulWidget {
  const _TeamFoot({required this.bots, required this.working, required this.selected, required this.onTap,
      required this.onNew});
  final List<BotView> bots;
  final int working;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onNew;
  @override
  State<_TeamFoot> createState() => _TeamFootState();
}

class _TeamFootState extends State<_TeamFoot> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final faces = widget.bots.take(3).toList();
    final status = widget.working > 0 ? 'Team · ${widget.working} working' : 'Team';
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '$status, Control 2',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: Shapes.r10,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            margin: const EdgeInsets.only(bottom: 1),
            padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
            decoration: BoxDecoration(
              color: widget.selected ? c.hover : (_hover ? c.hover.withValues(alpha: .6) : Colors.transparent),
              borderRadius: Shapes.r10,
            ),
            child: Row(
              children: [
                if (faces.isEmpty)
                  Glyph(G.team, size: 16, color: c.muted)
                else
                  SizedBox(
                    width: 18.0 + 12 * (faces.length - 1),
                    height: 20,
                    child: Stack(
                      children: [
                        for (var i = 0; i < faces.length; i++)
                          Positioned(left: 12.0 * i, top: 1, child: BotAvatar(bot: faces[i], size: 18)),
                      ],
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.labelLarge?.copyWith(
                          color: widget.selected || _hover ? c.text : (widget.working > 0 ? c.text : c.muted))),
                ),
                if (_hover)
                  IconButton(
                    tooltip: 'New teammate',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onNew,
                    icon: const Glyph(G.plus, size: 13),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The way into everything: looks like a search box, opens the command palette.
class _SearchField extends StatefulWidget {
  const _SearchField({this.onTap});
  final VoidCallback? onTap;
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      label: 'Search chats, agents and pages, Control K',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: _hover ? c.hover : c.sunken,
              borderRadius: Shapes.r6,
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Glyph(G.search, size: 13, color: c.faint),
                const SizedBox(width: 7),
                Expanded(
                  child: Text('Search or jump to…', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.labelMedium?.copyWith(color: c.faint, fontSize: 12.5)),
                ),
                const Kbd('Ctrl + K'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({required this.glyph, required this.label, required this.selected, required this.onTap,
      this.badge = 0, this.keys});
  final int badge;
  final GlyphData glyph;
  final String label;
  final String? keys;
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
    return Semantics(
      selected: on,
      button: true,
      label: widget.keys == null ? widget.label : '${widget.label}, ${widget.keys}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: Shapes.r6,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            curve: Motion.standard,
            margin: const EdgeInsets.only(bottom: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: on ? c.hover : (_hover ? c.hover.withValues(alpha: .6) : Colors.transparent),
              borderRadius: Shapes.r10,
            ),
            child: Row(
              children: [
                Glyph(widget.glyph, size: 15, color: on ? c.text : c.muted),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(widget.label,
                      style: context.type.labelLarge?.copyWith(color: on || _hover ? c.text : c.muted)),
                ),
                if (widget.badge > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: c.warningSoft, borderRadius: Shapes.pill),
                    child: Text('${widget.badge}', textAlign: TextAlign.center,
                        style: TextStyle(color: c.warning, fontSize: 11, fontWeight: FontWeight.w600)),
                  )
                else if (widget.keys != null && _hover)
                  Text(widget.keys!, style: context.type.labelSmall?.copyWith(color: c.faint, letterSpacing: 0)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The tabs across the top of Activity and Tools & settings: the old pages, one click apart.
class _Hub extends StatelessWidget {
  const _Hub({required this.title, required this.tabs, required this.current, required this.onPick,
      required this.child, this.badges = const {}});
  final String title;
  final List<Section> tabs;
  final Section current;
  final ValueChanged<Section> onPick;
  final Map<Section, int> badges;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 38,
          padding: EdgeInsets.symmetric(horizontal: Space.gutter(context) - 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in tabs)
                  _HubTab(
                    label: sectionLabel(s),
                    selected: s == current,
                    badge: badges[s] ?? 0,
                    onTap: () => onPick(s),
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _HubTab extends StatefulWidget {
  const _HubTab({required this.label, required this.selected, required this.onTap, this.badge = 0});
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onTap;
  @override
  State<_HubTab> createState() => _HubTabState();
}

class _HubTabState extends State<_HubTab> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final on = widget.selected;
    return Semantics(
      selected: on,
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: on ? c.text : Colors.transparent, width: 1.5)),
            ),
            alignment: Alignment.center,
            child: Row(
              children: [
                Text(widget.label,
                    style: context.type.labelLarge?.copyWith(color: on || _hover ? c.text : c.muted)),
                if (widget.badge > 0) ...[
                  const SizedBox(width: 6),
                  Text('${widget.badge}', style: TextStyle(color: c.warning, fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
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
    final at = _lastAt(task);
    final (String label, Color color) = waiting
        ? ('Needs you', c.warning)
        : switch (task.status) {
            'running' => ('Working', c.accent),
            'failed' => ('Problem', c.danger),
            'stopped' => ('Stopped', c.faint),
            _ => ('Done', c.success),
          };
    // One line per chat, the way a list of files reads: what it is, and a mark only when it is
    // doing something or wants something. Done is the normal state and draws nothing.
    final Widget mark = task.active && !waiting
        ? SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: color))
        : waiting || task.status == 'failed'
            ? Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle))
            : const SizedBox(width: 7);
    final title = task.fromRoutine ? '${task.origin!['title']}' : titleOf(task);
    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $label, ${ago(at)}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: Shapes.r6,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            curve: Motion.standard,
            margin: const EdgeInsets.only(bottom: 1),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: BoxDecoration(
              color: selected ? c.hover : (_hover ? c.hover.withValues(alpha: .6) : Colors.transparent),
              borderRadius: Shapes.r6,
            ),
            child: Row(
              children: [
                SizedBox(width: 12, child: Center(child: mark)),
                const SizedBox(width: 6),
                if (task.isTeam) ...[
                  Glyph(G.team, size: 13, color: c.muted),
                  const SizedBox(width: 5),
                ] else if (widget.bot != null && !widget.bot!.primary) ...[
                  BotAvatar(bot: widget.bot!, size: 14),
                  const SizedBox(width: 5),
                ],
                if (task.fromRoutine) ...[
                  Glyph(G.routine, size: 12, color: c.muted),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelLarge?.copyWith(color: selected || _hover ? c.text : c.muted),
                  ),
                ),
                const SizedBox(width: 6),
                Text(waiting ? 'Needs you' : ago(at),
                    style: context.type.labelSmall?.copyWith(color: waiting ? c.warning : c.faint, letterSpacing: 0)),
              ],
            ),
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
  const Composer({super.key, required this.core, required this.onSend, this.onSendFiles, this.hint = 'Ask Compii to do something…', this.busyTask, this.run, this.autofocus = true, this.state, this.large = false, this.seed = '', this.onVoice, this.allowOffline = false, this.voiceIsMic = false, this.tools = const []});
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

  /// The voice button starts listening in place (a text-first composer) instead of going
  /// back to the voice bar; Esc then does nothing voice-related.
  final bool voiceIsMic;

  /// Extra controls in the large composer's toolbar, between attach and the mic.
  final List<Widget> tools;

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
    final textStyle = widget.large ? context.type.bodyLarge?.copyWith(fontSize: 18, height: 1.45) : context.type.bodyLarge;
    final Widget? attach = widget.onSendFiles == null
        ? null
        : _GhostIconButton(
            tooltip: 'Attach files',
            glyph: G.clip,
            size: 19,
            onTap: canType && !_uploading ? _pick : null,
            color: canType ? c.muted : c.faint,
          );
    final Widget field = hearing
        ? LiveTranscript(voice: voice)
        : Focus(
            onFocusChange: (_) => setState(() {}),
            onKeyEvent: (node, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && widget.onVoice != null && !widget.voiceIsMic) {
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
              minLines: widget.large ? 2 : 1,
              maxLines: 6,
              style: textStyle,
              decoration: InputDecoration(
                hintText: online
                    ? (busy ? 'Compii is working — you can stop it any time' : widget.hint)
                    : widget.allowOffline
                        ? 'Your PC is away — this will wait and send when it’s back'
                        : 'Waiting for Compii Core…',
                hintStyle: textStyle?.copyWith(color: c.faint),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: widget.large ? 6 : 12),
              ),
            ),
          );
    final Widget? mic = widget.onVoice == null
        ? null
        : _GhostIconButton(
            tooltip: widget.voiceIsMic ? 'Talk instead (or hold Ctrl+Alt)' : 'Back to talking (Esc)',
            glyph: widget.voiceIsMic ? G.mic : G.wave,
            size: 19,
            onTap: widget.onVoice);
    // Send is ink on the composer, like every primary action; Stop is the one red thing.
    final Widget action = busy
        ? _RoundButton(
            tooltip: 'Stop',
            color: c.danger,
            onPressed: () => widget.run?.call(() => widget.core.stop(widget.busyTask!.id)),
            child: const Glyph(G.stop, size: 16, color: Colors.white, duo: true, duoColor: Colors.white),
          )
        : _RoundButton(
            tooltip: _uploading ? 'Sending files…' : 'Send (Enter)',
            color: c.text,
            onPressed: canSend ? _send : null,
            child: _uploading
                ? SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2, color: c.canvas))
                : Glyph(G.arrowUp, size: 18, color: c.canvas, weight: 2.2),
          );
    return AnimatedContainer(
      duration: context.motion(Motion.base),
      curve: Motion.standard,
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: widget.large ? Shapes.r20 : Shapes.r12,
        boxShadow: widget.large ? Shapes.float(c) : null,
        // A hairline that firms up when you are in it; no glow, no float. Listening is the only
        // state that brings a colour, because it is the only one you cannot see otherwise.
        border: Border.all(
            color: hearing ? c.listen : focused ? c.muted.withValues(alpha: .6) : c.borderStrong,
            width: hearing ? 1.5 : 1),
      ),
      padding: widget.large ? const EdgeInsets.fromLTRB(16, 14, 12, 10) : const EdgeInsets.fromLTRB(14, 4, 6, 4),
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
          if (widget.large)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field,
                const SizedBox(height: 6),
                Row(
                  children: [
                    ?attach,
                    for (final t in widget.tools) ...[const SizedBox(width: 6), t],
                    const Spacer(),
                    ?mic,
                    const SizedBox(width: 6),
                    action,
                  ],
                ),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (attach != null) ...[attach, const SizedBox(width: 2)],
                Expanded(child: field),
                mic ?? const SizedBox(width: 4),
                const SizedBox(width: 2),
                action,
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
    final team = [for (final id in state.team) core.botFor(id)].whereType<BotView>().toList();
    if (team.length > 1) return TeamHome(core: core, state: state, run: run, bots: team);
    final bot = core.botFor(state.botId);
    if (bot != null && !bot.primary) return BotHome(core: core, state: state, run: run, bot: bot);
    final c = context.c;
    final mood = state.moodWith(core);
    final jobs = core.ordered.where((t) => t.active).length;
    final online = core.status == CoreStatus.online;
    final ready = core.ordered.take(3).toList();
    final seeing = core.sight.value['screen_aware'] != false;
    final hero = (MediaQuery.sizeOf(context).height * .14).clamp(72.0, 120.0);
    // The Halo canvas the user approved: the halo, one question, one big composer, and what is
    // ready for you underneath. Outcomes first; the work is one click deeper, in the chat.
    return Align(
      alignment: const Alignment(0, -.4),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(Space.gutter(context), 40, Space.gutter(context), 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: state.voice != null
                    ? TalkableCompii(voice: state.voice!, mood: mood, jobs: jobs, size: hero)
                    : SizedBox.square(dimension: hero, child: Ember(mood: mood, jobs: jobs)),
              ),
              const SizedBox(height: 22),
              Text('What should we do?', textAlign: TextAlign.center,
                  style: context.type.displaySmall?.copyWith(fontSize: 40, height: 1.1, letterSpacing: -.8)),
              const SizedBox(height: 26),
              VoiceDock(
                core: core,
                state: state,
                onSend: _start,
                onSendFiles: _start,
                run: run,
                showCharacter: false,
                textFirst: true,
                large: true,
                hint: 'Ask anything, or describe what you want done',
                tools: [
                  _ToolChip(
                    glyph: seeing ? G.eye : G.eyeOff,
                    label: seeing ? 'Sees your screen' : 'Screen off',
                    tooltip: seeing
                        ? 'Compii reads the app in front of you when a request needs it. Click to turn it off.'
                        : 'Compii can’t see your screen. Click to let it read the app in front of you.',
                    onTap: online ? () => run(() => core.voiceSettings({'screen_aware': !seeing})) : null,
                  ),
                  _AgentChip(core: core, state: state),
                ],
              ),
              const SizedBox(height: 14),
              Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Or hold '),
                  TextSpan(text: 'Ctrl + Alt', style: TextStyle(color: c.text, fontWeight: FontWeight.w500)),
                  const TextSpan(text: ' in any app and just say it.'),
                ]),
                textAlign: TextAlign.center,
                style: context.type.bodySmall?.copyWith(color: c.faint, fontSize: 13),
              ),
              const SizedBox(height: 32),
              if (ready.isNotEmpty) ...[
                Text('Ready for you', style: context.type.labelMedium?.copyWith(color: c.faint)),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, box) {
                    final cols = box.maxWidth >= 620 ? 3 : (box.maxWidth >= 400 ? 2 : 1);
                    final w = (box.maxWidth - 10 * (cols - 1)) / cols;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final t in ready)
                          SizedBox(width: w, child: _ResultTile(task: t, core: core, onTap: () => state.open(t.id))),
                      ],
                    );
                  },
                ),
              ] else
                _HomeList(
                  title: 'Start with',
                  rows: [
                    for (final (g, title, _, prompt) in suggestions)
                      _HomeRow(glyph: g, label: title, onTap: online ? () => _start(prompt) : null),
                  ],
                ),
              const SizedBox(height: 18),
              BriefCard(core: core, run: run),
            ],
          ),
        ),
      ),
    );
  }
}

/// A control in the big composer's toolbar: a quiet pill with a glyph and a word.
class _ToolChip extends StatefulWidget {
  const _ToolChip({required this.glyph, required this.label, this.tooltip, this.onTap, this.trailing});
  final GlyphData glyph;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final Widget? trailing;
  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final chip = Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: _hover && widget.onTap != null ? .10 : .06),
              borderRadius: Shapes.r10,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Glyph(widget.glyph, size: 14, color: c.muted),
                const SizedBox(width: 7),
                Text(widget.label, style: context.type.labelLarge?.copyWith(color: c.muted, fontSize: 13)),
                if (widget.trailing != null) ...[const SizedBox(width: 4), widget.trailing!],
              ],
            ),
          ),
        ),
      ),
    );
    return widget.tooltip == null ? chip : Tooltip(message: widget.tooltip!, child: chip);
  }
}

/// Who this new chat goes to: Compii, or one of the teammates.
class _AgentChip extends StatelessWidget {
  const _AgentChip({required this.core, required this.state});
  final CoreClient core;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bots = [for (final b in core.bots) if (!b.archived) b];
    final current = core.botFor(state.botId);
    final name = current?.name ?? 'Compii';
    if (bots.length < 2) return _ToolChip(glyph: G.team, label: name);
    return PopupMenuButton<String>(
      tooltip: 'Who should take this',
      onSelected: (id) {
        final bot = core.botFor(id);
        state.pickBot(bot == null || bot.primary ? null : id);
      },
      itemBuilder: (_) => [
        for (final b in bots)
          PopupMenuItem(
            value: b.id,
            child: Row(
              children: [
                BotAvatar(bot: b, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      child: IgnorePointer(
        child: _ToolChip(glyph: G.team, label: name, onTap: () {}, trailing: Glyph(G.expand, size: 11, color: c.faint)),
      ),
    );
  }
}

/// One finished, waiting or running piece of work, outcome first: what state it is in, what it
/// was, and the gist of the result.
class _ResultTile extends StatefulWidget {
  const _ResultTile({required this.task, required this.core, required this.onTap});
  final TaskView task;
  final CoreClient core;
  final VoidCallback onTap;
  @override
  State<_ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends State<_ResultTile> {
  bool _hover = false;

  String _gist(TaskView t) {
    if (t.pendingApproval != null) return '${t.pendingApproval!['label'] ?? 'Waiting for your yes.'}';
    if (t.active) {
      final step = t.events.lastWhere(
          (e) => (e['type'] == 'action_started' || e['type'] == 'action_done') && e['label'] != null,
          orElse: () => const {})['label'];
      return step == null ? 'Working on it…' : '$step…';
    }
    final text = (t.finalText ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final first = RegExp(r'^.*?[.!?](\s|$)').firstMatch(text)?.group(0)?.trim() ?? text;
    return first.isEmpty ? 'No answer was written.' : first;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = widget.task;
    final bot = widget.core.botFor(t.botId);
    final who = bot == null || bot.primary ? '' : ' · ${bot.name}';
    final waiting = t.pendingApproval != null;
    final (String status, Color color) = waiting
        ? ('Needs you', c.warning)
        : t.active
            ? ('Working$who', c.accent)
            : switch (t.status) {
                'failed' => ('Problem$who', c.danger),
                'stopped' => ('Stopped$who', c.faint),
                _ => ('Done · ${ago(_lastAt(t))}', c.success),
              };
    final title = t.fromRoutine ? '${t.origin!['title']}' : titleOf(t);
    return Semantics(
      button: true,
      label: '$status. $title. ${_gist(t)}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            height: 124,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _hover ? c.hover : c.raised,
              borderRadius: Shapes.r16,
              border: Border.all(color: waiting ? c.warning.withValues(alpha: .35) : c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: context.type.labelMedium?.copyWith(color: color)),
                const SizedBox(height: 8),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: context.type.titleSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(_gist(t), maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: context.type.bodySmall?.copyWith(color: c.muted, fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled list on the home page: a label above, hairline rows below.
class _HomeList extends StatelessWidget {
  const _HomeList({required this.title, required this.rows});
  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 28,
          child: Row(
            children: [
              Expanded(child: Text(title, style: context.type.labelSmall?.copyWith(color: c.faint))),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(borderRadius: Shapes.r8, border: Border.all(color: c.border)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) Divider(height: 1, color: c.border),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HomeRow extends StatefulWidget {
  const _HomeRow({required this.glyph, required this.label, this.onTap});
  final GlyphData glyph;
  final String label;
  final VoidCallback? onTap;
  @override
  State<_HomeRow> createState() => _HomeRowState();
}

class _HomeRowState extends State<_HomeRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            color: _hover && enabled ? c.hover.withValues(alpha: .6) : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Glyph(widget.glyph, size: 14, color: enabled ? c.muted : c.faint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.labelLarge?.copyWith(color: enabled ? c.text : c.faint)),
                ),
                if (_hover && enabled)
                  Glyph(G.chevronRight, size: 13, color: c.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A chat's title, status and controls, drawn inside the window's title bar.
class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.task, required this.core, required this.state, required this.run});
  final TaskView task;
  final CoreClient core;
  final AppState state;
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
    return Row(
      children: [
        if (task.isTeam)
          Padding(padding: const EdgeInsets.only(right: 8), child: TeamStrip(task: task, core: core))
        else if (bot != null && !bot.primary)
          Padding(padding: const EdgeInsets.only(right: 8), child: BotAvatar(bot: bot, size: 18)),
        Flexible(
          child: Text(titleOf(task), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: context.type.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 10),
        Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: context.type.labelMedium?.copyWith(color: waiting ? c.warning : c.muted)),
        // What else is true of this chat, as quiet words rather than coloured pills.
        for (final (bool on, String word, String why) in [
          (task.fromRoutine, 'Routine', 'Started by a routine'),
          (task.delegated, 'Delegated', 'A job handed to this agent by another'),
          (core.sight.value['looking'] == true, 'Seeing your screen', 'Compii is reading your screen now'),
          (task.probation || (task.delegated && core.botFor(task.botId)?.trust == 'probation'),
              'On probation', 'This agent drafts but does not send, delete or pay'),
        ])
          if (on) ...[
            Text('  ·  ', style: context.type.labelMedium?.copyWith(color: c.faint)),
            Tooltip(message: why, child: Text(word, style: context.type.labelMedium?.copyWith(color: c.faint))),
          ],
        if (task.answersWith.isNotEmpty) ...[
          Text('  ·  ', style: context.type.labelMedium?.copyWith(color: c.faint)),
          Flexible(
            child: Tooltip(
              message: 'The AI answering this chat: ${task.answersWith}',
              child: Text(task.answersWith, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: context.type.labelMedium?.copyWith(color: c.faint)),
            ),
          ),
        ],
        const Spacer(),
        if (task.active)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: () => run(() => core.stop(task.id)),
            icon: const Glyph(G.stop, size: 14),
            label: const Text('Stop'),
          ),
        if (!task.active && core.bots.length > 1)
          IconButton(
            tooltip: 'Hand over to another agent',
            onPressed: () => showHandover(context, core: core, state: state, run: run, task: task),
            icon: const Glyph(G.hand, size: 15),
          ),
        if (task.status == 'done' && !task.fromRoutine) SaveSkillButton(task: task, run: run),
        IconButton(
          tooltip: 'Character view',
          onPressed: () => state.setChatView(false),
          icon: const Glyph(G.pip, size: 15),
        ),
        ConversationMenu(task: task, core: core, state: state),
      ],
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
    // Its title, status and controls are in the title bar (_ChatHeader); this is the thread.
    final gutter = Space.gutter(context);
    return Column(
      children: [
        Expanded(child: ThreadView(task: task, core: core, run: run, onOpenTask: state.open)),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: VoiceDock(
              core: core,
              state: state,
              hint: 'Follow up…',
              task: task,
              run: run,
              textFirst: true,
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
