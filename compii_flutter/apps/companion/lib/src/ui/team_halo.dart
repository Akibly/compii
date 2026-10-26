import 'package:flutter/material.dart';

import '../console/character.dart' show Mood;
import '../console/core_client.dart';
import 'agent_character.dart';
import 'bots.dart';
import 'glyphs.dart';
import 'shell.dart';
import 'thread.dart' show Run;
import 'tokens.dart';

/// The team, as people you can talk to: every teammate is its glass character in
/// its own colour and shape, with its job, what it is doing right now — read
/// from Core's live tasks, never guessed — and exactly which tools it may use.
/// A click opens its own conversation; Compii itself is first.
class TeamHaloPage extends StatefulWidget {
  const TeamHaloPage({super.key, required this.core, required this.state, required this.run});
  final CoreClient core;
  final AppState state;
  final Run run;

  @override
  State<TeamHaloPage> createState() => _TeamHaloPageState();
}

class _TeamHaloPageState extends State<TeamHaloPage> {
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || widget.core.status != CoreStatus.online) return;
    try {
      await widget.core.fetchTeam();
      if (mounted) setState(() => _problem = null);
    } on Object catch (e) {
      if (mounted) setState(() => _problem = 'Compii couldn’t refresh the team: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final core = widget.core;
    return ListenableBuilder(
      listenable: core,
      builder: (context, _) {
        final bots = [
          for (final b in core.bots)
            if (!b.archived) b,
        ]..sort((a, b) => a.primary == b.primary ? a.name.compareTo(b.name) : (a.primary ? -1 : 1));
        final working = bots.where((b) => _now(core, b) != null).length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(40, 32, 40, 40),
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 16,
              spacing: 16,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Team', style: context.type.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      working == 0
                          ? 'Talk to any of them directly, or ask Compii and it brings in whoever fits.'
                          : '$working working now. Talk to any of them directly, or ask Compii.',
                      style: context.type.bodyMedium?.copyWith(color: c.muted),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: () => showBotEditor(context, core: core, state: widget.state, run: widget.run),
                  icon: const Glyph(G.plus, size: 16),
                  label: const Text('New teammate'),
                ),
              ],
            ),
            if (_problem != null) ...[
              const SizedBox(height: 14),
              Text(_problem!, style: context.type.bodySmall?.copyWith(color: c.warning)),
            ],
            const SizedBox(height: 24),
            if (bots.isEmpty)
              Text(
                core.status == CoreStatus.online
                    ? 'No teammates yet. Add one, or ask Compii to suggest who you need.'
                    : 'The team appears once Compii is running.',
                style: context.type.bodyMedium?.copyWith(color: c.faint),
              )
            else
              LayoutBuilder(
                builder: (context, box) {
                  final cols = (box.maxWidth / 320).floor().clamp(1, 4);
                  final w = (box.maxWidth - 14 * (cols - 1)) / cols;
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final b in bots)
                        SizedBox(
                          width: w,
                          child: _MemberCard(
                            core: core,
                            bot: b,
                            now: _now(core, b),
                            onOpen: () => widget.state.pickBot(b.primary ? null : b.id),
                            onEdit: () => showBotEditor(context, core: core, state: widget.state, run: widget.run, bot: b),
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        );
      },
    );
  }

  /// What this teammate is doing right now, from Core's own tasks.
  static TaskView? _now(CoreClient core, BotView b) {
    for (final t in core.ordered) {
      if (t.active && (t.botId == b.id || (b.primary && t.botId == null))) return t;
    }
    return null;
  }
}

class _MemberCard extends StatefulWidget {
  const _MemberCard({required this.core, required this.bot, required this.now, required this.onOpen, required this.onEdit});
  final CoreClient core;
  final BotView bot;
  final TaskView? now;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  State<_MemberCard> createState() => _MemberCardState();
}

class _MemberCardState extends State<_MemberCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final b = widget.bot;
    final color = botColor(b, c.accent);
    final mood = botMood(widget.core, b);
    final now = widget.now;
    final needs = now?.pendingApproval != null || now?.pendingQuestion != null;
    final (status, tone) = switch ((now, mood)) {
      (final TaskView t, _) when needs => ('Needs you · ${_short(t.request)}', c.warning),
      (final TaskView t, _) => ('Working · ${_short(t.request)}', c.success),
      (_, Mood.problem) => ('Last job didn’t finish', c.danger),
      (_, Mood.happy) => ('Ready · last job done', c.muted),
      _ => ('Ready', c.faint),
    };
    final look = botLook(b);
    final lanes = laneShort(widget.core, b);
    return Semantics(
      button: true,
      label: '${b.name}. ${b.job}. $status',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: context.motion(140),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _hover ? c.hover : c.raised,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: needs
                    ? c.warning.withValues(alpha: .45)
                    : (now != null ? c.success.withValues(alpha: .35) : c.border),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: AgentFace(
                        color: color,
                        shape: look.shape,
                        seed: look.seed,
                        size: 56,
                        mood: needs ? Mood.waiting : mood,
                        animate: now != null || _hover,
                        backgroundDisc: false,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (b.job.isNotEmpty)
                            Text(
                              b.job,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.bodySmall?.copyWith(color: c.muted),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit ${b.name}',
                      onPressed: widget.onEdit,
                      icon: Glyph(G.edit, size: 16, color: c.faint),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.labelMedium?.copyWith(color: tone),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Chip(lanes),
                    if (b.trust == 'probation') const _Chip('On probation'),
                    if (b.provider.isNotEmpty) _Chip(b.answersWith.isEmpty ? b.provider : b.answersWith),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 48 ? '${one.substring(0, 47)}…' : one;
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: c.sunken, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: context.type.labelSmall?.copyWith(color: c.muted)),
    );
  }
}
