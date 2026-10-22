import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/core_client.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'shell.dart';
import 'tokens.dart';
import 'trust.dart';

Future<void> _nothing() async {}

/// One searchable thing: a page, a conversation, a skill, a file or a setting.
class _Entry {
  const _Entry({
    required this.title,
    required this.subtitle,
    required this.glyph,
    required this.kind,
    required this.pick,
    this.terms = '',
    this.key,
  })  : heading = false,
        count = null;

  /// A non-selectable group title in the result list.
  _Entry.heading(this.title, {this.count})
      : subtitle = '',
        glyph = G.search,
        kind = '',
        pick = _nothing,
        terms = '',
        key = null,
        heading = true;

  final String title;
  final String subtitle;
  final GlyphData glyph;
  final String kind;
  final Future<void> Function() pick;

  /// Extra words that should find this entry (not shown).
  final String terms;

  /// Stable identity, so a result from Core replaces the same thing found in this window.
  final String? key;
  final bool heading;
  final int? count;

  String get haystack => '$title $subtitle $kind $terms';
}

typedef PaletteRun = Future<void> Function(Future<void> Function() action);

/// What a query found across the stores on this PC, as Core's /search returns it.
typedef PaletteSearch = Future<Map<String, dynamic>> Function(String query);

/// A row's height at the current text scale: the base already fits the two text
/// lines a row holds, and grows with them, so nothing overflows at large text.
double _rowExtent(BuildContext context, {required bool heading}) =>
    (heading ? 28.0 : 56.0) * MediaQuery.textScalerOf(context).scale(1);

Future<void> showCommandPalette({
  required BuildContext context,
  required CoreClient core,
  required AppState state,
  required PaletteRun run,
  PaletteSearch? search,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: context.c.canvas.withValues(alpha: .55),
    builder: (_) => CommandPalette(core: core, state: state, run: run, search: search),
  );
}

