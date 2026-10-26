import 'package:flutter/material.dart';

import '../console/character.dart' show Mood, compiiColor;
import '../console/core_client.dart';
import '../overlay/halo_cursor.dart' show CardEyes;
import 'tokens.dart';

/// The receipt for one turn of work, counted from Core's own events — never
/// from what the model said it did. It is what the outcome-first answer leads
/// with: how it ended, how long it took, and what was actually touched.
class Outcome {
  const Outcome({
    required this.status,
    required this.seconds,
    required this.steps,
    required this.failedSteps,
    required this.facts,
  });

  /// done, failed, stopped or timeout.
  final String status;
  final double? seconds;
  final int steps;
  final int failedSteps;

  /// Plain counts, in the order they matter: what changed before what was read.
  final List<String> facts;

  /// The latest turn of [task], or null while it is still running or when it
  /// did nothing worth a receipt (a plain chat answer).
  static Outcome? of(TaskView task) {
    if (task.active) return null;
    final events = task.events;
    var start = 0;
    for (var i = events.length - 1; i >= 0; i--) {
      final t = events[i]['type'];
      if (t == 'user_message' || t == 'task_started') {
        start = i;
        break;
      }
    }
    final turn = events.sublist(start);
    var steps = 0, failed = 0, undoable = 0, declined = 0, delegated = 0, pages = 0;
    final files = <String, int>{};
    double? first, last;
    for (final e in turn) {
      final at = (e['at'] as num?)?.toDouble();
      if (at != null) {
        first ??= at;
        last = at;
      }
      switch (e['type']) {
        case 'action_done':
          if (e['tool'] == 'update_plan') break;
          steps++;
          if (e['ok'] == false) failed++;
          if (e['undoable'] == true) undoable++;
        case 'file':
          final a = '${e['action'] ?? 'changed'}';
          files[a] = (files[a] ?? 0) + 1;
        case 'sources':
          pages += (e['items'] as List? ?? const []).length;
        case 'approval_resolved' when e['approved'] == false:
          declined++;
        case 'delegation':
          delegated++;
      }
    }
    if (steps == 0 && files.isEmpty && delegated == 0) {
      // A plain answer: the words are the outcome, no receipt needed — unless
      // it failed, which is always said.
      if (task.status == 'done') return null;
    }
    String n(int k, String one, String many) => '$k ${k == 1 ? one : many}';
    final facts = <String>[
      for (final a in const ['created', 'modified', 'moved', 'deleted', 'changed'])
        if (files[a] != null) '${a[0].toUpperCase()}${a.substring(1)} ${n(files[a]!, 'file', 'files')}',
      if (delegated > 0) 'handed ${n(delegated, 'job', 'jobs')} to teammates',
      if (pages > 0) 'read ${n(pages, 'web page', 'web pages')}',
      if (declined > 0) '${n(declined, 'action', 'actions')} you said no to',
      if (failed > 0) '${n(failed, 'step', 'steps')} failed',
      if (undoable > 0) '${n(undoable, 'change', 'changes')} can be undone',
    ];
    return Outcome(
      status: task.status,
      seconds: first != null && last != null && last > first ? last - first : null,
      steps: steps,
      failedSteps: failed,
      facts: facts,
    );
  }

  String get headline {
    final how = switch (status) {
      'done' => failedSteps == 0 ? 'Done' : 'Done, with problems',
      'stopped' => 'Stopped',
      'timeout' => 'Ran out of time',
      _ => 'Didn’t finish',
    };
    final bits = [
      how,
      if (seconds != null) _duration(seconds!),
      if (steps > 0) '$steps ${steps == 1 ? 'step' : 'steps'}',
    ];
    return bits.join(' · ');
  }

  static String _duration(double s) {
    if (s < 60) return '${s.round()} s';
    final m = s ~/ 60, r = (s % 60).round();
    return r == 0 ? '$m min' : '$m min $r s';
  }
}

/// The top of a finished assistant turn: the eyes in how it went, the receipt
/// headline, and the facts under it. Renders nothing for a plain chat answer.
class OutcomeHeader extends StatelessWidget {
  const OutcomeHeader({super.key, required this.task, required this.core});
  final TaskView task;
  final CoreClient core;

  @override
  Widget build(BuildContext context) {
    final o = Outcome.of(task);
    if (o == null) return const SizedBox.shrink();
    final c = context.c;
    final good = o.status == 'done' && o.failedSteps == 0;
    final tone = good ? c.success : (o.status == 'stopped' ? c.muted : c.warning);
    return Semantics(
      container: true,
      label: [o.headline, ...o.facts].join('. '),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: ListenableBuilder(
                  listenable: compiiColor,
                  builder: (context, _) => CardEyes(
                    mood: good ? Mood.happy : (o.status == 'stopped' ? Mood.idle : Mood.problem),
                    color: compiiColor.value,
                    size: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      o.headline,
                      style: context.type.labelLarge?.copyWith(color: tone, fontWeight: FontWeight.w600),
                    ),
                    if (o.facts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(o.facts.join(' · '), style: context.type.bodySmall?.copyWith(color: c.faint)),
                    ],
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
