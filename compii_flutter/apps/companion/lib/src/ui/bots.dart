import 'package:flutter/material.dart';

import '../console/character.dart' show Mood;
import '../console/core_client.dart';
import '../art/halo.dart' show colorHex;
import 'agent_character.dart';
import 'color_chooser.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'proactive.dart' show BotRoutines;
import 'shell.dart';
import 'thread.dart' show Run;
import 'tokens.dart';
import 'voice_dock.dart';

const _defaultColor = '#3F86FF';

Color hexColor(String hex, Color fallback) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

Color botColor(BotView bot, Color fallback) => hexColor(bot.color, fallback);

/// The character a bot wears. Core saves one on every teammate; anything
/// unreadable falls back to a design drawn from the name, so it stays stable.
AgentLook botLook(BotView bot) => AgentLook.parse(bot.avatar, name: bot.name);

const modeLabels = {'solo': 'Solo', 'team': 'Team player', 'lead': 'Team lead'};
const modeNotes = {
  'solo': 'Works alone in its lane; never hands work to another teammate.',
  'team': 'Can hand part of a job to a specialist, check the result and send it back.',
  'lead': 'Coordinates the team and can propose a new teammate when a role is missing.',
};

GlyphData modeGlyph(String mode) => switch (mode) {
      'solo' => G.hand,
      'lead' => G.flag,
      _ => G.team,
    };

/// The lane, in the user's words: "Mail & calendar · Memory & knowledge".
String laneNames(CoreClient core, BotView bot) {
  if (bot.tools.isEmpty) return 'Every tool';
  final byKey = {for (final p in core.botPacks) '${p['key']}': '${p['label']}'};
  final names = [for (final k in bot.tools) byKey[k] ?? k];
  return names.isEmpty ? 'Every tool' : names.join(' · ');
}

/// A pill-sized version of the lane: one name, a count, or "Every tool".
String laneShort(CoreClient core, BotView bot) {
  if (bot.tools.isEmpty || bot.tools.length > 1) {
    return bot.tools.length > 1 ? '${bot.tools.length} lanes' : 'Every tool';
  }
  final key = bot.tools.first;
  for (final p in core.botPacks) {
    if ('${p['key']}' == key) return '${p['label']}';
  }
  return key;
}

/// Who is thinking behind this teammate, in its own words. Core names the AI that answers, so
/// a teammate that was given a model which can't run says so instead of wearing another one.
String aiLine(BotView bot) {
  if (bot.provider.isEmpty) {
    return bot.answersWith.isEmpty
        ? 'Answers with Compii’s AI.'
        : 'Answers with ${bot.answersWith}, the AI you chose in Settings.';
  }
  if (bot.modelNote.isNotEmpty) return 'Wanted ${bot.provider}, but it can’t run yet: ${bot.modelNote}';
  return bot.answersWith.isEmpty
      ? 'Answers with ${bot.provider}, its own AI.'
      : 'Answers with ${bot.answersWith} — its own AI, not Compii’s.';
}

/// The AI line, sized for a roster card: a teammate that thinks with Compii's AI has nothing
/// special to say, so only its own choice — or a choice that can't run — takes a line.
String aiShort(BotView bot) {
  if (bot.provider.isEmpty) return '';
  if (bot.modelNote.isNotEmpty) return 'Wanted ${bot.provider}: ${bot.modelNote}';
  return bot.answersWith.isEmpty ? bot.provider : bot.answersWith;
}

/// A bot's character, on its own soft disc.
class BotAvatar extends StatelessWidget {
  const BotAvatar({
    super.key,
    required this.bot,
    this.size = 28,
    this.ring = false,
    this.animate = false,
    this.mood = Mood.idle,
  });
  final BotView bot;
  final double size;
  final bool ring;
  final bool animate;
  final Mood mood;

  @override
  Widget build(BuildContext context) {
    final look = botLook(bot);
    return AgentFace(
      color: botColor(bot, context.c.accent),
      shape: look.shape,
      seed: look.seed,
      size: size,
      ring: ring,
      animate: animate,
      mood: mood,
      semanticLabel: bot.name,
    );
  }
}

