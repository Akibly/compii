import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/character.dart';
import '../console/core_client.dart';
import 'bots.dart';
import 'reader.dart';
import 'reply_text.dart';
import 'supervisor.dart';
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
  final List<Map<String, dynamic>> attachments = []; // files the user sent with this message
  final List<Map<String, dynamic>> steps = []; // action_done / action_started
  final List<String> notes = [];
  final List<Map<String, dynamic>> files = [];
  final List<Map<String, dynamic>> sources = []; // web pages Compii actually read for this answer
  final List<Map<String, dynamic>> approvals = [];
  // Decided approvals by id, and whether the user said yes: a declined action has to leave a
  // visible mark, not vanish as though it was never asked.
  final Map<String, bool> resolved = {};
  final List<Map<String, dynamic>> questions = [];
  final Set<String> answered = {};
  final List<Map<String, dynamic>> takeovers = []; // secret steps waiting for the user's own hands
  final Set<String> handedBack = {};
  final List<Map<String, dynamic>> handoffs = []; // turns passed between teammates
  final List<Map<String, dynamic>> delegations = []; // jobs Compii handed to a teammate
  final Map<String, Map<String, dynamic>> delegationDone = {}; // job id -> how it came back
  final Map<String, Map<String, dynamic>> reviews = {}; // job id -> Compii's verdict
  final Map<String, Map<String, dynamic>> resumes = {}; // job id -> the send-back that restarted it
  final List<Map<String, dynamic>> hirings = []; // new teammates Compii suggested
  final Map<String, Map<String, dynamic>> hiringResolved = {}; // proposal id -> hired/declined
  final List<Map<String, dynamic>> screens = []; // what Compii actually looked at
  final List<Map<String, dynamic>> safety = []; // blocked, injection, redacted, rule used
  // What Compii was given to answer this turn from: each piece says where it came from and
  // when it was read, so the list can be seen whole and one source struck off this chat.
  Map<String, dynamic>? context;
  List<Map<String, dynamic>>? plan;
  String? reply;
  String? draft; // words still being written, before the answer is finished
  String status = 'running';
  double? endedAt;

  /// Which teammate actually spoke this exchange. Core stamps the current speaker on
  /// every event, so a handoff mid-turn moves it: without this the thread would say
  /// Compii answered when a specialist did.
  String? botId;

  bool get active => status == 'running' || status == 'waiting';
  Map<String, dynamic>? get pending => active
      ? approvals.where((a) => !resolved.containsKey(a['approval_id'])).lastOrNull
      : null;
  Map<String, dynamic>? get pendingQuestion => active
      ? questions.where((q) => !answered.contains(q['question_id'])).lastOrNull
      : null;
  Map<String, dynamic>? get pendingTakeover => active
      ? takeovers.where((t) => !handedBack.contains(t['takeover_id'])).lastOrNull
      : null;
  Map<String, dynamic>? get current {
    final last = steps.lastOrNull;
    return last != null && last['type'] == 'action_started' ? last : null;
  }

  List<Map<String, dynamic>> get finished => steps.where((s) => s['type'] == 'action_done').toList();
}

/// The teammate a event was emitted by, if it names one.
String? _speakerOf(Map<String, dynamic> e) {
  final id = e['bot_id'];
  return id is String && id.isNotEmpty ? id : null;
}

