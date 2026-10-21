import 'package:flutter/material.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'reply_text.dart';
import 'tokens.dart';
import 'trust.dart';
import 'chrome.dart';
import 'glyphs.dart';

/// One exchange in a conversation: what the user asked and everything Compii
/// did in response.
class Turn {
  Turn(this.ask, this.at);
  final String ask;
  final double at;
  final List<Map<String, dynamic>> steps = []; // action_done / action_started
  final List<String> notes = [];
  final List<Map<String, dynamic>> files = [];
  final List<Map<String, dynamic>> sources = []; // web pages Compii actually read for this answer
  final List<Map<String, dynamic>> approvals = [];
  final Set<String> resolved = {};
  final List<Map<String, dynamic>> questions = [];
  final Set<String> answered = {};
  final List<Map<String, dynamic>> safety = []; // blocked, injection, redacted, rule used
  List<Map<String, dynamic>>? plan;
  String? reply;
  String status = 'running';
  double? endedAt;

  bool get active => status == 'running' || status == 'waiting';
  Map<String, dynamic>? get pending => active
      ? approvals.where((a) => !resolved.contains(a['approval_id'])).lastOrNull
      : null;
  Map<String, dynamic>? get pendingQuestion => active
      ? questions.where((q) => !answered.contains(q['question_id'])).lastOrNull
      : null;
  Map<String, dynamic>? get current {
    final last = steps.lastOrNull;
    return last != null && last['type'] == 'action_started' ? last : null;
  }

  List<Map<String, dynamic>> get finished => steps.where((s) => s['type'] == 'action_done').toList();
}

/// Rebuilds the conversation from Core's event stream.
List<Turn> turnsOf(TaskView task) {
  final turns = <Turn>[];
  for (final e in task.events) {
    final at = (e['at'] as num?)?.toDouble() ?? 0;
    switch (e['type']) {
      case 'task_started':
        turns.add(Turn(task.request, at));
      case 'user_message':
        turns.add(Turn(e['text'] as String, at));
      default:
        if (turns.isEmpty) turns.add(Turn(task.request, at));
        final t = turns.last;
        switch (e['type']) {
          case 'note':
            t.notes.add(e['text'] as String);
          case 'plan':
            t.plan = [for (final s in e['steps'] as List) Map<String, dynamic>.from(s as Map)];
          case 'action_started':
            if (e['tool'] != 'update_plan') t.steps.add(e);
          case 'action_done':
            if (e['tool'] == 'update_plan') break;
            if (t.steps.isNotEmpty && t.steps.last['type'] == 'action_started') t.steps.removeLast();
            t.steps.add(e);
          case 'file':
            t.files.add(e);
          case 'sources':
            for (final s in (e['items'] as List? ?? const [])) {
              t.sources.add(Map<String, dynamic>.from(s as Map));
            }
          case 'action_blocked' || 'injection_warning' || 'redacted' || 'rule_used':
            t.safety.add(e);
          case 'approval_needed':
            t.approvals.add(e);
          case 'approval_resolved':
            t.resolved.add(e['approval_id'] as String);
          case 'question':
            t.questions.add(e);
          case 'question_answered':
            t.answered.add(e['question_id'] as String);
          case 'task_finished':
            t.reply = e['text'] as String?;
            t.status = e['status'] as String;
            t.endedAt = at;
        }
    }
  }
  // The last turn always reflects the conversation's real state, even if its
  // final event never arrived (for example after Core restarted).
  if (turns.isNotEmpty && (task.active || turns.last.status == 'running')) {
    turns.last.status = task.status;
  }
  return turns;
}

typedef Run = Future<void> Function(Future<void> Function() action);

/// The scrolling conversation.
class ThreadView extends StatelessWidget {
  const ThreadView({super.key, required this.task, required this.core, required this.run, this.compact = false});
  final TaskView task;
  final CoreClient core;
  final Run run;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final turns = turnsOf(task);
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 28, vertical: 20),
      itemCount: turns.length,
      itemBuilder: (context, i) {
        final turn = turns[turns.length - 1 - i];
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _UserBubble(text: turn.ask),
                  const SizedBox(height: 14),
                  _AssistantTurn(turn: turn, task: task, core: core, run: run, compact: compact),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: context.c.userBubble,
          borderRadius: BorderRadius.circular(18).copyWith(bottomRight: const Radius.circular(6)),
        ),
        child: SelectableText(text, style: context.type.bodyLarge?.copyWith(color: context.c.onBubble)),
      ),
    ),
  );
}