/// The Ctrl+K palette: type a few letters to jump anywhere or ask Compii.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.core, required this.state, required this.run, this.search});
  final CoreClient core;
  final AppState state;
  final PaletteRun run;
  final PaletteSearch? search;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _rows = {};
  late final FocusNode _field = FocusNode(onKeyEvent: _onKey);
  List<Map<String, dynamic>> _skills = const [];
  List<Map<String, dynamic>> _groups = const [];
  bool _remoteBusy = false;
  bool _remoteFailed = false;
  Timer? _debounce;
  int _searchRun = 0;
  int _selected = 0;
  String _text = '';

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  Future<void> _loadSkills() async {
    try {
      final list = await TrustApi.call('GET', '/skills') as List;
      if (mounted) {
        setState(() => _skills = [for (final s in list) Map<String, dynamic>.from(s as Map)]);
      }
    } on Object {
      // Skills are a bonus here; conversations and pages still work.
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    _field.dispose();
    super.dispose();
  }

  void _typed(String value) {
    setState(() {
      _text = value;
      _selected = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
    _debounce?.cancel();
    final run = ++_searchRun;
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _groups = const [];
        _remoteBusy = false;
        _remoteFailed = false;
      });
      return;
    }
    setState(() => _remoteBusy = true);
    _debounce = Timer(const Duration(milliseconds: 180), () => _searchRemote(q, run));
  }

  Future<void> _searchRemote(String query, int run) async {
    try {
      final got = widget.search != null
          ? await widget.search!(query)
          : await TrustApi.map('GET', '/search?q=${Uri.encodeQueryComponent(query)}&limit=5');
      if (!mounted || run != _searchRun) return;
      final groups = [for (final g in (got['groups'] as List? ?? const [])) Map<String, dynamic>.from(g as Map)];
      setState(() {
        _groups = groups;
        _remoteBusy = false;
        _remoteFailed = false;
        _selected = 0;
      });
    } on Object {
      if (!mounted || run != _searchRun) return;
      setState(() {
        _groups = const [];
        _remoteBusy = false;
        _remoteFailed = true;
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.tab) {
      _move(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _open(_selected);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int by) {
    final results = _results;
    final pickable = [for (var i = 0; i < results.length; i++) if (!results[i].heading) i];
    if (pickable.isEmpty) return;
    var at = pickable.indexOf(_effectiveSelection(results));
    if (at < 0) at = by > 0 ? -1 : pickable.length;
    final next = (at + by).clamp(0, pickable.length - 1).toInt();
    final index = pickable[next];
    setState(() => _selected = index);
    _reveal(index, forward: by > 0);
  }

  /// The row that is really highlighted: skip group titles and headings.
  int _effectiveSelection(List<_Entry> results) {
    if (results.isEmpty) return -1;
    final at = _selected.clamp(0, results.length - 1).toInt();
    if (!results[at].heading) return at;
    for (var i = at; i < results.length; i++) {
      if (!results[i].heading) return i;
    }
    for (var i = at - 1; i >= 0; i--) {
      if (!results[i].heading) return i;
    }
    return -1;
  }

  void _reveal(int index, {required bool forward}) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(index, forward: forward));
  }

  void _scrollTo(int index, {required bool forward, bool estimated = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final row = _rows[index]?.currentContext?.findRenderObject();
    if (row == null || !row.attached) {
      if (estimated) return;
      _scroll.jumpTo(_offsetOf(_results, index).clamp(0.0, _scroll.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(index, forward: forward, estimated: true));
      return;
    }
    _scroll.position.ensureVisible(
      row,
      alignmentPolicy: forward
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      duration: context.motion(Motion.quick),
      curve: Motion.standard,
    );
  }

  /// Where a row starts: the list's top padding plus every measured height above it.
  double _offsetOf(List<_Entry> results, int index) {
    var y = Space.s;
    for (var i = 0; i < index && i < results.length; i++) {
      y += _rowExtent(context, heading: results[i].heading) + (results[i].heading ? 0 : 1);
    }
    return y;
  }

  List<_Entry> get _results {
    final all = _allEntries();
    final q = _text.trim();
    if (q.isEmpty) {
      return all.take(14).toList();
    }
    final scored = <(int, int, _Entry)>[];
    for (final (i, entry) in all.indexed) {
      final score = _score(entry.haystack, q);
      if (score >= 0) scored.add((score, i, entry));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    final remote = _remoteEntries;
    final found = {for (final e in remote) if (e.key != null) e.key};
    final local = [for (final s in scored) s.$3].where((e) => e.key == null || !found.contains(e.key)).take(12).toList();
    return [
      ...remote,
      if (local.isNotEmpty) ...[
        _Entry.heading('Go to', count: local.length),
        ...local,
      ],
      _Entry(
        title: 'Ask Compii “$q”',
        subtitle: 'Start a new conversation',
        glyph: G.send,
        kind: 'Action',
        pick: () async {
          final id = await widget.core.startConversation(q);
          widget.state.open(id);
        },
        terms: 'ask new conversation request',
      ),
    ];
  }

  List<_Entry> get _remoteEntries {
    final out = <_Entry>[];
    for (final group in _groups) {
      final items = [for (final r in (group['items'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
      if (items.isEmpty) continue;
      out.add(_Entry.heading('${group['label'] ?? 'Results'}',
          count: (group['total'] as num?)?.toInt() ?? items.length));
      for (final item in items) {
        out.add(_remoteEntry(item));
      }
    }
    return out;
  }

  _Entry _remoteEntry(Map<String, dynamic> r) {
    final kind = '${r['kind']}';
    final id = '${r['id']}';
    final title = '${r['title'] ?? ''}'.trim();
    final subtitle = '${r['subtitle'] ?? ''}'.trim();
    final when = r['when'];
    final q = _text.trim();
    String stamped(String text) {
      if (when is! num) return text;
      final at = ago(when.toDouble());
      return text.isEmpty ? at : '$text · $at';
    }

    switch (kind) {
      case 'conversation':
        return _Entry(key: 'conversation:$id', title: title, subtitle: subtitle, glyph: G.chat,
            kind: 'Conversation', pick: () async => widget.state.open(id));
      case 'bot':
        return _Entry(key: 'bot:$id', title: title, subtitle: subtitle, glyph: G.team,
            kind: 'Teammate', pick: () async => widget.state.pickBot(id));
      case 'routine':
        return _Entry(key: 'routine:$id', title: title, subtitle: subtitle, glyph: G.routine, kind: 'Routine',
            pick: () async => widget.state.goDeep(Section.routines, kind: 'routine', id: id));
      case 'watch':
        return _Entry(key: 'watch:$id', title: title, subtitle: subtitle, glyph: G.eye, kind: 'Watch',
            pick: () async => widget.state.goDeep(Section.routines, kind: 'watch', id: id));
      case 'skill':
        return _Entry(key: 'skill:$id', title: title, subtitle: subtitle, glyph: G.wand, kind: 'Skill',
            pick: () async {
              final task = await TrustApi.map('POST', '/skills/${Uri.encodeComponent(id)}/run');
              widget.state.open(task['id'] as String);
            });
      case 'memory':
        return _Entry(key: 'memory:$id', title: title, subtitle: stamped('Saved'), glyph: G.memory,
            kind: 'Memory', pick: () async => widget.state.goDeep(Section.memory, kind: 'memory', id: id));
      case 'snippet':
        return _Entry(key: 'snippet:$id', title: title, subtitle: stamped(subtitle), glyph: G.note,
            kind: 'Snippet',
            pick: () async => widget.state.goDeep(Section.clips, kind: 'snippet', query: q, tab: 'snippets'));
      case 'clip':
        return _Entry(key: 'clip:$id', title: title, subtitle: stamped(subtitle), glyph: G.clipboard,
            kind: 'Clip', pick: () async => widget.state.goDeep(Section.clips, kind: 'clip', query: q, tab: 'history'));
      case 'moment':
        return _Entry(key: 'moment:$id', title: title, subtitle: stamped(subtitle), glyph: G.clock,
            kind: 'On screen',
            pick: () async => widget.state.goDeep(Section.timeline, kind: 'moment', query: q));
      default:
        return _Entry(key: 'result:$id', title: title, subtitle: subtitle, glyph: G.search,
            kind: 'Result', pick: () async {});
    }
  }

  List<_Entry> _allEntries() {
    final core = widget.core;
    final state = widget.state;
    final entries = <_Entry>[
      _Entry(title: 'Home', subtitle: 'A fresh start and a new request', glyph: G.home, kind: 'Go to',
          pick: () async => state.go(Section.home), terms: 'start new ask'),
      _Entry(title: 'Team', subtitle: 'Who works here, what they are doing, and the record', glyph: G.team, kind: 'Go to',
          pick: () async => state.go(Section.team), terms: 'agents employees roster hires trust jobs supervisor'),
      _Entry(title: 'Updates', subtitle: 'Briefs and things Compii noticed', glyph: G.bell, kind: 'Go to',
          pick: () async => state.go(Section.updates), terms: 'inbox notifications brief'),
      _Entry(title: 'Routines', subtitle: 'Things Compii runs on a schedule', glyph: G.routine, kind: 'Go to',
          pick: () async => state.go(Section.routines), terms: 'schedule daily weekly reminder'),
      _Entry(title: 'Skills', subtitle: 'What you taught Compii', glyph: G.skill, kind: 'Go to',
          pick: () async => state.go(Section.skills), terms: 'taught saved replay'),
      _Entry(title: 'Library', subtitle: 'Skills and connectors made for Claude, GPT and other agents', glyph: G.box, kind: 'Go to',
          pick: () async => state.go(Section.library), terms: 'import claude gpt openapi mcp connector skill zip workshop'),
      _Entry(title: 'Knowledge', subtitle: 'Ask Compii about your own documents and notes', glyph: G.search, kind: 'Go to',
          pick: () async => state.go(Section.knowledge), terms: 'files documents pdf folder index ask my files search notes'),
      _Entry(title: 'Research', subtitle: 'What Compii can read outside this PC: web, feeds, code and social platforms',
          glyph: G.globe, kind: 'Go to',
          pick: () async => state.go(Section.research),
          terms: 'social media twitter x reddit facebook instagram linkedin xiaohongshu bilibili youtube github rss feed '
              'v2ex web search research reach browser session'),
      _Entry(title: 'Memory', subtitle: 'What Compii remembers about you', glyph: G.memory, kind: 'Go to',
          pick: () async => state.go(Section.memory), terms: 'remember forget facts'),
      _Entry(title: 'Timeline', subtitle: 'What was on screen, searchable', glyph: G.clock, kind: 'Go to',
          pick: () async => state.go(Section.timeline),
          terms: 'screen history moments catch me up daybook what did i do today where was i undo'),
      _Entry(title: 'Clips', subtitle: 'Your clipboard history and snippets', glyph: G.clipboard, kind: 'Go to',
          pick: () async => state.go(Section.clips), terms: 'copy paste text snippet'),
      _Entry(title: 'Safety', subtitle: 'Rules, approvals and the kill switch', glyph: G.shield, kind: 'Go to',
          pick: () async => state.go(Section.safety), terms: 'permissions policy audit lockdown'),
      _Entry(title: 'Settings', subtitle: 'Brain, voice, phones and appearance', glyph: G.sliders, kind: 'Go to',
          pick: () async => state.go(Section.settings), terms: 'preferences options theme voice pairing'),
    ];

    for (final task in core.ordered.take(40)) {
      entries.add(_Entry(
        key: 'conversation:${task.id}',
        title: titleOf(task),
        subtitle: task.active
            ? (task.pendingApproval != null ? 'Needs your OK' : 'Working now')
            : 'Conversation · ${task.status}',
        glyph: G.chat,
        kind: 'Conversation',
        pick: () async => state.open(task.id),
        terms: task.request,
      ));
    }

    for (final skill in _skills) {
      entries.add(_Entry(
        key: 'skill:${skill['id']}',
        title: '${skill['name']}',
        subtitle: 'Run this skill now',
        glyph: G.wand,
        kind: 'Skill',
        pick: () async {
          final task = await TrustApi.map('POST', '/skills/${skill['id']}/run');
          state.open(task['id'] as String);
        },
        terms: '${skill['instruction'] ?? ''} skill',
      ));
    }

    final files = <String>{};
    for (final task in core.tasks.values) {
      for (final event in task.events) {
        if (event['type'] == 'file' && event['path'] is String) files.add(event['path'] as String);
      }
    }
    for (final path in files.take(30)) {
      entries.add(_Entry(
        title: path.split(RegExp(r'[\\/]')).last,
        subtitle: 'Open on your PC',
        glyph: G.file,
        kind: 'File',
        pick: () => core.openFile(path),
        terms: path,
      ));
    }

    entries.addAll([
      _Entry(title: 'Light appearance', subtitle: 'Use Compii in light mode', glyph: G.sun, kind: 'Setting',
          pick: () async => state.setTheme(ThemeMode.light), terms: 'theme white bright'),
      _Entry(title: 'Dark appearance', subtitle: 'Use Compii in dark mode', glyph: G.contrast, kind: 'Setting',
          pick: () async => state.setTheme(ThemeMode.dark), terms: 'theme night black'),
      _Entry(title: 'Follow Windows appearance', subtitle: 'Light or dark, whichever Windows uses',
          glyph: G.monitor, kind: 'Setting',
          pick: () async => state.setTheme(ThemeMode.system), terms: 'theme automatic system'),
      _Entry(title: 'Use chat-style replies', subtitle: 'Show conversations as a scrollable thread',
          glyph: G.chat, kind: 'Setting',
          pick: () async => state.setChatView(true), terms: 'view history conversation'),
      _Entry(title: 'Use speech-bubble replies', subtitle: 'Show one answer at a time with the character',
          glyph: G.speakingHead, kind: 'Setting',
          pick: () async => state.setChatView(false), terms: 'view stage character'),
    ]);
    return entries;
  }

  Future<void> _open(int index) async {
    final results = _results;
    if (results.isEmpty) return;
    var at = index.clamp(0, results.length - 1).toInt();
    if (results[at].heading) at = _effectiveSelection(results);
    if (at < 0) return;
    final entry = results[at];
    Navigator.of(context).pop();
    await widget.run(entry.pick);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final results = _results;
    final selected = _effectiveSelection(results);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              decoration: BoxDecoration(borderRadius: Shapes.r24, boxShadow: Shapes.float(c)),
              child: Glass(
                radius: Shapes.r24,
                sigma: 30,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
                      child: Row(
                        children: [
                          Glyph(G.search, size: 19, color: c.muted),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _query,
                              focusNode: _field,
                              autofocus: true,
                              textInputAction: TextInputAction.go,
                              style: context.type.titleMedium,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                hintText: 'Search conversations, routines, clips, memory…',
                                hintStyle: context.type.titleMedium?.copyWith(color: c.faint),
                                isDense: true,
                              ),
                              onChanged: _typed,
                              onSubmitted: (_) => _open(_selected),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Kbd('Esc'),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: c.border),
                    Flexible(
                      child: results.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text('Nothing matches that yet.',
                                  style: context.type.bodyMedium?.copyWith(color: c.muted)),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: Space.s, horizontal: Space.s),
                              itemCount: results.length,
                              itemBuilder: (context, i) {
                                final entry = results[i];
                                if (entry.heading) return _SectionRow(entry: entry);
                                return _ResultRow(
                                  key: _rows[i] ??= GlobalKey(),
                                  entry: entry,
                                  selected: i == selected,
                                  onTap: () => _open(i),
                                  onHover: () => setState(() => _selected = i),
                                );
                              },
                            ),
                    ),
                    Divider(height: 1, color: c.border),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                      child: Wrap(
                        spacing: 14,
                        runSpacing: 6,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              _Hint(keys: ['↑', '↓'], label: 'move'),
                              SizedBox(width: 14),
                              _Hint(keys: ['Enter'], label: 'open'),
                            ],
                          ),
                          _SearchStatus(
                            busy: _remoteBusy,
                            failed: _remoteFailed,
                            count: results.where((e) => !e.heading).length,
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
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({super.key, required this.entry, required this.selected, required this.onTap, required this.onHover});
  final _Entry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: selected,
      label: '${entry.title}. ${entry.subtitle}',
      child: MouseRegion(
        onEnter: (_) => onHover(),
        child: AnimatedContainer(
          duration: context.motion(Motion.quick),
          curve: Motion.standard,
          constraints: BoxConstraints(minHeight: _rowExtent(context, heading: false)),
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : Colors.transparent,
            borderRadius: Shapes.r12,
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: Shapes.r12,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: context.motion(Motion.quick),
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: selected ? c.accent.withValues(alpha: c.dark ? .22 : .12) : c.sunken,
                    borderRadius: Shapes.r10,
                  ),
                  alignment: Alignment.center,
                  child: Glyph(entry.glyph, size: 17, color: selected ? c.accent : c.muted),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: context.type.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: selected ? c.accent : c.text,
                          )),
                      const SizedBox(height: 2),
                      Text(entry.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(entry.kind, style: context.type.labelMedium?.copyWith(color: c.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: BoxConstraints(minHeight: _rowExtent(context, heading: true)),
      padding: const EdgeInsets.fromLTRB(16, 9, 14, 0),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: Text(entry.title.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: context.type.labelSmall?.copyWith(color: c.faint, letterSpacing: .9,
                    fontWeight: FontWeight.w600)),
          ),
          if (entry.count != null)
            Text('${entry.count}', style: context.type.labelSmall?.copyWith(color: c.faint)),
        ],
      ),
    );
  }
}

class _SearchStatus extends StatelessWidget {
  const _SearchStatus({required this.busy, required this.failed, required this.count});
  final bool busy;
  final bool failed;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = context.type.labelMedium?.copyWith(color: c.faint);
    if (busy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(dimension: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.faint)),
          const SizedBox(width: 7),
          Text('Searching your PC…', style: style),
        ],
      );
    }
    if (failed) return Text('PC search unavailable', style: style);
    return Text('$count result${count == 1 ? '' : 's'}', style: style);
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.keys, required this.label});
  final List<String> keys;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final key in keys) ...[Kbd(key), const SizedBox(width: 4)],
          const SizedBox(width: 2),
          Text(label, style: context.type.labelMedium?.copyWith(color: context.c.faint)),
        ],
      );
}

