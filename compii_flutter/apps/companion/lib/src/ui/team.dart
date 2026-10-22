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
    final teammates = widget.core.bots.where((b) => !b.primary).toList();
    final jobs = widget.core.teamJobs.take(14).toList();
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
        _Heading('TEAMMATES', teammates.length),
        const SizedBox(height: 8),
        if (teammates.isEmpty)
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

class _TeammateCard extends StatelessWidget {
  const _TeammateCard({
    required this.bot,
    required this.core,
    required this.state,
    required this.run,
    required this.onAssign,
    required this.onOpenThread,
    required this.onTrust,
  });
  final BotView bot;
  final CoreClient core;
  final AppState state;
  final Run run;
  final VoidCallback onAssign;
  final void Function(String taskId) onOpenThread;
  final void Function(bool trusted) onTrust;

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
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Pill(
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
                Glyph(G.checkCircle, size: 14, color: c.faint),
                const SizedBox(width: 7),
                Text('Free — ready for a job', style: context.type.labelMedium?.copyWith(color: c.faint)),
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
              TextButton.icon(
                onPressed: onAssign,
                icon: const Glyph(G.send, size: 14),
                label: const Text('Give a job'),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Edit name, job and face',
                visualDensity: VisualDensity.compact,
                onPressed: () => showBotEditor(context, core: core, state: state, run: run, bot: bot),
                icon: const Glyph(G.edit, size: 16),
              ),
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