class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.turn, required this.task, required this.core, required this.run, required this.compact});
  final Turn turn;
  final TaskView task;
  final CoreClient core;
  final Run run;
  final bool compact;

  Mood get _mood => switch (turn.status) {
    'waiting' => Mood.waiting,
    'running' => turn.current != null ? Mood.acting : Mood.thinking,
    'done' => Mood.happy,
    'failed' => Mood.problem,
    _ => Mood.idle,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final pending = turn.pending;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(
          dimension: 34,
          child: Orbling(mood: _mood, jobs: turn.active ? 1 : 0, animate: turn.active),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (turn.plan != null && compact) PlanList(steps: turn.plan!, dense: true),
              if (turn.steps.isNotEmpty || turn.active) StepLedger(turn: turn),
              if (turn.safety.isNotEmpty) SafetyNotes(events: turn.safety),
              if (pending != null) ...[
                const SizedBox(height: 10),
                ApprovalCard(approval: pending, core: core, run: run),
              ],
              if (turn.pendingQuestion != null) ...[
                const SizedBox(height: 10),
                QuestionCard(question: turn.pendingQuestion!, core: core, run: run, compact: compact),
              ],
              if (turn.reply != null) ...[
                const SizedBox(height: 8),
                ReplyText(
                  turn.reply!,
                  style: context.type.bodyLarge?.copyWith(
                    color: turn.status == 'failed' ? c.danger : null,
                  ),
                ),
              ] else if (turn.active && turn.notes.isNotEmpty && pending == null) ...[
                const SizedBox(height: 8),
                Text(turn.notes.last, style: context.type.bodyMedium?.copyWith(color: c.muted)),
              ],
              if (!turn.active && (turn.files.isNotEmpty || turn.finished.isNotEmpty)) ...[
                const SizedBox(height: 12),
                ResultSummary(turn: turn, task: task, core: core, run: run),
              ],
              if (!turn.active && turn.sources.isNotEmpty) ...[
                const SizedBox(height: 10),
                SourcesRow(sources: turn.sources, core: core, run: run),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One quiet line while working ("Working · 3 steps"); expands into every step.
class StepLedger extends StatefulWidget {
  const StepLedger({super.key, required this.turn});
  final Turn turn;
  @override
  State<StepLedger> createState() => _StepLedgerState();
}

class _StepLedgerState extends State<StepLedger> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = widget.turn;
    final n = t.finished.length;
    final current = t.current;
    final failed = t.finished.where((s) => s['ok'] != true).length;
    final seconds = t.endedAt == null ? null : (t.endedAt! - t.at).round();
    final String headline;
    final waiting = t.pending != null || t.pendingQuestion != null;
    if (t.pending != null) {
      headline = 'Waiting for you · $n ${n == 1 ? 'step' : 'steps'} so far';
    } else if (t.pendingQuestion != null) {
      headline = 'Compii is asking you something · $n ${n == 1 ? 'step' : 'steps'} so far';
    } else if (t.active) {
      headline = current != null ? '${current['label']}…' : (n == 0 ? 'Thinking…' : 'Thinking · $n ${n == 1 ? 'step' : 'steps'} done');
    } else {
      headline = '${switch (t.status) {
        'stopped' => 'Stopped',
        'failed' => 'Stopped on a problem',
        _ => 'Worked',
      }}${seconds != null ? ' for ${_duration(seconds)}' : ''} · $n ${n == 1 ? 'step' : 'steps'}${failed > 0 ? ' · $failed failed' : ''}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: n == 0 ? null : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (t.active && !waiting)
                  SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent))
                else
                  Glyph(
                    waiting ? G.hand : (failed > 0 ? G.alert : G.checkCircle),
                    size: 16,
                    color: waiting ? c.warning : (failed > 0 ? c.danger : c.success),
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    headline,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodyMedium?.copyWith(color: c.muted, fontWeight: FontWeight.w500),
                  ),
                ),
                if (n > 0) Glyph(_open ? G.collapse : G.expand, size: 18, color: c.faint),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: c.raised,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [for (final s in t.finished) _StepRow(step: s)],
                  ),
                ),
        ),
      ],
    );
  }
}