/// What this teammate is doing right now, so its face says the same thing as
/// its status line.
Mood botMood(CoreClient core, BotView bot) {
  TaskView? last;
  for (final t in core.ordered) {
    if (t.botId != bot.id) continue;
    if (t.active) return t.pendingApproval != null ? Mood.waiting : Mood.acting;
    last ??= t;
  }
  return switch (last?.status) {
    'failed' => Mood.problem,
    'done' => Mood.happy,
    _ => Mood.idle,
  };
}

/// The bot a thread belongs to, as a small chip.
class BotChip extends StatelessWidget {
  const BotChip({super.key, required this.bot});
  final BotView bot;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = botColor(bot, c.accent);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: c.dark ? .16 : .1),
        borderRadius: Shapes.pill,
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BotAvatar(bot: bot, size: 17),
          const SizedBox(width: 5),
          Text(bot.name, style: context.type.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Everyone in a team chat, as overlapping faces. The one speaking is ringed.
class TeamStrip extends StatelessWidget {
  const TeamStrip({super.key, required this.task, required this.core});
  final TaskView task;
  final CoreClient core;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bots = [for (final id in task.team) core.botFor(id)].whereType<BotView>().take(6).toList();
    if (bots.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: bots.map((b) => b.job.isEmpty ? b.name : '${b.name} — ${b.job}').join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24 + (bots.length - 1) * 15,
            height: 24,
            child: Stack(
              children: [
                for (final (i, bot) in bots.indexed)
                  Positioned(left: i * 15, child: BotAvatar(bot: bot, size: 24, ring: bot.id == task.botId)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text('${bots.length} teammates',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: c.muted)),
          ),
        ],
      ),
    );
  }
}

/// One teammate passing the turn to another, in the thread where it happened.
class HandoffNote extends StatelessWidget {
  const HandoffNote({super.key, required this.event, required this.core});
  final Map<String, dynamic> event;
  final CoreClient core;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final from = core.botFor(event['from_id'] as String?);
    final to = core.botFor(event['to_id'] as String?);
    if (from == null || to == null) return const SizedBox.shrink();
    final note = '${event['note'] ?? ''}'.trim();
    final byUser = event['by'] == 'user';
    // Core names what came with the thread, so the handover is shown, not silent.
    final shared = event['shared'] as Map?;
    final turns = (shared?['turns'] as num?)?.toInt() ?? 0;
    final files = [for (final f in (shared?['files'] as List? ?? const [])) '$f'];
    final carried = [
      if (turns > 0) '$turns ${turns == 1 ? 'exchange' : 'exchanges'}',
      if (files.isNotEmpty) '${files.length} ${files.length == 1 ? 'file' : 'files'}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
      decoration: BoxDecoration(
        color: c.sunken,
        borderRadius: Shapes.r10,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BotAvatar(bot: from, size: 16),
              const SizedBox(width: 5),
              Flexible(child: Text(from.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.labelMedium)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Glyph(G.chevronRight, size: 12, color: c.faint),
              ),
              BotAvatar(bot: to, size: 16),
              const SizedBox(width: 5),
              Flexible(child: Text(to.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.labelMedium)),
              if (byUser) ...[
                const Spacer(),
                Text('you asked', style: context.type.labelMedium?.copyWith(color: c.faint)),
              ],
            ],
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(note, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: context.type.bodySmall?.copyWith(color: c.muted)),
          ],
          if (carried.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Shared with ${to.name}: $carried', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: context.type.labelSmall?.copyWith(color: c.faint)),
          ],
        ],
      ),
    );
  }
}

/// Move a conversation to another teammate because the user asked. The thread itself
/// travels; nothing outside it is shared.
Future<void> showHandover(
  BuildContext context, {
  required CoreClient core,
  required AppState state,
  required Run run,
  required TaskView task,
}) async {
  final from = core.botFor(task.botId);
  final others = [for (final b in core.bots) if (b.id != task.botId && !b.archived) b];
  if (others.isEmpty) return;
  final to = await showDialog<BotView>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Hand this conversation to…'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              from == null
                  ? 'They take over from here, with everything said in this thread.'
                  : '${from.name} keeps the thread and passes it on. Nothing outside this conversation is shared.',
              style: context.type.bodySmall?.copyWith(color: context.c.muted),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final b in others)
                      ListTile(
                        leading: BotAvatar(bot: b, size: 30),
                        title: Text(b.name),
                        subtitle: b.job.isEmpty
                            ? null
                            : Text(b.job, maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(ctx, b),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
    ),
  );
  if (to == null) return;
  await run(() async {
    await core.transferConversation(task.id, to.id);
    state.open(task.id);
  });
}