/// A quiet "Search · Ctrl K" affordance for the title bar.
class PaletteButton extends StatelessWidget {
  const PaletteButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final shape = RoundedRectangleBorder(
      borderRadius: Shapes.r10,
      side: BorderSide(color: c.border),
    );
    return Tooltip(
      message: 'Search everything (Ctrl+K)',
      child: Semantics(
        button: true,
        label: 'Search everything',
        child: Material(
          type: MaterialType.transparency,
          child: Ink(
            height: 30,
            decoration: ShapeDecoration(color: c.sunken, shape: shape),
            child: InkWell(
              onTap: onTap,
              customBorder: shape,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Glyph(G.search, size: 14, color: c.muted),
                    const SizedBox(width: 7),
                    Text('Search', style: context.type.labelMedium?.copyWith(color: c.muted)),
                    const SizedBox(width: 8),
                    const Kbd('Ctrl+K'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cheap fuzzy score: exact, prefix, word start, substring, then letters in order.
int _score(String haystack, String query) {
  final h = haystack.toLowerCase();
  final q = query.toLowerCase();
  if (q.isEmpty) return 0;
  if (h == q) return 1000;
  if (h.startsWith(q)) return 900 - (h.length < 80 ? h.length : 80);
  for (final word in h.split(RegExp(r'[\s·,.:;()\[\]/\\_-]+'))) {
    if (word.startsWith(q)) return 750 - (h.length < 80 ? h.length : 80);
  }
  final at = h.indexOf(q);
  if (at >= 0) return 600 - (at < 200 ? at : 200);
  var qi = 0;
  var gaps = 0;
  for (var i = 0; i < h.length && qi < q.length; i++) {
    if (h[i] == q[qi]) {
      qi++;
    } else if (qi > 0) {
      gaps++;
    }
  }
  if (qi == q.length) {
    final cut = gaps ~/ 6;
    return 300 - (cut < 200 ? cut : 200);
  }
  return -1;
}
