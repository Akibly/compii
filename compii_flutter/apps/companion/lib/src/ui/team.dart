import 'package:flutter/material.dart';

import '../console/core_client.dart';
import 'bots.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'shell.dart';
import 'thread.dart' show Run;
import 'tokens.dart';

/// Who is on the team, what Compii has handed them, and how their work went.
/// This is the supervisor's desk: the roster, the live workload, the record,
/// and the trust ladder in one place.
class TeamPage extends StatefulWidget {
  const TeamPage({super.key, required this.core, required this.state, required this.run});
  final CoreClient core;
  final AppState state;
  final Run run;

  @override
  State<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends State<TeamPage> {
  bool _loading = false;
  bool _showArchived = false;
  String _query = '';
  String _category = '';
  // Wide windows show one teammate beside the directory; this is which one.
  String? _selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || widget.core.status != CoreStatus.online) return;
    setState(() => _loading = true);
    try {
      await widget.core.fetchTeam();
    } catch (e) {
      widget.state.fail(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newTeammate() =>
      showBotEditor(context, core: widget.core, state: widget.state, run: widget.run);

  void _clearFilters() => setState(() {
        _query = '';
        _category = '';
        _showArchived = false;
      });

  /// Put a teammate away, keeping its role, its memory and every conversation it had.
  Future<void> _archive(BotView bot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Archive ${bot.name}?'),
        content: Text('Nothing is thrown away: the role, what ${bot.name} learnt and your conversations stay, '
            'and you can open them again. But ${bot.name} leaves the team — Compii stops handing work to it, its '
            'errands stop firing, and a new conversation needs it brought back first.\n\n'
            'Deleting a teammate is a different thing, and it does forget its memory.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it on the team')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.core.editBot(bot.id, {'archived': true});
      await _refresh();
    } catch (e) {
      widget.state.fail(e);
    }
  }

  Future<void> _restore(BotView bot) async {
    try {
      await widget.core.editBot(bot.id, {'archived': false});
      await _refresh();
    } catch (e) {
      widget.state.fail(e);
    }
  }

  Future<void> _trust(BotView bot, bool trusted) async {
    if (trusted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Make ${bot.name} trusted?'),
          content: Text('Trusted teammates use your normal approval settings: changes ask once per task, and sends, '
              'deletes and payments still ask every time.\n\nNew teammates start on probation for a reason. Promote '
              '${bot.name} once their work has been checked a few times.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep on probation')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Make trusted')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await widget.core.editBot(bot.id, {'trust': trusted ? 'trusted' : 'probation'});
      await _refresh();
    } catch (e) {
      widget.state.fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final primary = widget.core.primaryBot;
    final everyone = widget.core.bots.where((b) => !b.primary).toList();
    // An archived teammate is off the page you work from, not off the roster: its conversations
    // still name it, so the list keeps it and one switch decides whether you are looking at them.
    final onTeam = [for (final b in everyone) if (!b.archived) b];
    final putAway = [for (final b in everyone) if (b.archived) b];
    final pool = _showArchived ? putAway : onTeam;
    final kinds = <String>{for (final b in pool) if (b.category.isNotEmpty) b.category};
    final categories = kinds.toList()..sort();
    final q = _query.trim().toLowerCase();
    final teammates = [
      for (final b in pool)
        if ((_category.isEmpty || b.category == _category) &&
            (q.isEmpty ||
                b.name.toLowerCase().contains(q) ||
                b.job.toLowerCase().contains(q) ||
                laneNames(widget.core, b).toLowerCase().contains(q)))
          b,
    ];
    final filtering = q.isNotEmpty || _category.isNotEmpty || _showArchived;
    final jobs = widget.core.teamJobs.take(14).toList();
    // A wide window works like the rest of the app: the directory on the left, the teammate you
    // picked on the right, and its conversations under it. Narrow windows keep the card grid.
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    final selected = teammates.where((b) => b.id == _selected).firstOrNull ?? teammates.firstOrNull;
    return PageScaffold(
      glyph: G.team,
      title: 'Team',
      subtitle: 'Compii leads this team. Teammates can pull each other in, check what comes back and send it back — '
          'and every handoff is recorded. You can give any teammate a job directly.',
      maxWidth: 980,
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: 'Refresh the record',
            onPressed: _loading ? null : _refresh,
            icon: _loading
                ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent))
                : const Glyph(G.sync, size: 18),
          ),
          FilledButton.icon(
            onPressed: _newTeammate,
            icon: Glyph(G.plus, size: 15, color: c.onAccent),
            label: const Text('New teammate'),
          ),
        ],
      ),
      children: [
        if (primary != null) ...[
          _CompiiBand(bot: primary, core: widget.core, onTalk: () => widget.state.pickBot(null)),
          const SizedBox(height: 26),
        ],
        if (widget.core.teamProposals.isNotEmpty) ...[
          _Heading('WAITING FOR YOUR ANSWER', widget.core.teamProposals.length),
          const SizedBox(height: 8),
          for (final p in widget.core.teamProposals)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProposalRow(proposal: p, core: widget.core, onChanged: _refresh),
            ),
          const SizedBox(height: 20),
        ],
        _Heading(_showArchived ? 'ARCHIVED TEAMMATES' : 'TEAMMATES', teammates.length),
        const SizedBox(height: 8),
        if (everyone.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: _showArchived ? 'Search archived teammates' : 'Search by name, job or lane',
                      prefixIcon: const Glyph(G.search, size: 15),
                      isDense: true,
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear the search',
                              icon: const Glyph(G.close, size: 14),
                              onPressed: () => setState(() => _query = ''),
                            ),
                    ),
                  ),
                ),
              ),
              if (putAway.isNotEmpty)
                ChoiceChip(
                  label: Text(_showArchived ? 'Archived (${putAway.length})' : 'Archive (${putAway.length})'),
                  avatar: Glyph(G.box, size: 14, color: _showArchived ? c.accent : c.muted),
                  selected: _showArchived,
                  onSelected: (_) => setState(() {
                    _showArchived = !_showArchived;
                    _category = '';
                  }),
                ),
              if (filtering)
                TextButton(onPressed: _clearFilters, child: const Text('Clear')),
            ],
          ),
          if (categories.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Every kind'),
                  selected: _category.isEmpty,
                  onSelected: (_) => setState(() => _category = ''),
                ),
                for (final cat in categories)
                  ChoiceChip(
                    label: Text(cat),
                    selected: _category == cat,
                    onSelected: (_) => setState(() => _category = _category == cat ? '' : cat),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
        ],
        if (everyone.isEmpty)
          Panel(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No teammates yet.', style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('Compii can do everything itself. A teammate is for work that keeps coming back: invoices, '
                    'research, mail. Ask Compii when you notice a pattern — it will suggest a role and let you name '
                    'it. Or make one now and write the job yourself.',
                    style: context.type.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _newTeammate,
                  icon: Glyph(G.plus, size: 15, color: c.onAccent),
                  label: const Text('Create a teammate'),
                ),
              ],
            ),
          )
        else if (teammates.isEmpty)
          Panel(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _showArchived
                        ? (q.isEmpty
                            ? 'Nothing is archived.'
                            : 'No archived teammate matches “$_query”.')
                        : _category.isEmpty
                            ? 'No teammate matches “$_query”. There ${pool.length == 1 ? 'is 1' : 'are ${pool.length}'} '
                                'in the team.'
                            : 'No $_category teammate matches “$_query”.',
                    style: context.type.bodySmall?.copyWith(color: c.muted),
                  ),
                ),
                TextButton(onPressed: _clearFilters, child: const Text('Show everyone')),
              ],
            ),
          )
        else if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 320,
                child: Column(
                  children: [
                    for (final bot in teammates)
                      _DirectoryRow(
                        bot: bot,
                        core: widget.core,
                        selected: selected?.id == bot.id,
                        onTap: () => setState(() => _selected = bot.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (selected != null)
                      _TeammateCard(
                        bot: selected,
                        core: widget.core,
                        state: widget.state,
                        run: widget.run,
                        onAssign: () => widget.state.pickBot(selected.id),
                        onOpenThread: widget.state.open,
                        onTrust: (v) => _trust(selected, v),
                        onArchive: () => _archive(selected),
                        onRestore: () => _restore(selected),
                      ),
                    if (selected != null) ...[
                      const SizedBox(height: 18),
                      _SelectedConversations(
                        key: ValueKey(selected.id),
                        bot: selected,
                        core: widget.core,
                        onOpen: widget.state.open,
                        onOpenLane: () => widget.state.pickBot(selected.id),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          )
        else
          LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 760;
              final width = wide ? (box.maxWidth - 14) / 2 : box.maxWidth;
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final bot in teammates)
                    SizedBox(
                      width: width,
                      child: _TeammateCard(
                        bot: bot,
                        core: widget.core,
                        state: widget.state,
                        run: widget.run,
                        onAssign: () => widget.state.pickBot(bot.id),
                        onOpenThread: widget.state.open,
                        onTrust: (v) => _trust(bot, v),
                        onArchive: () => _archive(bot),
                        onRestore: () => _restore(bot),
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 26),
        _Heading('RECENT JOBS', jobs.length),
        const SizedBox(height: 8),
        if (jobs.isEmpty)
          Panel(
            padding: const EdgeInsets.all(18),
            child: Text('When Compii hands a job to a teammate, it lands here with the result and whether Compii '
                'accepted it.', style: context.type.bodySmall?.copyWith(color: c.muted)),
          )
        else
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, job) in jobs.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: c.border),
                  _JobRow(job: job, core: widget.core, state: widget.state),
                ],
              ],
            ),
          ),
        const SizedBox(height: 26),
        _Heading('HOW WORK MOVES', null),
        const SizedBox(height: 8),
        Panel(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TrustLine(
                glyph: G.team,
                color: c.accent,
                title: 'Compii leads',
                body: 'It decides what to do itself, hands the rest to the right teammate, can run several jobs at '
                    'once, checks the result and either accepts it or sends it back with the exact gap.',
              ),
              const SizedBox(height: 12),
              _TrustLine(
                glyph: G.flag,
                color: c.muted,
                title: 'Team players and leads',
                body: 'A teammate can hand part of its own job to another specialist and review it itself. A lead '
                    'can also propose a new teammate when a role is missing. Work never circles back on itself.',
              ),
              const SizedBox(height: 12),
              _TrustLine(
                glyph: G.hand,
                color: c.muted,
                title: 'Solo',
                body: 'Works only inside its own lane and never hands work on. Use it for a role that should stay '
                    'predictable and self-contained.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        _Heading('HOW TRUST WORKS', null),
        const SizedBox(height: 8),
        Panel(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TrustLine(
                glyph: G.warning,
                color: c.warning,
                title: 'On probation',
                body: 'New teammates read and prepare. Every change asks you, and sends, deletes and payments are off.',
              ),
              const SizedBox(height: 12),
              _TrustLine(
                glyph: G.shieldCheck,
                color: c.success,
                title: 'Trusted',
                body: 'The full toolset, under your normal approval settings. You promote someone after their work '
                    'has been checked and accepted.',
              ),
              const SizedBox(height: 12),
              _TrustLine(
                glyph: G.team,
                color: c.accent,
                title: 'Compii',
                body: 'Always full trust. It is the one that assigns, checks and reviews — teammates never report '
                    'straight to you as finished work.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, this.count);
  final String text;
  final int? count;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        Text(text, style: context.type.labelSmall),
        if (count != null) ...[
          const SizedBox(width: 6),
          Text('$count', style: context.type.labelSmall?.copyWith(color: c.muted)),
        ],
      ],
    );
  }
}