/// Rebuilds the conversation from Core's event stream.
List<Turn> turnsOf(TaskView task) {
  final turns = <Turn>[];
  for (final e in task.events) {
    final at = (e['at'] as num?)?.toDouble() ?? 0;
    switch (e['type']) {
      case 'task_started':
        turns.add(Turn(task.request, at)..botId = _speakerOf(e) ?? task.botId);
        _filesOf(e, turns.last);
      case 'user_message' || 'retry':
        // A retry is Compii answering the same ask again, so the thread shows the ask
        // once more with a fresh answer under it — not a new request from the user.
        final asked = '${e['text'] ?? ''}'.trim();
        turns.add(Turn(asked.isEmpty ? task.request : asked, at)..botId = _speakerOf(e) ?? task.botId);
        _filesOf(e, turns.last);
      default:
        if (turns.isEmpty) turns.add(Turn(task.request, at)..botId = task.botId);
        final t = turns.last;
        t.botId = _speakerOf(e) ?? t.botId;
        switch (e['type']) {
          case 'answer_delta':
            final words = (e['text'] as String? ?? '').trim();
            t.draft = words.isEmpty ? null : words;
          case 'note':
            final note = '${e['text'] ?? ''}'.trim();
            if (note.isNotEmpty) t.notes.add(note);
            t.draft = null;
          case 'plan':
            final steps = e['steps'];
            t.plan = [
              if (steps is List)
                for (final s in steps)
                  if (s is Map) Map<String, dynamic>.from(s),
            ];
          case 'action_started':
            t.draft = null;
            if (e['tool'] != 'update_plan') t.steps.add(e);
          case 'action_done':
            if (e['tool'] == 'update_plan') break;
            if (t.steps.isNotEmpty && t.steps.last['type'] == 'action_started') t.steps.removeLast();
            t.steps.add(e);
          case 'file':
            t.files.add(e);
          case 'sources':
            for (final s in (e['items'] as List? ?? const [])) {
              if (s is Map) t.sources.add(Map<String, dynamic>.from(s));
            }
          case 'context':
            t.context = e;
          case 'action_blocked' || 'injection_warning' || 'redacted' || 'rule_used':
            t.safety.add(e);
          case 'approval_needed':
            t.draft = null;
            t.approvals.add(e);
          case 'approval_resolved':
            t.resolved['${e['approval_id'] ?? ''}'] = e['approved'] == true;
          case 'question':
            t.draft = null;
            t.questions.add(e);
          case 'question_answered':
            t.answered.add('${e['question_id'] ?? ''}');
          case 'takeover':
            t.draft = null;
            t.takeovers.add(e);
          case 'takeover_done':
            t.handedBack.add('${e['takeover_id'] ?? ''}');
          case 'handoff':
            t.handoffs.add(e);
          case 'delegation':
            t.delegations.add(e);
          case 'delegation_done':
            t.delegationDone['${e['job_id'] ?? e['child_task']}'] = e;
          case 'job_reviewed':
            t.reviews['${e['job_id']}'] = e;
          case 'delegation_resumed':
            final id = '${e['job_id']}';
            t.resumes[id] = e;
            t.delegationDone.remove(id);
            t.reviews.remove(id);
          case 'hiring':
            t.hirings.add(e);
          case 'hiring_resolved':
            t.hiringResolved['${e['proposal_id']}'] = e;
          case 'screen_seen':
            t.screens.add(e);
          case 'task_finished':
            t.draft = null;
            t.reply = e['text'] is String ? e['text'] as String : null;
            if (e['status'] is String) t.status = e['status'] as String;
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

void _filesOf(Map<String, dynamic> event, Turn turn) {
  for (final a in (event['attachments'] as List? ?? const [])) {
    if (a is Map) turn.attachments.add(Map<String, dynamic>.from(a));
  }
}

typedef Run = Future<void> Function(Future<void> Function() action);

/// The scrolling conversation.
class ThreadView extends StatelessWidget {
  const ThreadView({super.key, required this.task, required this.core, required this.run, this.compact = false,
    this.onOpenTask});
  final TaskView task;
  final CoreClient core;
  final Run run;
  final bool compact;

  /// Jump to another thread (a teammate's job from a delegation card).
  final void Function(String taskId)? onOpenTask;

  @override
  Widget build(BuildContext context) {
    final turns = turnsOf(task);
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 28, vertical: 20),
      itemCount: turns.length,
      itemBuilder: (context, i) {
        final turn = turns[turns.length - 1 - i];
        // Only the newest exchange can be answered again or edited: everything
        // before it is history that other answers already depend on.
        final last = i == 0 && !task.active;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _UserBubble(
                    text: turn.ask,
                    files: turn.attachments,
                    onResend: last
                        ? (text) => run(() => core.reply(task.id, text))
                        : null,
                  ),
                  const SizedBox(height: 14),
                  _AssistantTurn(turn: turn, task: task, core: core, run: run, compact: compact,
                      latest: last, onOpenTask: onOpenTask),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UserBubble extends StatefulWidget {
  const _UserBubble({required this.text, this.files = const [], this.onResend});
  final String text;
  final List<Map<String, dynamic>> files;

  /// Send these words into the conversation as a new message. Null on a turn the
  /// user can't edit (an older ask, or while Compii is still working).
  final void Function(String text)? onResend;

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  final _text = TextEditingController();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() {
    if (_editing) setState(() {});
  }

  @override
  void dispose() {
    _text.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  void _edit() {
    _text.text = widget.text;
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    setState(() => _editing = true);
  }

  void _send() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    setState(() => _editing = false);
    widget.onResend?.call(t);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final files = widget.files;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: c.userBubble,
                borderRadius: Shapes.r18.copyWith(bottomRight: const Radius.circular(6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_editing)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 28),
                          child: TextField(
                            key: const Key('edit-ask'),
                            controller: _text,
                            autofocus: true,
                            minLines: 1,
                            maxLines: 8,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            style: context.type.bodyLarge?.copyWith(color: c.onBubble),
                            cursorColor: c.accent,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Goes in as a new message.',
                                style: context.type.labelSmall?.copyWith(color: c.onBubble.withValues(alpha: .6))),
                            const SizedBox(width: 6),
                            TextButton(
                              onPressed: () => setState(() => _editing = false),
                              child: const Text('Cancel'),
                            ),
                            TextButton.icon(
                              key: const Key('resend-ask'),
                              onPressed: _text.text.trim().isEmpty ? null : _send,
                              icon: const Glyph(G.send, size: 15),
                              label: const Text('Send'),
                            ),
                          ],
                        ),
                      ],
                    )
                  else
                    SelectableText(widget.text, style: context.type.bodyLarge?.copyWith(color: c.onBubble)),
                  if (files.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        for (final f in files)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: c.onBubble.withValues(alpha: .08),
                              borderRadius: Shapes.r8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Glyph(G.file, size: 12, color: c.onBubble.withValues(alpha: .75)),
                                const SizedBox(width: 5),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 220),
                                  child: Text('${f['name'] ?? 'file'}', maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.type.labelSmall?.copyWith(color: c.onBubble)),
                                ),
                                if (f['size'] is num) ...[
                                  const SizedBox(width: 4),
                                  Text(_UserBubble._size((f['size'] as num).toInt()),
                                      style: context.type.labelSmall?.copyWith(color: c.onBubble.withValues(alpha: .6))),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (widget.onResend != null && !_editing)
              TextButton.icon(
                key: const Key('edit-ask-button'),
                onPressed: _edit,
                icon: const Glyph(G.edit, size: 14),
                label: const Text('Edit'),
              ),
          ],
        ),
      ),
    );
  }
}