String _duration(int s) => s < 60 ? '${s}s' : '${s ~/ 60}m ${s % 60}s';

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});
  final Map<String, dynamic> step;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ok = step['ok'] == true;
    final detail = '${step['detail'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Glyph(ok ? G.check : G.close, size: 15, color: ok ? c.success : c.danger),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${step['label']}', style: context.type.bodyMedium),
                if (detail.isNotEmpty && (!ok || step['tool'] == 'send_email'))
                  Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _KindBadge(kind: '${step['kind'] ?? ''}'),
        ],
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});
  final String kind;
  @override
  Widget build(BuildContext context) {
    if (kind.isEmpty || kind == 'read') return const SizedBox.shrink();
    final (fg, bg) = tierColors(context, kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(kind, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

/// Risk colours for approval tiers.
(Color, Color) tierColors(BuildContext context, String kind) {
  final c = context.c;
  return switch (kind) {
    'delete' || 'spend' => (c.danger, c.dangerSoft),
    'send' => (c.accent, c.accentSoft),
    'change' => (c.warning, c.warningSoft),
    _ => (c.muted, c.sunken),
  };
}

String _tierTitle(String kind) => switch (kind) {
  'send' => 'Send this?',
  'delete' => 'Delete this?',
  'spend' => 'Spend money?',
  'change' => 'Make this change?',
  _ => 'Go ahead?',
};

String _tierWhy(String kind) => switch (kind) {
  'send' => 'This leaves your computer and goes to someone else.',
  'delete' => 'This removes something. It may not be possible to undo.',
  'spend' => 'This costs money.',
  'change' => 'This changes things on your computer. Compii keeps a record so you can undo it.',
  _ => '',
};

/// Approval, styled by risk tier. Destructive tiers get a different layout so
/// they are never clicked through out of habit.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({super.key, required this.approval, required this.core, required this.run, this.compact = false});
  final Map<String, dynamic> approval;
  final CoreClient core;
  final Run run;

  /// Small screens: decision buttons right under the title, details after.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final kind = '${approval['kind']}';
    final (fg, bg) = tierColors(context, kind);
    final id = approval['approval_id'] as String;
    final input = Map<String, dynamic>.from(approval['input'] as Map);
    final destructive = kind == 'delete' || kind == 'spend';
    final fields = input.entries.where((e) => e.key != 'code' && e.key != 'content' && e.value != null).toList();
    final body = input['code'] ?? input['content'];

    final approve = FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: destructive ? c.danger : c.accent),
      onPressed: () => run(() => core.decide(id, approved: true)),
      icon: Glyph(destructive ? G.warning : G.check, size: 18),
      label: Text(destructive ? 'Yes, ${kind == 'spend' ? 'pay' : 'delete'}' : 'Approve'),
    );
    final decline = OutlinedButton(
      onPressed: () => run(() => core.decide(id, approved: false)),
      child: const Text('Decline'),
    );
    // Grok-style "Always allow": saved as a rule for this tool on this folder,
    // site, window or recipients. Never offered for payments.
    final always = approval['can_always'] == true
        ? TextButton(
            onPressed: () => run(() => TrustApi.alwaysAllow(id)),
            child: const Text('Always allow'),
          )
        : null;
    final why = '${approval['why'] ?? ''}';

    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: Shapes.r16,
        border: Border.all(color: fg.withValues(alpha: destructive ? .7 : .4), width: destructive ? 1.8 : 1.2),
        boxShadow: [
          ...Shapes.float(c),
          BoxShadow(color: fg.withValues(alpha: .10), blurRadius: 0, spreadRadius: 4),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [bg, bg.withValues(alpha: 0)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                GlyphTile(
                  glyph: switch (kind) {
                    'send' => G.send,
                    'delete' => G.trash,
                    'spend' => G.money,
                    _ => G.edit,
                  },
                  size: 30,
                  color: fg,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_tierTitle(kind),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.titleMedium?.copyWith(color: fg)),
                ),
                const SizedBox(width: 8),
                Pill('Needs your okay', color: c.warning, glyph: G.hand),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${approval['label']}', style: context.type.titleMedium),
                if (compact) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: destructive
                        ? [decline, const Spacer(), approve]
                        : [approve, const SizedBox(width: 8), decline, if (always != null) ...[const Spacer(), always]],
                  ),
                ],
                if (why.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(why, style: context.type.bodySmall?.copyWith(color: c.danger)),
                ],
                if (_tierWhy(kind).isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_tierWhy(kind), style: context.type.bodySmall),
                ],
                if (fields.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final f in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 96,
                            child: Text(_fieldName(f.key), style: context.type.bodySmall),
                          ),
                          Expanded(child: _FieldValue(name: f.key, value: f.value)),
                        ],
                      ),
                    ),
                ],
                if (body != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: c.sunken, borderRadius: BorderRadius.circular(8)),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '$body',
                        style: TextStyle(fontFamily: 'Cascadia Mono', fontFamilyFallback: const ['Consolas'], fontSize: 12.5, color: c.text),
                      ),
                    ),
                  ),
                ],
                if (!compact) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: destructive
                        ? [decline, const Spacer(), approve]
                        : [approve, const SizedBox(width: 8), decline, if (always != null) ...[const Spacer(), always]],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compii's question, answered where it was asked: tap a choice, or type it in