class _TrustLine extends StatelessWidget {
  const _TrustLine({required this.glyph, required this.color, required this.title, required this.body});
  final GlyphData glyph;
  final Color color;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Glyph(glyph, size: 17, color: color, duo: true),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: RichText(
            text: TextSpan(style: context.type.bodySmall, children: [
              TextSpan(text: '$title — ', style: context.type.bodySmall?.copyWith(
                  color: c.text, fontWeight: FontWeight.w600)),
              TextSpan(text: body, style: context.type.bodySmall?.copyWith(color: c.muted)),
            ]),
          ),
        ),
      ],
    );
  }
}

/// Compii itself at the top of its own team page.
class _CompiiBand extends StatelessWidget {
  const _CompiiBand({required this.bot, required this.core, required this.onTalk});
  final BotView bot;
  final CoreClient core;
  final VoidCallback onTalk;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final working = bot.working;
    final stats = bot.stats;
    final jobs = (stats['jobs'] as num?)?.toInt() ?? 0;
    final accepted = (stats['accepted'] as num?)?.toInt() ?? 0;
    final rejected = (stats['rejected'] as num?)?.toInt() ?? 0;
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      borderColor: c.accent.withValues(alpha: .28),
      child: Row(
        children: [
          BotAvatar(bot: bot, size: 46, ring: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: context.type.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
                    const SizedBox(width: 8),
                    Pill('Runs the team', color: c.accent, glyph: G.team),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  working.isEmpty
                      ? (jobs == 0
                          ? 'No jobs supervised yet. Ask for something and Compii decides whether to do it itself or hand it to a teammate.'
                          : '$jobs supervised · $accepted accepted · $rejected sent back.')
                      : 'Working on ${working.length} ${working.length == 1 ? 'thing' : 'things'} right now.',
                  style: context.type.bodySmall?.copyWith(color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onTalk,
            icon: const Glyph(G.chat, size: 15),
            label: const Text('Talk to Compii'),
          ),
        ],
      ),
    );
  }
}