/// A link in Compii's own words opens the way a source under the answer does:
/// through Core, so the same rules cover what the model cites and what it read.
OpenLink? _openLink(CoreClient core, Run run) => (url) => run(() => core.openUrl(url));

class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.turn, required this.task, required this.core, required this.run, required this.compact,
    required this.latest, this.onOpenTask});
  final Turn turn;
  final TaskView task;
  final CoreClient core;
  final Run run;
  final bool compact;

  /// The newest exchange: the one the user can have answered again.
  final bool latest;
  final void Function(String taskId)? onOpenTask;

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
    final speaker = core.botFor(turn.botId);
    // Compii keeps its own animated face; a teammate wears its own character, so
    // the conversation shows who actually answered.
    final specialist = speaker != null && !speaker.primary;
    final handedOver = specialist && turn.handoffs.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(
          dimension: 34,
          child: specialist
              ? BotAvatar(bot: speaker, size: 34, mood: _mood, animate: turn.active)
              : Ember(mood: _mood, jobs: turn.active ? 1 : 0, animate: turn.active),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (handedOver)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(speaker.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: context.type.labelMedium?.copyWith(color: botColor(speaker, c.accent))),
                      ),
                      const SizedBox(width: 6),
                      Text('took this over', style: context.type.labelMedium?.copyWith(color: c.faint)),
                    ],
                  ),
                ),
              if (turn.plan != null && compact) PlanList(steps: turn.plan!, dense: true),
              for (final s in turn.screens) _ScreenSeen(event: s),
              if (turn.steps.isNotEmpty || turn.active) StepLedger(turn: turn),
              for (final h in turn.handoffs)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: HandoffNote(event: h, core: core),
                ),
              for (final d in turn.delegations)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DelegationCard(
                    event: d,
                    done: turn.delegationDone['${d['job_id'] ?? d['child_task']}'],
                    review: turn.reviews['${d['job_id']}'],
                    attempt: (turn.resumes['${d['job_id']}']?['attempt'] as num?)?.toInt() ?? 1,
                    core: core,
                    run: run,
                    onOpen: onOpenTask,
                  ),
                ),
              for (final h in turn.hirings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: HiringCard(
                    event: h,
                    resolved: turn.hiringResolved['${(h['proposal'] as Map?)?['id']}'],
                    core: core,
                    live: turn.active,
                  ),
                ),
              if (turn.safety.isNotEmpty) SafetyNotes(events: turn.safety),
              if (pending != null) ...[
                const SizedBox(height: 10),
                ApprovalCard(approval: pending, core: core, run: run),
              ],
              // A no is an outcome too: the action is off, and the thread keeps that on screen
              // instead of leaving a gap where the card used to be.
              for (final a in turn.approvals)
                if (turn.resolved[a['approval_id']] == false)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _DeclinedNote(approval: a),
                  ),
              if (turn.pendingTakeover != null) ...[
                const SizedBox(height: 10),
                TakeoverCard(event: turn.pendingTakeover!, core: core, run: run),
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
                  onOpen: _openLink(core, run),
                ),
                if (turn.reply!.length > 900)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => showAnswerReader(
                        context,
                        text: turn.reply!,
                        title: specialist ? speaker.name : 'Compii’s answer',
                        subtitle: turn.ask.length > 90 ? '${turn.ask.substring(0, 90)}…' : turn.ask,
                        onOpen: _openLink(core, run),
                      ),
                      icon: const Glyph(G.doc, size: 15),
                      label: const Text('Read in reader'),
                    ),
                  ),
              ] else if (turn.active && turn.draft != null) ...[
                const SizedBox(height: 8),
                ReplyText(turn.draft!, style: context.type.bodyLarge, onOpen: _openLink(core, run)),
                const SizedBox(height: 6),
                SizedBox(width: 64, child: LinearProgressIndicator(minHeight: 2, color: c.accent)),
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
              if (!turn.active && turn.context != null) ...[
                const SizedBox(height: 10),
                ContextRow(turn: turn, task: task, core: core),
              ],
              if (latest && turn.reply != null) ...[
                const SizedBox(height: 4),
                TurnActions(turn: turn, task: task, core: core, run: run),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// What to do with an answer once it is on screen: take the words away, or have
/// Compii answer the same ask again. "Again" is a real second turn over the same
/// history — the earlier answer stays in the thread exactly as it was said.
class TurnActions extends StatefulWidget {
  const TurnActions({super.key, required this.turn, required this.task, required this.core, required this.run});
  final Turn turn;
  final TaskView task;
  final CoreClient core;
  final Run run;

  @override
  State<TurnActions> createState() => _TurnActionsState();
}

class _TurnActionsState extends State<TurnActions> {
  Timer? _returned;
  bool _copied = false;

  @override
  void dispose() {
    _returned?.cancel();
    super.dispose();
  }

  void _sayCopied() {
    setState(() => _copied = true);
    _returned?.cancel();
    _returned = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final words = widget.turn.reply ?? '';
    final again = switch (widget.turn.status) {
      'failed' || 'stopped' => 'Try again',
      _ => 'Again',
    };
    return Align(
      alignment: Alignment.centerLeft,
      // Wraps rather than clips: at large type or in a narrow island the two
      // actions sit on separate lines instead of losing one off the edge.
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton.icon(
            key: const Key('copy-answer'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: words));
              if (mounted) _sayCopied();
            },
            icon: Glyph(_copied ? G.check : G.copy, size: 15, color: _copied ? c.success : null),
            label: Text(_copied ? 'Copied' : 'Copy'),
          ),
          TextButton.icon(
            key: const Key('answer-again'),
            onPressed: () => widget.run(() => widget.core.answerAgain(widget.task.id)),
            icon: const Glyph(G.sync, size: 15),
            label: Text(again),
          ),
        ],
      ),
    );
  }
}