/// the box — the box is there for the answers no choice can hold.
class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.question, required this.core, required this.run, this.compact = false});
  final Map<String, dynamic> question;
  final CoreClient core;
  final Run run;
  final bool compact;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final TextEditingController _typed = TextEditingController();
  String? _sent;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _answer(String value) {
    final text = value.trim();
    if (text.isEmpty || _sent != null) return;
    _typed.clear();
    setState(() => _sent = text);
    final id = '${widget.question['question_id']}';
    widget.run(() => widget.core.answerQuestion(id, text));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final choices = [for (final v in (widget.question['choices'] as List? ?? const [])) '$v'];
    final asked = '${widget.question['question']}';

    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: Shapes.r16,
        border: Border.all(color: c.accent.withValues(alpha: .5), width: 1.2),
        boxShadow: [
          ...Shapes.float(c),
          BoxShadow(color: c.accent.withValues(alpha: .08), blurRadius: 0, spreadRadius: 4),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GlyphTile(glyph: G.chat, size: 30, color: c.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(asked, style: context.type.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
                  ),
                ),
                const SizedBox(width: 8),
                Pill('Your turn', color: c.accent, glyph: G.hand, soft: true),
              ],
            ),
            const SizedBox(height: 12),
            if (_sent != null)
              Row(
                children: [
                  Glyph(G.checkCircle, size: 18, color: c.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('“$_sent” — Compii is carrying on.',
                        style: context.type.bodyMedium?.copyWith(color: c.muted)),
                  ),
                ],
              )
            else ...[
              if (choices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [for (final choice in choices) _AnswerChip(label: choice, onTap: () => _answer(choice))],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _typed,
                      minLines: 1,
                      maxLines: 5,
                      autofocus: !widget.compact,
                      textInputAction: TextInputAction.newline,
                      onSubmitted: _answer,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: c.sunken,
                        hintText: choices.isEmpty ? 'Type your answer' : 'Or type your own answer',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.accent, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _answer(_typed.text),
                    icon: const Glyph(G.send, size: 17),
                    label: const Text('Send'),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _answer('I’d rather you decide — use your best judgement and tell me what you chose.'),
                  child: const Text('Compii, you decide'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One tappable answer.
class _AnswerChip extends StatefulWidget {
  const _AnswerChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_AnswerChip> createState() => _AnswerChipState();
}

class _AnswerChipState extends State<_AnswerChip> {
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: _hover ? c.accentSoft : c.sunken,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: _hover ? c.accent.withValues(alpha: .55) : c.border),
          ),
          child: Text(widget.label,
              style: context.type.labelLarge?.copyWith(color: _hover ? c.accent : c.text, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

/// Paths show the file name first and the full location smaller underneath.
class _FieldValue extends StatelessWidget {
  const _FieldValue({required this.name, required this.value});
  final String name;
  final Object? value;

  static const _pathFields = {'attachments', 'path', 'source', 'destination', 'folder'};

  @override
  Widget build(BuildContext context) {
    final values = value is List ? [for (final v in value as List) '$v'] : ['$value'];
    if (!_pathFields.contains(name)) {
      return SelectableText(values.join(', '), style: context.type.bodyMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final v in values) ...[
          Text(v.split(RegExp(r'[\\/]')).last, style: context.type.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          SelectableText(v, style: context.type.bodySmall),
        ],
      ],
    );
  }
}

String _fieldName(String key) => switch (key) {
  'to' => 'To',
  'subject' => 'Subject',
  'body' => 'Message',
  'attachments' => 'Attachments',
  'path' => 'File',
  'source' => 'From',
  'destination' => 'To',
  'target' => 'Target',
  _ => key[0].toUpperCase() + key.substring(1).replaceAll('_', ' '),
};

/// Leads the result with what changed, then the files to open.
class ResultSummary extends StatelessWidget {
  const ResultSummary({super.key, required this.turn, required this.task, required this.core, required this.run});
  final Turn turn;
  final TaskView task;
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final counts = <String, int>{};
    for (final f in turn.files) {
      final key = '${f['action']}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final undoable = turn.finished.any((s) => s['undoable'] == true);
    final changes = [
      for (final e in counts.entries) '${e.value} ${e.value == 1 ? 'file' : 'files'} ${e.key}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (changes.isNotEmpty)
          Text(changes.join(' · '), style: context.type.labelMedium),
        if (turn.files.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final f in turn.files) FileChip(file: f, core: core, run: run)],
          ),
        ],
        if (undoable) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.muted, padding: const EdgeInsets.symmetric(horizontal: 6)),
            onPressed: () => run(() async {
              final result = await core.undo(task.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
              }
            }),
            icon: const Glyph(G.undo, size: 16),
            label: const Text('Undo last change'),
          ),
        ],
      ],
    );
  }
}

