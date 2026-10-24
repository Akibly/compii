import 'package:flutter/material.dart';

import '../console/character.dart' show Mood;
import '../console/core_client.dart';
import 'agent_character.dart';
import 'bots.dart';
import 'chrome.dart';
import 'glyphs.dart';
import 'thread.dart' show Run;
import 'tokens.dart';

/// A job Compii handed to a teammate: who has it, what "done" means, and how
/// it came back. The verdict line appears once Compii has checked the work.
class DelegationCard extends StatelessWidget {
  const DelegationCard({super.key, required this.event, this.done, this.review, this.attempt = 1,
      required this.core, required this.run, this.onOpen});
  final Map<String, dynamic> event;
  final Map<String, dynamic>? done;
  final Map<String, dynamic>? review;

  /// 1 the first time; 2+ after Compii sent it back and the teammate is fixing it.
  final int attempt;
  final CoreClient core;
  final Run run;
  final void Function(String taskId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bot = core.botFor(event['bot_id'] as String?);
    final name = '${event['bot_name'] ?? bot?.name ?? 'Teammate'}';
    final objective = '${event['objective'] ?? ''}'.trim();
    final doneWhen = '${event['done_when'] ?? ''}'.trim();
    final budget = (event['budget_min'] as num?)?.toInt() ?? 8;
    final status = '${done?['status'] ?? ''}';
    final running = done == null;
    final child = '${done?['child_task'] ?? event['child_task'] ?? ''}';
    final canOpen = onOpen != null && child.isNotEmpty && core.tasks.containsKey(child);
    final trusted = '${event['trust'] ?? 'probation'}' == 'trusted';
    final (Color color, GlyphData icon, String label) = switch (status) {
      'done' => (c.success, G.checkCircle, 'Reported done'),
      'timeout' => (c.warning, G.clock, 'Out of time'),
      'failed' => (c.danger, G.alert, 'Hit a problem'),
      'stopped' => (c.faint, G.stop, 'Stopped'),
      _ => (c.accent, G.sync, 'Working'),
    };
    final verdict = '${review?['verdict'] ?? ''}';
    final note = '${review?['note'] ?? ''}'.trim();
    final result = '${done?['result'] ?? ''}'.trim();
    final actions = (done?['actions'] as num?)?.toInt() ?? 0;
    final files = [for (final f in (done?['files'] as List? ?? const [])) '$f'];
    final look = AgentLook.forName(name);
    final mood = running
        ? Mood.acting
        : switch (status) { 'done' => Mood.happy, 'failed' || 'timeout' => Mood.problem, _ => Mood.idle };
    final face = bot != null
        ? BotAvatar(bot: bot, size: 28, mood: mood)
        : AgentFace(
            color: c.accent,
            shape: look.shape,
            seed: look.seed,
            size: 28,
            mood: mood,
          );
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderColor: (running ? c.accent : color).withValues(alpha: .3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              face,
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Assigned to $name', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text('${trusted ? 'Trusted teammate' : 'On probation'}${attempt > 1 ? ' · attempt $attempt' : ''}',
                        style: context.type.labelMedium?.copyWith(color: trusted ? c.success : c.warning)),
                  ],
                ),
              ),
              if (running)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: c.accent)),
                  const SizedBox(width: 6),
                  Text('Working', style: context.type.labelMedium?.copyWith(color: c.accent)),
                ])
              else
                Pill(label, color: color, glyph: icon),
            ],
          ),
          if (objective.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(objective, style: context.type.bodyMedium),
          ],
          if (doneWhen.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text('Done when: $doneWhen', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: context.type.bodySmall?.copyWith(color: c.muted)),
          ],
          if (running) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Glyph(G.clock, size: 13, color: c.faint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Compii is waiting on this — up to $budget min.',
                      style: context.type.labelMedium?.copyWith(color: c.faint)),
                ),
                if (canOpen)
                  TextButton.icon(
                    onPressed: () => onOpen!(child),
                    icon: const Glyph(G.eye, size: 14),
                    label: const Text('Watch'),
                  ),
                if (child.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: c.danger),
                    onPressed: () => run(() => core.stop(child)),
                    icon: const Glyph(G.stop, size: 14, duo: true),
                    label: const Text('Stop'),
                  ),
              ],
            ),
          ] else ...[
            if (result.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(result, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: context.type.bodySmall?.copyWith(color: c.muted)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Glyph(G.check, size: 13, color: c.faint),
                const SizedBox(width: 5),
                Text(
                    '$actions ${actions == 1 ? 'action' : 'actions'}'
                    '${files.isEmpty ? '' : ' · ${files.length} ${files.length == 1 ? 'file' : 'files'}'}',
                    style: context.type.labelMedium?.copyWith(color: c.faint)),
                const Spacer(),
                if (canOpen)
                  TextButton.icon(
                    onPressed: () => onOpen!(child),
                    icon: const Glyph(G.chevronRight, size: 14),
                    label: Text('$name’s thread'),
                  ),
              ],
            ),
            if (verdict.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Glyph(verdict == 'accepted' ? G.shieldCheck : G.undo, size: 14,
                        color: verdict == 'accepted' ? c.success : c.warning),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      verdict == 'accepted'
                          ? 'Compii checked it and accepted.'
                          : 'Compii sent it back${note.isEmpty ? '.' : ' — $note'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.labelMedium?.copyWith(
                          color: verdict == 'accepted' ? c.success : c.warning),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Compii suggests a new teammate: the user chooses the name and the job, or
/// says not now. New teammates start on probation.
class HiringCard extends StatefulWidget {
  const HiringCard({super.key, required this.event, this.resolved, required this.core, this.live = false});
  final Map<String, dynamic> event;
  final Map<String, dynamic>? resolved;
  final CoreClient core;

  /// The turn is still waiting on an answer. A card with no answer and no live
  /// turn is stale (Core was restarted, or the wait timed out).
  final bool live;

  @override
  State<HiringCard> createState() => _HiringCardState();
}

class _HiringCardState extends State<HiringCard> {
  late final Map<String, dynamic> _proposal =
      widget.event['proposal'] is Map ? Map<String, dynamic>.from(widget.event['proposal'] as Map) : {};
  late final _name = TextEditingController(text: '${_proposal['name'] ?? ''}');
  late final _job = TextEditingController(text: '${_proposal['job'] ?? ''}');
  bool _busy = false;
  String? _error;
  String? _hired;

  @override
  void dispose() {
    _name.dispose();
    _job.dispose();
    super.dispose();
  }

  String get _id => '${_proposal['id'] ?? ''}';

  Future<void> _hire() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give this teammate a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await widget.core.hireBot(_id,
          name: _name.text.trim(), job: _job.text.trim(), avatar: '${_proposal['avatar'] ?? ''}');
      if (mounted) setState(() => _hired = made?.name ?? _name.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.core.declineHire(_id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final resolved = widget.resolved;
    final hired = _hired ??
        (resolved?['status'] == 'hired'
            ? '${(resolved?['bot'] as Map?)?['name'] ?? _proposal['name'] ?? ''}'
            : null);
    final declined = resolved?['status'] == 'declined';
    final expired = resolved?['status'] == 'expired' ||
        (resolved == null && _hired == null && !widget.live);
    final why = '${_proposal['why'] ?? ''}'.trim();
    final first = '${_proposal['first_task'] ?? ''}'.trim();
    final proposalLook = AgentLook.parse('${_proposal['avatar'] ?? ''}',
        name: '${_proposal['name'] ?? ''}');
    final face = AgentFace(
      color: hexColor('${_proposal['color'] ?? ''}', c.accent),
      shape: proposalLook.shape,
      seed: proposalLook.seed,
      size: 38,
      ring: true,
      mood: hired != null ? Mood.happy : (declined || expired ? Mood.idle : Mood.waiting),
    );
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderColor: c.accent.withValues(alpha: .35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              face,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('A new teammate?', style: context.type.bodyMedium?.copyWith(
                        color: c.accent, fontWeight: FontWeight.w700)),
                    if (why.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(why, maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: context.type.bodySmall?.copyWith(color: c.muted)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (hired != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              Glyph(G.checkCircle, size: 16, color: c.success),
              const SizedBox(width: 8),
              Expanded(child: Text('$hired is on the team, on probation.',
                  style: context.type.bodySmall?.copyWith(color: c.success))),
            ]),
          ] else if (declined || expired) ...[
            const SizedBox(height: 10),
            Text(declined ? 'Not now — Compii will do this itself.' : 'This suggestion expired.',
                style: context.type.bodySmall?.copyWith(color: c.faint)),
          ] else ...[
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Name', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _job,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'What they do', isDense: true),
            ),
            if (first.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('First up: $first', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: context.type.bodySmall?.copyWith(color: c.muted)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _hire,
                  icon: Glyph(G.plus, size: 15, color: c.onAccent),
                  label: Text(_busy
                      ? 'Hiring…'
                      : 'Hire ${_name.text.trim().isEmpty ? 'them' : _name.text.trim()}'),
                ),
                TextButton(onPressed: _busy ? null : _decline, child: const Text('Not now')),
                Text('Starts on probation: changes ask, sends and deletes are off.',
                    style: context.type.labelMedium?.copyWith(color: c.faint)),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: context.type.bodySmall?.copyWith(color: c.danger)),
          ],
        ],
      ),
    );
  }
}