/// One quiet line: the window Compii actually looked at, and how much it could read.
class _ScreenSeen extends StatelessWidget {
  const _ScreenSeen({required this.event});
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final title = '${event['title'] ?? ''}'.trim();
    final ocr = (event['ocr'] as num?)?.toInt() ?? 0;
    final items = (event['items'] as num?)?.toInt() ?? 0;
    final read = ocr > 0 ? '$ocr ${ocr == 1 ? 'line' : 'lines'} read' : (items > 0 ? '$items items found' : '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Glyph(G.eye, size: 14, color: c.faint),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              'Looked at ${title.isEmpty ? 'your screen' : '“$title”'}${read.isEmpty ? '' : ' · $read'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.labelMedium?.copyWith(color: c.muted),
            ),
          ),
        ],
      ),
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
          borderRadius: Shapes.r10,
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
          duration: context.motion(Motion.base),
          curve: Motion.out,
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
                    borderRadius: Shapes.r14,
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
                if (detail.isNotEmpty &&
                    (!ok || const ['send_email', 'second_opinion'].contains(step['tool'])))
                  Tooltip(
                    message: detail,
                    waitDuration: const Duration(milliseconds: 350),
                    child: Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
                  ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: Shapes.pill),
      child: Text(kind, style: TextStyle(color: fg, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: .2)),
    );
  }
}