/// The pages Compii actually read for this answer, so you can check them yourself.
class SourcesRow extends StatelessWidget {
  const SourcesRow({super.key, required this.sources, required this.core, required this.run});
  final List<Map<String, dynamic>> sources;
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final seen = <String>{};
    final unique = [for (final s in sources) if (seen.add('${s['url']}')) s];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Sources', style: context.type.labelMedium?.copyWith(color: c.muted)),
        for (final s in unique)
          Tooltip(
            message: '${s['url']}',
            child: ActionChip(
              avatar: const Glyph(G.globe, size: 14),
              label: Text(Uri.tryParse('${s['url']}')?.host.replaceFirst('www.', '') ?? '${s['title']}',
                  style: context.type.labelMedium),
              onPressed: () => run(() => core.openUrl('${s['url']}')),
            ),
          ),
      ],
    );
  }
}

class FileChip extends StatelessWidget {
  const FileChip({super.key, required this.file, required this.core, required this.run});
  final Map<String, dynamic> file;
  final CoreClient core;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final path = '${file['path']}';
    final name = path.split(RegExp(r'[\\/]')).last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final gone = '${file['action']}' == 'deleted';
    final icon = switch (ext) {
      'xlsx' || 'xls' || 'csv' => G.sheet,
      'pdf' => G.doc,
      'eml' => G.mail,
      'png' || 'jpg' || 'jpeg' => G.image,
      '' => G.folder,
      _ => G.doc,
    };
    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Glyph(gone ? G.trash : icon, size: 20, color: gone ? c.muted : c.accent),
          const SizedBox(width: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.titleSmall),
                  Text(gone ? 'in the Recycle Bin' : '${file['action']}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.labelMedium?.copyWith(color: gone ? c.muted : null)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // A recycled file is gone from its folder: offering to open it would only fail.
          if (!gone) ...[
            IconButton(
              tooltip: 'Open',
              visualDensity: VisualDensity.compact,
              onPressed: () => run(() => core.openFile(path)),
              icon: const Glyph(G.external, size: 17),
            ),
            IconButton(
              tooltip: 'Show in folder',
              visualDensity: VisualDensity.compact,
              onPressed: () => run(() => core.revealFile(path)),
              icon: const Glyph(G.folder, size: 17),
            ),
          ],
        ],
      ),
    );
  }
}

/// The checklist Compii shows before and during multi-step work.
class PlanList extends StatelessWidget {
  const PlanList({super.key, required this.steps, this.dense = false});
  final List<Map<String, dynamic>> steps;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, s) in steps.indexed)
          Padding(
            padding: EdgeInsets.symmetric(vertical: dense ? 3 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PlanMark(status: '${s['status']}', number: i + 1),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${s['title']}',
                    style: context.type.bodyMedium?.copyWith(
                      color: s['status'] == 'done' || s['status'] == 'skipped' ? c.muted : c.text,
                      fontWeight: s['status'] == 'active' ? FontWeight.w600 : FontWeight.w400,
                      decoration: s['status'] == 'skipped' ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PlanMark extends StatelessWidget {
  const _PlanMark({required this.status, required this.number});
  final String status;
  final int number;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: switch (status) {
          'done' => c.success.withValues(alpha: c.dark ? .2 : .14),
          'active' => c.accent.withValues(alpha: c.dark ? .25 : .14),
          _ => Colors.transparent,
        },
        border: Border.all(
          color: switch (status) {
            'done' => c.success.withValues(alpha: .5),
            'active' => c.accent,
            _ => c.borderStrong,
          },
          width: 1.5,
        ),
      ),
      child: switch (status) {
        'done' => Glyph(G.check, size: 12, color: c.success, weight: 2.4),
        'active' => Container(width: 8, height: 8, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)),
        _ => Text('$number', style: TextStyle(fontSize: 11, color: c.faint, fontWeight: FontWeight.w600)),
      },
    );
  }
}
