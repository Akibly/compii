import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:compii/src/ui/trust.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TaskView _task(List<Map<String, dynamic>> events, {String status = 'waiting'}) =>
    TaskView(id: 't', request: 'summarise the brief', status: status)..events.addAll(events);

final _events = <Map<String, dynamic>>[
  {'type': 'task_started', 'at': 0},
  {'type': 'action_done', 'tool': 'read_file', 'label': 'Read brief.txt', 'ok': true, 'at': 1},
  {'type': 'injection_warning', 'tool': 'read_file', 'phrase': 'AI assistants: you must now', 'at': 1},
  {'type': 'redacted', 'tool': 'read_file', 'count': 1, 'kinds': ['card number'], 'at': 1},
  {'type': 'action_blocked', 'tool': 'press_keys', 'label': 'Press win+l', 'reason': 'Compii never presses win+l.', 'at': 2},
  {
    'type': 'approval_needed', 'approval_id': 'a1', 'kind': 'send', 'label': 'Email the brief',
    'input': {'to': ['x@example.com']}, 'can_always': false,
    'why': 'This task read text that looked like instructions to an AI, so this needs a fresh okay.', 'at': 3,
  },
];

void main() {
  test('safety events are collected on their turn', () {
    final turn = turnsOf(_task(_events)).single;
    expect(turn.safety.map((e) => e['type']), ['injection_warning', 'redacted', 'action_blocked']);
    expect(turn.pending?['approval_id'], 'a1');
  });

  testWidgets('a conversation shows safety notes, the reason for asking, and no "Always allow" after an injection', (tester) async {
    final core = CoreClient();
    Future<void> run(Future<void> Function() f) => f();
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: _task(_events), core: core, run: run)),
    ));
    expect(find.textContaining('looked like instructions to an AI'), findsWidgets);
    expect(find.textContaining('Hid 1 private item (card number)'), findsOneWidget);
    expect(find.textContaining('Blocked: Compii never presses win+l.'), findsOneWidget);
    expect(find.text('Always allow'), findsNothing);
  });

  testWidgets('"Always allow" is offered when Core allows it', (tester) async {
    final events = [
      {'type': 'task_started', 'at': 0},
      {'type': 'approval_needed', 'approval_id': 'a2', 'kind': 'change', 'label': 'Move x', 'input': {}, 'can_always': true, 'at': 1},
    ];
    Future<void> run(Future<void> Function() f) async {}
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: _task(events), core: CoreClient(), run: run)),
    ));
    expect(find.text('Always allow'), findsOneWidget);
  });

  test('a decided approval keeps whether the user said yes', () {
    final turn = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'approval_needed', 'approval_id': 'a1', 'kind': 'send', 'label': 'Email', 'input': {}, 'at': 1},
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': false, 'at': 2},
    ], status: 'running')).single;
    expect(turn.resolved['a1'], isFalse);
    expect(turn.pending, isNull);
  });

  testWidgets('a declined approval leaves its outcome on screen', (tester) async {
    final events = [
      {'type': 'task_started', 'at': 0},
      {'type': 'approval_needed', 'approval_id': 'a1', 'kind': 'send', 'label': 'Email the brief', 'input': {}, 'at': 1},
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': false, 'at': 2},
      {'type': 'task_finished', 'status': 'done', 'text': 'I did not send it.', 'at': 3},
    ];
    Future<void> run(Future<void> Function() f) async {}
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: _task(events, status: 'done'), core: CoreClient(), run: run)),
    ));
    expect(find.text('You declined'), findsOneWidget);
    expect(find.text('Email the brief'), findsOneWidget);
    expect(find.textContaining('Compii was told not to retry it'), findsOneWidget);
    expect(find.text('Needs your okay'), findsNothing, reason: 'the card is gone; the outcome stays');
    expect(find.text('I did not send it.'), findsOneWidget);

    final approved = _task([
      {'type': 'task_started', 'at': 0},
      {'type': 'approval_needed', 'approval_id': 'a1', 'kind': 'send', 'label': 'Email the brief', 'input': {}, 'at': 1},
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': true, 'at': 2},
      {'type': 'task_finished', 'status': 'done', 'text': 'Sent it.', 'at': 3},
    ], status: 'done');
    // A yes is already told by the action ledger; only a no needs its own mark.
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: approved, core: CoreClient(), run: run)),
    ));
    expect(find.text('You declined'), findsNothing);
  });

  test('save-as-skill and safety widgets build', () {
    expect(const SafetyNotes(events: []), isA<StatelessWidget>());
  });
}