/// What the thread shows after the user said no. The card is gone, but the decision and its
/// consequence stay: nothing ran, and Compii was told not to try it again.
class _DeclinedNote extends StatelessWidget {
  const _DeclinedNote({required this.approval});
  final Map<String, dynamic> approval;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final label = '${approval['label'] ?? 'That action'}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: Shapes.r12,
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlyphTile(glyph: G.block, size: 26, color: c.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('You declined',
                    style: context.type.labelLarge?.copyWith(color: c.muted, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(label, style: context.type.bodySmall),
                const SizedBox(height: 3),
                Text('Nothing was done, and Compii was told not to retry it. If you still want it, say how to go ahead.',
                    style: context.type.bodySmall?.copyWith(color: c.faint)),
              ],
            ),
          ),
        ],
      ),
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
    final id = '${approval['approval_id'] ?? ''}';
    // Events arrive from JSON, and this card is the only way to answer one. A
    // missing field must not blank the thread, so both casts tolerate absence.
    final input = approval['input'] is Map
        ? Map<String, dynamic>.from(approval['input'] as Map)
        : const <String, dynamic>{};
    final destructive = kind == 'delete' || kind == 'spend';
    final fields = input.entries.where((e) => e.key != 'code' && e.key != 'content' && e.value != null).toList();
    final body = input['code'] ?? input['content'];

    final approve = FilledButton.icon(
      style: destructive ? FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: Colors.white) : null,
      onPressed: () => run(() => core.decide(id, approved: true)),
      icon: Glyph(destructive ? G.warning : G.check, size: 15),
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

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: destructive ? WrapAlignment.spaceBetween : WrapAlignment.start,
      children: destructive
          ? [decline, approve]
          : [approve, decline, ?always],
    );

    // A plain card with an amber edge: amber is "needs you" everywhere in the app. The kind of
    // action (send, change, delete, pay) is said in words and its own colour, not a gradient.
    final edge = destructive ? c.danger : c.warning;
    return Container(
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: Shapes.r10,
        border: Border.all(color: edge.withValues(alpha: destructive ? .7 : .45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: edge),
            Expanded(
              child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              children: [
                Glyph(
                  switch (kind) {
                    'send' => G.send,
                    'delete' => G.trash,
                    'spend' => G.money,
                    _ => G.edit,
                  },
                  size: 14,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_tierTitle(kind),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: context.type.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Text('Needs your okay', style: context.type.labelMedium?.copyWith(color: c.warning)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${approval['label']}', style: context.type.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                if (compact) ...[
                  const SizedBox(height: 10),
                  actions,
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                                    child: Text(_fieldName(f.key),
                                        maxLines: 2, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
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
                            decoration: BoxDecoration(color: c.sunken, borderRadius: Shapes.r8),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                '$body',
                                style: TextStyle(fontFamily: 'Cascadia Mono', fontFamilyFallback: const ['Consolas'], fontSize: 12.5, color: c.text),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 12),
                  actions,
                ],
              ],
            ),
          ),
        ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A password, card or one-time-code step. Compii fills what it safely can,
/// brings the window forward and waits — the secret is typed by the user, never
/// by Compii, and nothing they type passes through the app.
class TakeoverCard extends StatefulWidget {
  const TakeoverCard({super.key, required this.event, required this.core, required this.run});
  final Map<String, dynamic> event;
  final CoreClient core;
  final Run run;

  @override
  State<TakeoverCard> createState() => _TakeoverCardState();
}

class _TakeoverCardState extends State<TakeoverCard> {
  String? _outcome;

  void _finish(String outcome) {
    if (_outcome != null) return;
    setState(() => _outcome = outcome);
    widget.run(() => widget.core.finishTakeover('${widget.event['takeover_id']}', outcome: outcome));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fields = [for (final f in (widget.event['fields'] as List? ?? const [])) '${(f as Map)['label'] ?? f}'];
    final url = '${widget.event['url'] ?? ''}'.trim();
    final host = Uri.tryParse(url)?.host ?? '';
    final what = '${widget.event['what'] ?? 'This step needs your hands.'}';

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
                GlyphTile(glyph: G.lock, size: 30, color: c.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(what,
                        style: context.type.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
                  ),
                ),
                const SizedBox(width: 8),
                Pill('Your turn', color: c.accent, glyph: G.hand, soft: true),
              ],
            ),
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final label in fields)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: c.sunken,
                        borderRadius: Shapes.r10,
                        border: Border.all(color: c.border),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Glyph(G.lock, size: 13, color: c.muted),
                        const SizedBox(width: 6),
                        Text(label, style: context.type.labelMedium),
                      ]),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 9),
            Text(
              'Only you type this. Compii brings ${host.isEmpty ? 'the window' : host} forward and waits — '
              'it never sees or keeps what you enter.',
              style: context.type.bodySmall?.copyWith(color: c.muted),
            ),
            const SizedBox(height: 10),
            if (_outcome != null)
              Row(
                children: [
                  Glyph(G.checkCircle, size: 18, color: c.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _outcome == 'skip'
                          ? 'Skipped — Compii is carrying on without that step.'
                          : 'Handed back — Compii is carrying on.',
                      style: context.type.bodyMedium?.copyWith(color: c.muted),
                    ),
                  ),
                ],
              )
            else
              Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _finish('done'),
                    icon: const Glyph(G.checkCircle, size: 17),
                    label: const Text('I’ve done it — continue'),
                  ),
                  TextButton(
                    onPressed: () => _finish('skip'),
                    child: const Text('Skip this step'),
                  ),
                ],
              ),
          ],
        ),
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
                          borderRadius: Shapes.r12,
                          borderSide: BorderSide(color: c.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: Shapes.r12,
                          borderSide: BorderSide(color: c.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: Shapes.r12,
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
    return Keyable(
      label: widget.label,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ExcludeSemantics(
              child: AnimatedContainer(
                duration: context.motion(Motion.quick),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: _hover ? c.accentSoft : c.sunken,
                  borderRadius: Shapes.pill,
                  border: Border.all(color: _hover ? c.accent.withValues(alpha: .55) : c.border),
                ),
                child: Text(widget.label,
                    style: context.type.labelLarge?.copyWith(color: _hover ? c.accent : c.text, fontWeight: FontWeight.w500)),
              ),
            ),
          ),
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

/// What Compii attached to this answer, and what the user can do about any of it.
///
/// Every item says where it came from, when it was read and which permission made that
/// possible. Striking one off keeps it out of this conversation from then on — Core holds
/// the refusal, so it cannot come back on a later message.
class ContextRow extends StatelessWidget {
  const ContextRow({super.key, required this.turn, required this.task, required this.core});
  final Turn turn;
  final TaskView task;
  final CoreClient core;

  static List<Map<String, dynamic>> _maps(Object? v) =>
      [for (final m in (v as List? ?? const [])) Map<String, dynamic>.from(m as Map)];

  static String _ago(num at) {
    final s = DateTime.now().millisecondsSinceEpoch / 1000 - at;
    if (s < 60) return 'read just now';
    if (s < 3600) return 'read ${s ~/ 60} min ago';
    if (s < 86400) return 'read ${s ~/ 3600} h ago';
    return 'read ${s ~/ 86400} d ago';
  }

  static GlyphData _glyph(String kind) => switch (kind) {
        'instruction' => G.skill,
        'observation' => G.monitor,
        'memory' => G.memory,
        'claim' => G.team,
        _ => G.eye,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final gave = turn.context!;
    final items = _maps(gave['items']);
    final off = core.withheld[task.id] ?? {};
    final live = items.where((i) => !off.contains(i['id'])).length;
    final missed = _maps(gave['unavailable']);
    final aside = <String>[
      if (missed.isNotEmpty) '${missed.length} could not be read',
      if (((gave['trimmed'] as num?) ?? 0) > 0) '${gave['trimmed']} did not fit',
      if (((gave['expired'] as num?) ?? 0) > 0) '${gave['expired']} had gone stale',
      if (((gave['duplicated'] as num?) ?? 0) > 0) '${gave['duplicated']} were repeats',
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Compii used', style: context.type.labelMedium?.copyWith(color: c.muted)),
        ActionChip(
          avatar: Glyph(live == 0 ? G.eyeOff : G.eye, size: 14),
          label: Text(
            '${live == items.length ? '$live thing${live == 1 ? '' : 's'}' : '$live of ${items.length} thing${items.length == 1 ? '' : 's'}'}'
            ' it could see${aside.isEmpty ? '' : ' · ${aside.join(' · ')}'}',
            style: context.type.labelMedium,
          ),
          onPressed: () => _open(context),
        ),
      ],
    );
  }

  Future<void> _open(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) {
          final c = context.c;
          final gave = turn.context!;
          final items = _maps(gave['items']);
          final missed = _maps(gave['unavailable']);
          final refused = (gave['refused'] as List? ?? const []).length;
          return StatefulBuilder(
            builder: (context, set) => AlertDialog(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
              title: const Text('What Compii could see'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This is the whole list it was answered with. Strike one off and it stays out '
                        'of this chat.', style: context.type.bodySmall?.copyWith(color: c.muted)),
                    const SizedBox(height: 12),
                    for (final item in items)
                      _ContextLine(
                        item: item,
                        off: (core.withheld[task.id] ?? {}).contains(item['id']),
                        onToggle: () => set(() => core.withhold(task.id, '${item['id']}',
                            !(core.withheld[task.id] ?? {}).contains(item['id']))),
                      ),
                    for (final m in missed)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Glyph(G.warning, size: 15, color: c.warning),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text('Could not use ${m['source']}: ${m['why']}',
                                  style: context.type.bodySmall?.copyWith(color: c.warning)),
                            ),
                          ],
                        ),
                      ),
                    if (refused > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('$refused item(s) you struck off were left out of this answer.',
                            style: context.type.bodySmall?.copyWith(color: c.muted)),
                      ),
                  ],
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
            ),
          );
        },
      );
}