/// One line in the directory when the window is wide enough to keep the teammate beside it.
/// The full card on the right carries the rest; this is only who is who and how they stand.
class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({required this.bot, required this.core, required this.selected, required this.onTap});
  final BotView bot;
  final CoreClient core;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = botColor(bot, c.accent);
    final (String state, Color tone) = bot.archived
        ? ('Away', c.faint)
        : bot.working.isNotEmpty
            ? ('Working', color)
            : bot.trust == 'trusted'
                ? ('Trusted', c.success)
                : ('Probation', c.warning);
    return Keyable(
      key: ValueKey('dir-${bot.id}'),
      onTap: onTap,
      selected: selected,
      radius: Shapes.r12,
      label: [
        bot.name,
        if (bot.archived) 'archived',
        if (bot.job.isNotEmpty) bot.job,
      ].join(', '),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: context.motion(Motion.quick),
            curve: Motion.standard,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: selected ? c.accentSoft : Colors.transparent,
              borderRadius: Shapes.r12,
              border: Border.all(color: selected ? c.accent.withValues(alpha: .35) : Colors.transparent),
            ),
            child: Row(
              children: [
                if (bot.archived)
                  Opacity(opacity: .5, child: BotAvatar(bot: bot, size: 30))
                else
                  BotAvatar(bot: bot, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: context.type.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600, color: bot.archived ? c.faint : null)),
                      const SizedBox(height: 1),
                      Text(bot.job.isNotEmpty ? bot.job : laneShort(core, bot), maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.labelMedium?.copyWith(color: c.faint)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(width: 6, height: 6, decoration: BoxDecoration(color: tone, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(state, style: context.type.labelSmall?.copyWith(color: tone)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The third pane on a wide window: the conversations this teammate actually has, read from
/// Core, so the directory can lead straight into one without leaving the page.
class _SelectedConversations extends StatefulWidget {
  const _SelectedConversations({
    super.key,
    required this.bot,
    required this.core,
    required this.onOpen,
    required this.onOpenLane,
  });
  final BotView bot;
  final CoreClient core;
  final void Function(String taskId) onOpen;
  final VoidCallback onOpenLane;

  @override
  State<_SelectedConversations> createState() => _SelectedConversationsState();
}

class _SelectedConversationsState extends State<_SelectedConversations> {
  List<TaskView>? _threads;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final threads = await widget.core.fetchConversations(widget.bot.id);
      if (!mounted) return;
      setState(() => _threads = threads);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _threads = const [];
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = botColor(widget.bot, c.accent);
    final threads = _threads;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('CONVERSATIONS', style: context.type.labelSmall),
            if (threads != null) ...[
              const SizedBox(width: 7),
              Text('${threads.length}', style: context.type.labelSmall?.copyWith(color: c.faint)),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.onOpenLane,
                  child: Text('Open ${widget.bot.name}’s lane',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (threads == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Reading ${widget.bot.name}’s conversations…',
                      maxLines: 2,
                      style: context.type.labelMedium?.copyWith(color: c.faint)),
                ),
              ],
            ),
          )
        else if (_error != null)
          Panel(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Expanded(
                  child: Text('This window could not read ${widget.bot.name}’s conversations. $_error',
                      style: context.type.bodySmall?.copyWith(color: c.warning)),
                ),
                TextButton(onPressed: _load, child: const Text('Try again')),
              ],
            ),
          )
        else if (threads.isEmpty)
          Panel(
            padding: const EdgeInsets.all(18),
            child: Text(
              'No conversations with ${widget.bot.name} yet. ${widget.bot.archived ? 'It is put away, so bring it back first.' : 'Ask for something from its lane and it stays here.'}',
              style: context.type.bodySmall?.copyWith(color: c.faint),
            ),
          )
        else
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, t) in threads.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: 14, endIndent: 14, color: c.border),
                  _ConversationRow(task: t, color: color, onTap: () => widget.onOpen(t.id)),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.task, required this.color, required this.onTap});
  final TaskView task;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final waiting = task.pendingApproval != null;
    final (String label, Color tone) = waiting
        ? ('Needs you', c.warning)
        : switch (task.status) {
            'running' => ('Working', c.accent),
            'failed' => ('Problem', c.danger),
            'stopped' => ('Stopped', c.faint),
            _ => ('Done', c.success),
          };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(width: 3, height: 26, decoration: BoxDecoration(color: waiting || task.active ? color : c.border, borderRadius: Shapes.pill)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(titleOf(task), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodyMedium),
            ),
            const SizedBox(width: 8),
            Text(label, style: context.type.labelMedium?.copyWith(color: tone, fontSize: 11.5)),
            const SizedBox(width: 8),
            Text(ago(task.last?['at'] as double? ?? 0), style: context.type.labelMedium?.copyWith(color: c.faint, fontSize: 11.5)),
            const SizedBox(width: 4),
            Glyph(G.chevronRight, size: 14, color: c.faint),
          ],
        ),
      ),
    );
  }
}