/// A bot's own home: who it is, what it remembers, and the conversations it owns.
class BotHome extends StatefulWidget {
  const BotHome({super.key, required this.core, required this.state, required this.run, required this.bot});
  final CoreClient core;
  final AppState state;
  final Run run;
  final BotView bot;

  @override
  State<BotHome> createState() => _BotHomeState();
}

class _BotHomeState extends State<BotHome> {
  List<TaskView> _threads = const [];
  bool _loaded = false;
  String? _historyError;

  CoreClient get core => widget.core;
  AppState get state => widget.state;
  Run get run => widget.run;
  BotView get bot => widget.bot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final threads = await core.fetchConversations(bot.id);
      if (!mounted) return;
      setState(() {
        _threads = threads;
        _loaded = true;
        _historyError = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      // The page still works from what this window already knows; say what couldn't be read.
      setState(() {
        _loaded = true;
        _historyError = '$e';
      });
    }
  }

  Future<void> _start(String text, [List<String> files = const []]) async {
    try {
      final id = await core.startConversation(text, botId: bot.id, attachments: files);
      state.open(id);
    } catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = botColor(bot, c.accent);
    // Until Core answers, show the threads this window is already holding.
    final threads = _threads.isNotEmpty
        ? _threads
        : core.ordered.where((t) => t.belongsTo(bot.id)).toList();
    final accepted = (bot.stats['accepted'] as num?)?.toInt() ?? 0;
    final rejected = (bot.stats['rejected'] as num?)?.toInt() ?? 0;
    final reviewed = accepted + rejected;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 18, 32, 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                children: [
                  Aura(
                    size: 150,
                    color: color,
                    child: BotAvatar(bot: bot, size: 78, ring: true, animate: true, mood: botMood(core, bot)),
                  ),
                  const SizedBox(height: 16),
                  Text(bot.name, textAlign: TextAlign.center, style: context.type.displaySmall),
                  if (bot.job.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(bot.job, textAlign: TextAlign.center, style: context.type.bodyLarge?.copyWith(color: c.muted)),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      Pill(
                        bot.trust == 'trusted' ? 'Trusted' : 'On probation',
                        color: bot.trust == 'trusted' ? c.success : c.warning,
                        glyph: bot.trust == 'trusted' ? G.shieldCheck : G.warning,
                      ),
                      Pill(modeLabels[bot.mode] ?? 'Team player', color: c.muted, glyph: modeGlyph(bot.mode)),
                      Tooltip(
                        message: 'Tools it may use: ${laneNames(core, bot)}',
                        waitDuration: const Duration(milliseconds: 350),
                        child: Pill(laneShort(core, bot), color: c.muted, glyph: G.folder),
                      ),
                      if (reviewed > 0)
                        Pill('$accepted of $reviewed jobs accepted', color: c.muted, glyph: G.checkCircle),
                      if (bot.working.isNotEmpty)
                        Pill('Working now', color: color, glyph: G.sync, pulse: true),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      aiLine(bot),
                      key: const Key('bot-ai'),
                      textAlign: TextAlign.center,
                      style: context.type.bodySmall
                          ?.copyWith(color: bot.modelNote.isEmpty ? c.faint : c.warning),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        onPressed: () => showBotEditor(context, core: core, state: state, run: run, bot: bot),
                        icon: const Glyph(G.edit, size: 15),
                        label: const Text('Edit'),
                      ),
                      TextButton.icon(
                        onPressed: () => showTeamPicker(context, core: core, state: state, preselect: [bot.id]),
                        icon: const Glyph(G.team, size: 16),
                        label: const Text('Team up'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              VoiceDock(
                core: core,
                state: state,
                onSend: _start,
                onSendFiles: _start,
                run: run,
                showCharacter: false,
                hint: 'Ask ${bot.name} to…',
              ),
              if (bot.facts.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('REMEMBERS', style: context.type.labelSmall),
                const SizedBox(height: 8),
                Panel(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (i, fact) in bot.facts.take(5).indexed) ...[
                        if (i > 0) const SizedBox(height: 7),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Container(width: 5, height: 5, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                            ),
                            const SizedBox(width: 9),
                            Expanded(child: Text(fact, style: context.type.bodySmall?.copyWith(color: c.muted))),
                          ],
                        ),
                      ],
                      if (bot.facts.length > 5) ...[
                        const SizedBox(height: 6),
                        Text('and ${bot.facts.length - 5} more', style: context.type.labelMedium?.copyWith(color: c.faint)),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              BotRoutines(core: core, run: run, bot: bot, onOpenTask: state.open),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text('CONVERSATIONS', style: context.type.labelSmall),
                  const Spacer(),
                  if (_historyError != null)
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _historyError = null);
                        _load();
                      },
                      icon: const Glyph(G.undo, size: 14),
                      label: const Text('Try again'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (threads.isEmpty && !_loaded)
                Row(
                  children: [
                    SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
                    const SizedBox(width: 10),
                    Text('Reading ${bot.name}’s conversations…',
                        style: context.type.labelMedium?.copyWith(color: c.faint)),
                  ],
                )
              else if (threads.isEmpty)
                Panel(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                  child: Text(
                    'No conversations with ${bot.name} yet. Ask for something above and it stays in this lane.',
                    style: context.type.bodySmall?.copyWith(color: c.faint),
                  ),
                )
              else
                for (final t in threads) _BotThread(task: t, color: color, onTap: () => state.open(t.id)),
              if (_historyError != null) ...[
                const SizedBox(height: 8),
                Text('This is what this window still holds. $_historyError',
                    style: context.type.labelMedium?.copyWith(color: c.warning)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A shared thread: several bots, one conversation, and work handed to whoever owns it.
class TeamHome extends StatelessWidget {
  const TeamHome({super.key, required this.core, required this.state, required this.run, required this.bots});
  final CoreClient core;
  final AppState state;
  final Run run;
  final List<BotView> bots;

  Future<void> _start(String text, [List<String> files = const []]) async {
    try {
      final id = await core.startConversation(text, botId: bots.first.id,
          team: [for (final b in bots) b.id], attachments: files);
      state.open(id);
    } catch (e) {
      state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = botColor(bots.first, c.accent);
    final threads = core.ordered.where((t) => t.isTeam).take(5).toList();
    final names = bots.map((b) => b.name).join(', ');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 18, 32, 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Aura(
                size: 154,
                color: color,
                child: SizedBox(
                  width: 104,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [for (final bot in bots.take(4)) BotAvatar(bot: bot, size: 44, ring: true)],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Your team', textAlign: TextAlign.center, style: context.type.displaySmall),
              const SizedBox(height: 5),
              Text(names, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: context.type.bodyLarge?.copyWith(color: c.muted)),
              const SizedBox(height: 8),
              Text('One shared thread. Compii hands a step to whoever owns it — or say @Name to pick who answers.',
                  textAlign: TextAlign.center, style: context.type.bodySmall?.copyWith(color: c.faint)),
              const SizedBox(height: 18),
              VoiceDock(
                core: core,
                state: state,
                onSend: _start,
                onSendFiles: _start,
                run: run,
                showCharacter: false,
                hint: 'Ask the team…',
              ),
              const SizedBox(height: 24),
              Text('WHO IS HERE', style: context.type.labelSmall),
              const SizedBox(height: 8),
              Panel(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Column(
                  children: [
                    for (final (i, bot) in bots.indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.border),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Row(
                          children: [
                            BotAvatar(bot: bot, size: 26),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(bot.name, style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                  if (bot.job.isNotEmpty)
                                    Text(bot.job, maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: context.type.bodySmall?.copyWith(color: c.muted)),
                                ],
                              ),
                            ),
                            if (i == 0)
                              Text('starts', style: context.type.labelMedium?.copyWith(color: botColor(bot, c.accent))),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (threads.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('RECENT TEAM CHATS', style: context.type.labelSmall),
                const SizedBox(height: 8),
                for (final t in threads) _BotThread(task: t, color: color, onTap: () => state.open(t.id)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Pick who shares a new team chat (2–6 bots). The first picked opens the thread.
Future<void> showTeamPicker(
  BuildContext context, {
  required CoreClient core,
  required AppState state,
  List<String> preselect = const [],
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _TeamPicker(core: core, state: state, preselect: preselect),
    );

class _TeamPicker extends StatefulWidget {
  const _TeamPicker({required this.core, required this.state, required this.preselect});
  final CoreClient core;
  final AppState state;
  final List<String> preselect;

  @override
  State<_TeamPicker> createState() => _TeamPickerState();
}

class _TeamPickerState extends State<_TeamPicker> {
  late final List<String> _picked = [
    for (final id in widget.preselect)
      if (widget.core.botFor(id) != null) id,
  ];

  void _toggle(String id) => setState(() {
        if (_picked.contains(id)) {
          _picked.remove(id);
        } else if (_picked.length < 6) {
          _picked.add(id);
        }
      });

  void _start() {
    widget.state.pickTeam(_picked);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // A teammate that has been put away is not offered for new work.
    final bots = [for (final b in widget.core.bots) if (!b.archived) b];
    return AlertDialog(
      title: const Text('New team chat'),
      content: SizedBox(
        width: 460,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pick 2–6 teammates. The first one starts; after that they hand work to whoever owns it. '
                  'You can also say @Name to choose who answers.',
                  style: context.type.bodySmall?.copyWith(color: c.muted)),
              const SizedBox(height: 14),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final bot in bots)
                      InkWell(
                        borderRadius: Shapes.r10,
                        onTap: () => _toggle(bot.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                          child: Row(
                            children: [
                              BotAvatar(bot: bot, size: 28, ring: _picked.contains(bot.id)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(bot.name, style: context.type.bodyMedium),
                                    if (bot.job.isNotEmpty)
                                      Text(bot.job, maxLines: 1, overflow: TextOverflow.ellipsis,
                                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (_picked.contains(bot.id))
                                Container(
                                  width: 22,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: botColor(bot, c.accent).withValues(alpha: .16),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: botColor(bot, c.accent)),
                                  ),
                                  child: Text('${_picked.indexOf(bot.id) + 1}',
                                      style: context.type.labelMedium?.copyWith(
                                          color: botColor(bot, c.accent), fontWeight: FontWeight.w700)),
                                )
                              else
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: c.borderStrong),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text('${_picked.length} picked${_picked.length > 1 ? ' · ${widget.core.botFor(_picked.first)?.name} starts' : ''}',
                  style: context.type.labelMedium?.copyWith(color: c.faint)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _picked.length >= 2 ? _start : null,
          icon: const Glyph(G.team, size: 17),
          label: const Text('Start chat'),
        ),
      ],
    );
  }
}

class _BotThread extends StatelessWidget {
  const _BotThread({required this.task, required this.color, required this.onTap});
  final TaskView task;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final waiting = task.pendingApproval != null;
    final (String label, Color state) = waiting
        ? ('Needs you', c.warning)
        : switch (task.status) {
            'running' => ('Working', c.accent),
            'failed' => ('Problem', c.danger),
            'stopped' => ('Stopped', c.faint),
            _ => ('Done', c.success),
          };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: Shapes.r12,
        child: Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(width: 3, height: 30, decoration: BoxDecoration(color: waiting || task.active ? color : c.border, borderRadius: Shapes.pill)),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titleOf(task), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodyMedium),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(width: 6, height: 6, decoration: BoxDecoration(color: state, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(label, style: context.type.labelMedium?.copyWith(color: c.muted, fontSize: 11.5)),
                        const Spacer(),
                        Text(ago(task.last?['at'] as double? ?? 0), style: context.type.labelMedium?.copyWith(color: c.faint, fontSize: 11.5)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Glyph(G.chevronRight, size: 15, color: c.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Create a teammate (or change one): role, signature, way of working and memory.
Future<void> showBotEditor(
  BuildContext context, {
  required CoreClient core,
  required AppState state,
  required Run run,
  BotView? bot,
  BotView? copy,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _BotEditor(core: core, state: state, run: run, bot: bot, copy: copy),
    );

class _BotEditor extends StatefulWidget {
  const _BotEditor({required this.core, required this.state, required this.run, this.bot, this.copy});
  final CoreClient core;
  final AppState state;
  final Run run;
  final BotView? bot;

  /// An existing teammate to start a new one from: same job, same lane, same AI, new name.
  final BotView? copy;

  @override
  State<_BotEditor> createState() => _BotEditorState();
}

class _BotEditorState extends State<_BotEditor> {
  /// What the form starts from — the teammate being edited, or the one being copied.
  BotView? get _src => widget.bot ?? widget.copy;

  late final _name = TextEditingController(
      text: widget.bot?.name ?? (widget.copy == null ? '' : '${widget.copy!.name} copy'));
  late final _job = TextEditingController(text: _src?.job ?? '');
  late final _instructions = TextEditingController(text: _src?.instructions ?? '');
  final _fact = TextEditingController();
  late String _avatar = _src?.avatar ?? '';
  late String _color = _src?.color ?? _defaultColor;
  String _template = '';
  bool _pinned = false;
  late String _trust = widget.bot?.trust ?? 'probation';
  late String _mode = _src?.mode ?? 'team';
  late List<String> _tools = [...?_src?.tools];

  /// The AI this teammate thinks with. Empty means Compii's own, from Settings → Brain.
  late String _provider = _src?.provider ?? '';
  late final _model = TextEditingController(text: _src?.model ?? '');
  String? _aiProblem;
  bool _busy = false;
  String? _error;

  bool get _creating => widget.bot == null;

  AgentLook get _look => AgentLook.parse(_avatar, name: _name.text.trim());

  Color get _tint => hexColor(_color, Theme.of(context).colorScheme.primary);

  @override
  void initState() {
    super.initState();
    _pinned = widget.bot?.pinned ?? false;
    // A copy keeps its role, so it lands in the same category of the directory.
    _template = widget.copy?.template ?? '';
    // Core's own list of AIs, so the choice here is exactly what Compii can reach.
    _loadAis().ignore();
  }

  Future<void> _loadAis() async {
    if (widget.bot?.primary == true) return;
    try {
      await widget.core.fetchBrain();
    } catch (e) {
      if (mounted) setState(() => _aiProblem = 'Compii couldn’t read its list of AIs: $e');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _job.dispose();
    _instructions.dispose();
    _fact.dispose();
    _model.dispose();
    super.dispose();
  }

  /// What thinking with another AI means, said plainly — including when it cannot yet.
  String _aiNote(BotView? live) {
    final who = widget.bot?.name ?? 'this teammate';
    if (_provider.isEmpty) return 'Thinks with the AI you chose in Settings → Brain.';
    final preset = widget.core.aiPresets.firstWhere((p) => p['provider'] == _provider, orElse: () => const {});
    final label = '${preset['label'] ?? _provider}';
    if (preset['hasKey'] != true) {
      return '$label needs a key in Settings → Brain. Until you add one, $who answers with Compii’s AI, '
          'and its page says so.';
    }
    if (live != null && live.modelNote.isNotEmpty) return '$label: ${live.modelNote}';
    final model = _model.text.trim();
    return 'Thinks with $label${model.isEmpty ? '' : ' · $model'}, whatever your own AI is set to.';
  }

  BotView? get _current {
    final id = widget.bot?.id;
    return id == null ? null : widget.core.botFor(id);
  }

  void _pickTemplate(Map<String, dynamic> t) {
    setState(() {
      _template = '${t['key']}';
      if (_name.text.trim().isEmpty) _name.text = '${t['name'] ?? ''}';
      _job.text = '${t['job'] ?? ''}';
      _instructions.text = '${t['instructions'] ?? ''}';
      _avatar = '${t['avatar'] ?? ''}';
      _color = '${t['color'] ?? _color}';
      if (t['mode'] is String) _mode = '${t['mode']}';
      if (t['tools'] is List) _tools = [for (final k in t['tools'] as List) '$k'];
    });
  }

  Future<void> _chooseFace() async {
    final picked = await showAgentPicker(context, color: _tint, look: _look);
    if (picked != null && mounted) {
      setState(() {
        _avatar = picked.look.encode();
        _color = colorHex(picked.color);
      });
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give this teammate a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_creating) {
        final before = {for (final b in widget.core.bots) b.id};
        await widget.core.createBot(
          name: _name.text.trim(),
          template: _template,
          job: _job.text.trim(),
          instructions: _instructions.text.trim(),
          color: _color,
          avatar: _avatar,
          mode: _mode,
          tools: _tools,
          provider: _provider,
          model: _model.text.trim(),
        );
        final made = widget.core.bots.where((b) => !before.contains(b.id)).toList();
        if (made.isNotEmpty) widget.state.pickBot(made.first.id);
      } else {
        await widget.core.editBot(widget.bot!.id, {
          'name': _name.text.trim(),
          'job': _job.text.trim(),
          'instructions': _instructions.text.trim(),
          'color': _color,
          'avatar': _avatar,
          'pinned': _pinned,
          if (widget.bot!.primary != true) 'trust': _trust,
          if (widget.bot!.primary != true) 'mode': _mode,
          if (widget.bot!.primary != true) 'tools': _tools,
          // Always sent for a teammate: Core reads an empty value as "back to Compii's AI".
          if (widget.bot!.primary != true) 'provider': _provider,
          if (widget.bot!.primary != true) 'model': _model.text.trim(),
        });
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFact() async {
    final text = _fact.text.trim();
    if (text.isEmpty || _current == null) return;
    setState(() => _busy = true);
    try {
      await widget.core.addBotFact(_current!.id, text);
      _fact.clear();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetFact(int index) async {
    final bot = _current;
    if (bot == null) return;
    try {
      await widget.core.forgetBotFact(bot.id, index);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _delete() async {
    final bot = widget.bot!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${bot.name}?'),
        content: const Text('Its conversations stay in Compii, but this role and its memory are removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.core.deleteBot(bot.id);
      if (widget.state.botId == bot.id) widget.state.pickBot(null);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final current = _current;
    final templates = widget.core.botTemplates;
    return AlertDialog(
      title: Text(_creating ? 'New teammate' : 'Edit ${current?.name ?? widget.bot!.name}'),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_creating && templates.isNotEmpty) ...[
                  Text('Start from a role', style: context.type.labelSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in templates)
                        ChoiceChip(
                          avatar: AgentFace(
                            color: hexColor('${t['color'] ?? ''}', c.accent),
                            shape: AgentLook.parse('${t['avatar'] ?? ''}', name: '${t['name'] ?? ''}').shape,
                            seed: AgentLook.parse('${t['avatar'] ?? ''}', name: '${t['name'] ?? ''}').seed,
                            size: 18,
                            backgroundDisc: false,
                          ),
                          label: Text('${t['name'] ?? ''}'),
                          selected: _template == '${t['key']}',
                          onSelected: (_) => _pickTemplate(t),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AgentFace(
                      color: _tint,
                      shape: _look.shape,
                      seed: _look.seed,
                      size: 46,
                      ring: true,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        children: [
                          TextField(
                            controller: _name,
                            textCapitalization: TextCapitalization.words,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(labelText: 'Name', hintText: 'Inbox Manager'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _job,
                            decoration: const InputDecoration(labelText: 'Job', hintText: 'Triage mail and leave replies ready to send'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('Character', style: context.type.labelSmall),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _busy ? null : _chooseFace,
                      icon: const Glyph(G.wand, size: 15),
                      label: const Text('Change character'),
                    ),
                  ],
                ),
                Text(
                  'A live furry character that breathes, blinks and follows your pointer, in this teammate’s colour.',
                  style: context.type.bodySmall?.copyWith(color: c.faint),
                ),
                const SizedBox(height: 12),
                Text('Colour', style: context.type.labelSmall),
                const SizedBox(height: 6),
                ColorChooser(
                  color: _tint,
                  onChanged: (v) => setState(() => _color = colorHex(v)),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _instructions,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'How it works',
                    hintText: 'Read mail, sort what needs me from what can wait, draft replies. Never send.',
                  ),
                ),
                const SizedBox(height: 14),
                Text('How it works with the team', style: context.type.labelSmall),
                const SizedBox(height: 6),
                if (current?.primary == true)
                  Text(
                    'Compii leads the team: it can hand work to any teammate, review their work and propose new ones. '
                    'It keeps every tool.',
                    style: context.type.bodySmall?.copyWith(color: c.faint),
                  )
                else ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final m in const ['solo', 'team', 'lead'])
                        ChoiceChip(
                          avatar: Glyph(modeGlyph(m), size: 14),
                          label: Text(modeLabels[m]!),
                          selected: _mode == m,
                          onSelected: (_) => setState(() => _mode = m),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(modeNotes[_mode] ?? '', style: context.type.bodySmall?.copyWith(color: c.faint)),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Text('Its lane', style: context.type.labelSmall),
                      const Spacer(),
                      TextButton(
                        onPressed: _tools.isEmpty ? null : () => setState(() => _tools = []),
                        child: const Text('Everything'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in widget.core.botPacks)
                        Tooltip(
                          message: '${p['description'] ?? ''}',
                          waitDuration: const Duration(milliseconds: 350),
                          child: FilterChip(
                            label: Text('${p['label'] ?? p['key']}'),
                            selected: _tools.contains('${p['key']}'),
                            onSelected: (_) => setState(() {
                              final key = '${p['key']}';
                              _tools.contains(key) ? _tools.remove(key) : _tools.add(key);
                            }),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _tools.isEmpty
                        ? 'Every tool: this teammate can do anything Compii can.'
                        : 'Only these packs: a step outside the lane comes back as “that isn’t my job”, '
                            'so the work stays with the right teammate.',
                    style: context.type.bodySmall?.copyWith(color: c.faint),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Text('Answers with', style: context.type.labelSmall),
                      const Spacer(),
                      if (_provider.isNotEmpty)
                        TextButton(
                          onPressed: _busy ? null : () => setState(() { _provider = ''; _model.clear(); }),
                          child: const Text('Compii’s AI'),
                        ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in widget.core.aiPresets)
                        ChoiceChip(
                          avatar: Glyph(p['hasKey'] == true ? G.check : G.key, size: 13,
                              color: p['hasKey'] == true ? c.success : c.warning),
                          label: Text('${p['label']}'),
                          selected: _provider == p['provider'],
                          onSelected: (_) => setState(() {
                            _provider = '${p['provider']}';
                            // The provider's own default model comes from Core, so the app
                            // doesn't invent an id this AI has never heard of.
                            _model.text = '${p['model'] ?? ''}';
                          }),
                        ),
                    ],
                  ),
                  if (widget.core.aiPresets.isEmpty)
                    Text(_aiProblem ?? 'Reading the AIs Compii knows…',
                        style: context.type.bodySmall?.copyWith(color: c.faint))
                  else
                    Text(_aiNote(current), style: context.type.bodySmall?.copyWith(color: c.faint)),
                  if (_provider.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _model,
                      decoration: const InputDecoration(labelText: 'Model', hintText: 'openai/gpt-oss-120b'),
                    ),
                  ],
                ],
                if (!_creating) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Pin to the top'),
                    subtitle: const Text('Pinned teammates sit above the rest in the sidebar.'),
                    value: _pinned,
                    onChanged: (v) => setState(() => _pinned = v),
                  ),
                  if (current?.primary != true)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Trusted teammate'),
                      subtitle: Text(_trust == 'trusted'
                          ? 'Uses your normal approval settings. Change: once per task; sends, deletes and payments still ask.'
                          : 'On probation: every change asks you, and sends, deletes and payments are off.'),
                      value: _trust == 'trusted',
                      onChanged: (v) => setState(() => _trust = v ? 'trusted' : 'probation'),
                    ),
                  const SizedBox(height: 4),
                  Text('WHAT ${(_current?.name ?? '').toUpperCase()} REMEMBERS', style: context.type.labelSmall),
                  const SizedBox(height: 6),
                  for (final (i, f) in (current?.facts ?? const <String>[]).indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(f, style: context.type.bodySmall)),
                          IconButton(
                            tooltip: 'Forget this',
                            visualDensity: VisualDensity.compact,
                            onPressed: _busy ? null : () => _forgetFact(i),
                            icon: const Glyph(G.close, size: 13),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _fact,
                          onSubmitted: (_) => _addFact(),
                          decoration: const InputDecoration(hintText: 'Something this bot should remember'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Add',
                        onPressed: _busy ? null : _addFact,
                        icon: const Glyph(G.plus, size: 16),
                      ),
                    ],
                  ),
                  Text(
                    'Memory here belongs to this bot; Compii’s own memory is separate.',
                    style: context.type.labelMedium?.copyWith(color: c.faint),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (!_creating && current?.primary != true)
          TextButton(
            onPressed: _busy ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: c.danger),
            child: const Text('Delete'),
          ),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_creating ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