class _ContextLine extends StatelessWidget {
  const _ContextLine({required this.item, required this.off, required this.onToggle});
  final Map<String, dynamic> item;
  final bool off;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final scope = '${item['scope']}';
    final sensitive = '${item['sensitivity']}' != 'normal' ? ' · ${item['sensitivity']}' : '';
    final expiresIn = item['expires_in'];
    final age = expiresIn is num && expiresIn > 0
        ? 'true for ${expiresIn ~/ 60}s more'
        : ContextRow._ago(((item['at'] as num?) ?? 0).toDouble());
    final why = '${item['why']}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Glyph(ContextRow._glyph('${item['kind']}'), size: 15, color: off ? c.muted : c.accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${item['label']}',
                    style: context.type.bodyMedium
                        ?.copyWith(color: off ? c.muted : null, decoration: off ? TextDecoration.lineThrough : null)),
                Text('${item['source']} · ${item['kind']} · $age$sensitive'
                    '${scope.isEmpty ? '' : ' · allowed by $scope'}',
                    style: context.type.bodySmall?.copyWith(color: c.muted)),
                if (why.isNotEmpty && why != 'null')
                  Text(why, style: context.type.bodySmall?.copyWith(color: c.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: off ? 'Use this again in this chat' : 'Do not use this in this chat again',
            child: TextButton(
              onPressed: onToggle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Glyph(off ? G.eyeOff : G.eye, size: 14, color: off ? c.warning : c.muted),
                  const SizedBox(width: 5),
                  Text(off ? 'Left out' : 'Leave out', style: context.type.labelMedium),
                ],
              ),
            ),
          ),
        ],
      ),
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
        borderRadius: Shapes.r12,
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
        _ => Text('$number', style: context.type.labelSmall?.copyWith(color: c.faint, fontWeight: FontWeight.w600)),
      },
    );
  }
}