class _TeammateCard extends StatelessWidget {
  const _TeammateCard({
    required this.bot,
    required this.core,
    required this.state,
    required this.run,
    required this.onAssign,
    required this.onOpenThread,
    required this.onTrust,
    required this.onArchive,
    required this.onRestore,
  });
  final BotView bot;
  final CoreClient core;
  final AppState state;
  final Run run;
  final VoidCallback onAssign;
  final void Function(String taskId) onOpenThread;
  final void Function(bool trusted) onTrust;
  final VoidCallback onArchive;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = botColor(bot, c.accent);
    final stats = bot.stats;
    int n(String key) => (stats[key] as num?)?.toInt() ?? 0;
    final jobs = n('jobs');
    final accepted = n('accepted');
    final rejected = n('rejected');
    final reviewed = accepted + rejected;
    final success = (stats['success'] as num?)?.toInt();
    final last = '${stats['last_review'] ?? ''}'.trim();
    final working = bot.working;
    final thread = working.isEmpty ? '' : '${working.first['id'] ?? ''}';
    final canOpen = thread.isNotEmpty && core.tasks.containsKey(thread);
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BotAvatar(bot: bot, size: 38),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bot.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    if (bot.job.isNotEmpty)
                      Text(bot.job, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Glyph(modeGlyph(bot.mode), size: 13, color: c.faint),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${modeLabels[bot.mode] ?? 'Team player'} · ${laneNames(core, bot)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.labelMedium?.copyWith(color: c.faint),
                          ),
                        ),
                      ],
                    ),
                    // Only its own AI is worth a line here; thinking with Compii's is the default.
                    if (aiShort(bot).isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Glyph(G.memory, size: 12, color: bot.modelNote.isEmpty ? c.faint : c.warning),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              aiShort(bot),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.labelMedium
                                  ?.copyWith(color: bot.modelNote.isEmpty ? c.faint : c.warning),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              bot.archived
                  ? Pill('Archived', color: c.muted, glyph: G.box)
                  : Pill(
                      bot.trust == 'trusted' ? 'Trusted' : 'Probation',
                      color: bot.trust == 'trusted' ? c.success : c.warning,
                      glyph: bot.trust == 'trusted' ? G.shieldCheck : G.warning,
                    ),
            ],
          ),
          const SizedBox(height: 10),
          if (working.isNotEmpty)
            Row(
              children: [
                SizedBox.square(dimension: 9, child: CircularProgressIndicator(strokeWidth: 1.6, color: color)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text('Working on “${working.first['title'] ?? 'a job'}”', maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.labelMedium?.copyWith(color: color)),
                ),
                if (working.any((w) => w['status'] == 'waiting'))
                  Pill('Needs you', color: c.warning)
                else if (canOpen)
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => onOpenThread(thread),
                    child: const Text('Open'),
                  ),
              ],
            )
          else
            Row(
              children: [
                Glyph(bot.archived ? G.box : G.checkCircle, size: 14, color: c.faint),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    bot.archived
                        ? 'Put away — no new work reaches it until it comes back'
                        : 'Free — ready for a job',
                    maxLines: 2,
                    style: context.type.labelMedium?.copyWith(color: c.faint),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            reviewed == 0 && jobs == 0
                ? 'No jobs yet.'
                : '$jobs ${jobs == 1 ? 'job' : 'jobs'} · $accepted accepted · $rejected sent back'
                    '${success == null ? '' : ' · $success%'}',
            style: context.type.labelMedium?.copyWith(color: c.muted),
          ),
          if (last.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text('Last check: $last', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: context.type.labelMedium?.copyWith(color: c.faint)),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              if (bot.archived)
                TextButton.icon(
                  onPressed: onRestore,
                  icon: const Glyph(G.undo, size: 14),
                  label: const Text('Bring back'),
                )
              else
                TextButton.icon(
                  onPressed: onAssign,
                  icon: const Glyph(G.send, size: 14),
                  label: const Text('Give a job'),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'Start another like this',
                visualDensity: VisualDensity.compact,
                onPressed: () => showBotEditor(context, core: core, state: state, run: run, copy: bot),
                icon: const Glyph(G.copy, size: 16),
              ),
              IconButton(
                tooltip: 'Edit name, job and face',
                visualDensity: VisualDensity.compact,
                onPressed: () => showBotEditor(context, core: core, state: state, run: run, bot: bot),
                icon: const Glyph(G.edit, size: 16),
              ),
              if (!bot.archived) ...[
                IconButton(
                  tooltip: bot.trust == 'trusted' ? 'Back to probation' : 'Make trusted',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onTrust(bot.trust != 'trusted'),
                  icon: Glyph(
                    bot.trust == 'trusted' ? G.shieldCheck : G.shield,
                    size: 16,
                    color: bot.trust == 'trusted' ? c.success : c.muted,
                  ),
                ),
                IconButton(
                  tooltip: 'Archive ${bot.name} — its conversations stay',
                  visualDensity: VisualDensity.compact,
                  onPressed: onArchive,
                  icon: const Glyph(G.box, size: 16),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.core, required this.state});
  final Map<String, dynamic> job;
  final CoreClient core;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bot = core.botFor(job['bot_id'] as String?);
    final name = '${job['bot_name'] ?? bot?.name ?? 'Teammate'}';
    final status = '${job['status'] ?? ''}';
    final verdict = '${job['verdict'] ?? ''}';
    final note = '${job['review_note'] ?? ''}'.trim();
    final (String label, Color color) = status == 'running'
        ? ('Working', c.accent)
        : status == 'timeout'
            ? ('Out of time', c.warning)
            : status == 'failed'
                ? ('Failed', c.danger)
                : status == 'stopped'
                    ? ('Stopped', c.faint)
                    : verdict == 'accepted'
                        ? ('Accepted', c.success)
                        : verdict == 'rejected'
                            ? ('Sent back', c.warning)
                            : ('Not checked', c.muted);
    final child = '${job['child_task'] ?? ''}';
    final canOpen = child.isNotEmpty && core.tasks.containsKey(child);
    final started = (job['started'] as num?)?.toDouble() ?? 0;
    final actions = (job['actions'] as num?)?.toInt() ?? 0;
    final files = (job['files'] as List? ?? const []).length;
    final face = bot != null ? BotAvatar(bot: bot, size: 24) : const SizedBox.square(dimension: 24);
    return InkWell(
      onTap: canOpen ? () => state.open(child) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            face,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${job['objective'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    '$name · ${ago(started)} ago'
                    '${actions > 0 ? ' · $actions ${actions == 1 ? 'action' : 'actions'}' : ''}'
                    '${files > 0 ? ' · $files ${files == 1 ? 'file' : 'files'}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.labelMedium?.copyWith(color: c.faint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: note.isEmpty ? label : note,
              waitDuration: const Duration(milliseconds: 400),
              child: Pill(label, color: color),
            ),
            if (canOpen) ...[
              const SizedBox(width: 4),
              const Glyph(G.chevronRight, size: 15),
            ],
          ],
        ),
      ),
    );
  }
}

/// A hiring card the user hasn't answered yet, surfaced on the team page too.
class _ProposalRow extends StatefulWidget {
  const _ProposalRow({required this.proposal, required this.core, required this.onChanged});
  final Map<String, dynamic> proposal;
  final CoreClient core;
  final VoidCallback onChanged;

  @override
  State<_ProposalRow> createState() => _ProposalRowState();
}

class _ProposalRowState extends State<_ProposalRow> {
  bool _busy = false;
  String? _error;

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      widget.onChanged();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = widget.proposal;
    final name = '${p['name'] ?? ''}';
    final job = '${p['job'] ?? ''}';
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      borderColor: c.accent.withValues(alpha: .3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Compii suggests $name', style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (job.isNotEmpty)
                      Text(job, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                  ],
                ),
              ),
              TextButton(
                onPressed: _busy ? null : () => _act(() => widget.core.declineHire('${p['id']}')),
                child: const Text('Not now'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _act(() => widget.core.hireBot('${p['id']}', name: name, job: job)),
                child: const Text('Hire'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
          ],
        ],
      ),
    );
  }
}
