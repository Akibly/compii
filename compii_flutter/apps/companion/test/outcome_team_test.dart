// The outcome receipt counts only what Core recorded, and the Team page shows each
// teammate's live state from Core's own tasks.
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/outcome.dart';
import 'package:compii/src/ui/shell.dart' show AppState;
import 'package:compii/src/ui/team_halo.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TaskView _task(String status, List<Map<String, dynamic>> events) {
  final t = TaskView(id: 't1', request: 'Summarise the Q3 invoices for Tom', status: status);
  t.events.addAll(events);
  return t;
}

class _Core extends CoreClient {
  _Core() {
    bots = [
      BotView(id: 'bcompii', name: 'Compii', primary: true, trust: 'full', avatar: 'a3.orb.1'),
      BotView(id: 'bana', name: 'Researcher', job: 'Finds and cross-checks sources', avatar: 'a3.tile.5', tools: ['web']),
      BotView(id: 'binbox', name: 'Inbox Manager', job: 'Sorts mail', avatar: 'a3.pill.12', tools: ['mail']),
      BotView(id: 'bold', name: 'Gone', job: 'Archived', avatar: 'a3.gem.2', archived: true),
    ];
    primaryBotId = 'bcompii';
    botPacks = [
      {'key': 'mail', 'label': 'Mail & calendar'},
      {'key': 'web', 'label': 'Web & research'},
    ];
    tasks['t1'] = TaskView(id: 't1', request: 'Past Fabrikam payments', status: 'running', botId: 'bana');
    tasks['t2'] = TaskView(id: 't2', request: 'Draft replies', status: 'waiting', botId: 'binbox')
      ..events.add({'type': 'approval_needed', 'approval_id': 'a1', 'what': 'Send a reply'});
  }

  @override
  Future<void> fetchTeam() async {}
}

void main() {
  test('a finished task gets a receipt counted from its events, not from its words', () {
    final o = Outcome.of(_task('done', [
      {'type': 'user_message', 'at': 100.0},
      {'type': 'action_done', 'tool': 'read_file', 'ok': true, 'at': 101.0},
      {'type': 'action_done', 'tool': 'update_plan', 'ok': true, 'at': 101.5},
      {'type': 'action_done', 'tool': 'create_document', 'ok': true, 'undoable': true, 'at': 108.0},
      {'type': 'file', 'path': r'C:\Docs\Q3 summary.docx', 'action': 'created', 'at': 108.0},
      {'type': 'sources', 'items': [{'url': 'a'}, {'url': 'b'}], 'at': 110.0},
      {'type': 'task_finished', 'text': 'Done.', 'at': 114.0},
    ]))!;
    expect(o.headline, 'Done · 14 s · 2 steps', reason: 'the plan checklist is not a step of work');
    expect(o.facts, ['Created 1 file', 'read 2 web pages', '1 change can be undone']);
  });

  test('only the latest turn counts, and a plain chat answer gets no receipt', () {
    expect(
      Outcome.of(_task('done', [
        {'type': 'user_message', 'at': 1.0},
        {'type': 'action_done', 'tool': 'read_file', 'ok': true, 'at': 2.0},
        {'type': 'user_message', 'at': 10.0},
        {'type': 'task_finished', 'text': 'You’re welcome.', 'at': 11.0},
      ])),
      isNull,
    );
    expect(Outcome.of(_task('running', [{'type': 'user_message', 'at': 1.0}])), isNull, reason: 'not while it runs');
  });

  test('a failure is always said, with what failed and what was refused', () {
    final o = Outcome.of(_task('failed', [
      {'type': 'user_message', 'at': 1.0},
      {'type': 'action_done', 'tool': 'send_email', 'ok': false, 'at': 2.0},
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': false, 'at': 3.0},
    ]))!;
    expect(o.headline, startsWith('Didn’t finish'));
    expect(o.facts, containsAll(['1 action you said no to', '1 step failed']));
  });

  testWidgets('the team shows every active teammate with its live state, and opens its chat', (tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _Core();
    final state = AppState();
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.dark),
      home: Scaffold(body: TeamHaloPage(core: core, state: state, run: (f) async => f())),
    ));
    await tester.pump();

    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Compii'), findsOneWidget);
    expect(find.text('Gone'), findsNothing, reason: 'archived teammates stay out of the way');
    expect(find.text('Working · Past Fabrikam payments'), findsOneWidget);
    expect(find.text('Needs you · Draft replies'), findsOneWidget);
    expect(find.text('Web & research'), findsOneWidget, reason: 'its tools are spelled out');
    expect(find.text('Mail & calendar'), findsOneWidget);
    expect(find.textContaining('2 working now'), findsOneWidget);

    await tester.tap(find.text('Researcher'));
    await tester.pump();
    expect(state.botId, 'bana', reason: 'a click opens that teammate');
    expect(tester.takeException(), isNull);
  });
}
