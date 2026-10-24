import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/supervisor.dart';
import 'package:compii/src/ui/team.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TaskView _task(List<Map<String, dynamic>> events) =>
    TaskView(id: 't', request: 'get the lease sorted', status: 'done')..events.addAll(events);

Widget _app(Widget child) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1200, 900), disableAnimations: true),
    child: Scaffold(
      body: Center(
        child: SizedBox(width: 620, child: SingleChildScrollView(child: child)),
      ),
    ),
  ),
);

Widget _page(Widget child) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1200, 900), disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

void main() {
  test('delegations, verdicts and hiring suggestions stay on their own turn', () {
    final turns = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'delegation', 'job_id': 'j1', 'child_task': 'c1', 'bot_id': 'b2', 'bot_name': 'Analyst',
        'objective': 'Read the lease.', 'done_when': 'Dated list.', 'budget_min': 8, 'trust': 'probation', 'at': 1},
      {'type': 'delegation_done', 'job_id': 'j1', 'child_task': 'c1', 'status': 'done',
        'result': 'Two dates found.', 'at': 5},
      {'type': 'job_reviewed', 'job_id': 'j1', 'verdict': 'sent_back', 'note': 'No page numbers.', 'at': 6},
      {'type': 'hiring', 'proposal': {'id': 'h1', 'name': 'Inbox Manager', 'job': 'Triage mail'}, 'at': 7},
      {'type': 'hiring_resolved', 'proposal_id': 'h1', 'status': 'hired',
        'bot': {'id': 'b3', 'name': 'Inbox Manager'}, 'at': 9},
      {'type': 'task_finished', 'status': 'done', 'text': 'Done.', 'at': 10},
      {'type': 'user_message', 'text': 'and the reply?', 'at': 20},
      {'type': 'delegation', 'job_id': 'j2', 'child_task': 'c2', 'bot_id': 'b2', 'bot_name': 'Analyst',
        'objective': 'Draft a reply.', 'at': 21},
    ]));
    expect(turns, hasLength(2));
    final first = turns.first;
    expect(first.delegations.single['child_task'], 'c1');
    expect(first.delegationDone['j1']!['status'], 'done');
    expect(first.reviews['j1']!['verdict'], 'sent_back');
    expect(first.hirings.single['proposal']['id'], 'h1');
    expect(first.hiringResolved['h1']!['status'], 'hired');
    final last = turns.last;
    expect(last.delegations.single['job_id'], 'j2');
    expect(last.reviews, isEmpty, reason: 'a new ask starts a clean turn');
    expect(last.hiringResolved, isEmpty);
  });

  test('a bot from Core carries its trust, record and current work', () {
    final bot = BotView.fromJson({
      'id': 'b2',
      'name': 'Analyst',
      'job': 'Reads contracts',
      'trust': 'probation',
      'stats': {'jobs': 3, 'accepted': 2, 'rejected': 1, 'success': 67},
      'working': [
        {'task_id': 'c1', 'objective': 'Read the lease.'},
      ],
    });
    expect(bot.trust, 'probation');
    expect(bot.trusted, isFalse);
    expect(bot.busy, isTrue);
    expect(bot.stats['accepted'], 2);
  });

  test('a delegated task knows its parent job and probation', () {
    final task = TaskView.fromJson({
      'id': 'c1',
      'request': 'Read the lease.',
      'status': 'running',
      'parent_id': 't1',
      'probation': true,
      'job': {'id': 'j1', 'objective': 'Read the lease.', 'bot_id': 'b2'},
      'events': const [],
    });
    expect(task.parentId, 't1');
    expect(task.probation, isTrue);
    expect(task.delegated, isTrue);
  });

  testWidgets('a delegation card shows who has the job and how it came back', (tester) async {
    final core = CoreClient();
    await tester.pumpWidget(_app(DelegationCard(
      event: {
        'type': 'delegation', 'job_id': 'j1', 'child_task': 'c1', 'bot_id': 'b2', 'bot_name': 'Analyst',
        'objective': 'Read the lease and list renewal dates.', 'done_when': 'A dated list with page references.',
        'budget_min': 8, 'trust': 'trusted',
      },
      done: {
        'type': 'delegation_done', 'job_id': 'j1', 'child_task': 'c1', 'status': 'done',
        'result': 'Two dates found.', 'actions': 3, 'files': ['lease.md'],
      },
      review: {'type': 'job_reviewed', 'job_id': 'j1', 'verdict': 'accepted'},
      core: core,
      run: (action) => action(),
    )));
    expect(find.text('Assigned to Analyst'), findsOneWidget);
    expect(find.text('Trusted teammate'), findsOneWidget);
    expect(find.text('Read the lease and list renewal dates.'), findsOneWidget);
    expect(find.text('Done when: A dated list with page references.'), findsOneWidget);
    expect(find.text('Reported done'), findsOneWidget);
    expect(find.text('Two dates found.'), findsOneWidget);
    expect(find.text('3 actions · 1 file'), findsOneWidget);
    expect(find.text('Compii checked it and accepted.'), findsOneWidget);
  });

  testWidgets('a delegation still out shows the budget, not a result', (tester) async {
    final core = CoreClient();
    await tester.pumpWidget(_app(DelegationCard(
      event: {
        'type': 'delegation', 'job_id': 'j1', 'child_task': 'c1', 'bot_id': 'b2', 'bot_name': 'Analyst',
        'objective': 'Read the lease.', 'budget_min': 12, 'trust': 'probation',
      },
      core: core,
      run: (action) => action(),
    )));
    await tester.pump();
    expect(find.text('Working'), findsOneWidget);
    expect(find.text('On probation'), findsOneWidget);
    expect(find.text('Compii is waiting on this — up to 12 min.'), findsOneWidget);
  });

  testWidgets('a hiring card lets the user name the teammate before saying yes', (tester) async {
    final core = CoreClient();
    await tester.pumpWidget(_app(HiringCard(
      event: {
        'type': 'hiring',
        'proposal': {
          'id': 'h1', 'name': 'Inbox Manager', 'job': 'Triage mail',
          'why': 'Mail is piling up.', 'first_task': 'Sort today’s mail.',
        },
      },
      core: core,
      live: true,
    )));
    expect(find.text('A new teammate?'), findsOneWidget);
    expect(find.text('Mail is piling up.'), findsOneWidget);
    expect(find.text('First up: Sort today’s mail.'), findsOneWidget);
    expect(find.text('Hire Inbox Manager'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Starts on probation: changes ask, sends and deletes are off.'), findsOneWidget);
    final name = tester.widget<TextField>(find.byType(TextField).first);
    expect(name.controller!.text, 'Inbox Manager');

    await tester.enterText(find.byType(TextField).first, 'Mailroom');
    await tester.pump();
    expect(find.text('Hire Mailroom'), findsOneWidget);
  });

  testWidgets('a suggestion with no answer and no live turn reads as expired', (tester) async {
    final core = CoreClient();
    await tester.pumpWidget(_app(HiringCard(
      event: {'type': 'hiring', 'proposal': {'id': 'h1', 'name': 'Inbox Manager', 'job': 'Triage mail'}},
      core: core,
    )));
    expect(find.text('This suggestion expired.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a hired teammate is confirmed on the card', (tester) async {
    final core = CoreClient();
    await tester.pumpWidget(_app(HiringCard(
      event: {'type': 'hiring', 'proposal': {'id': 'h1', 'name': 'Inbox Manager', 'job': 'Triage mail'}},
      resolved: {'type': 'hiring_resolved', 'proposal_id': 'h1', 'status': 'hired',
        'bot': {'id': 'b3', 'name': 'Inbox Manager'}},
      core: core,
      live: false,
    )));
    expect(find.text('Inbox Manager is on the team, on probation.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the team page shows the roster, the open suggestion and the record', (tester) async {
    final core = CoreClient()..status = CoreStatus.offline;
    core.botPacks = [
      {'key': 'mail', 'label': 'Mail & calendar'},
      {'key': 'knowledge', 'label': 'Memory & knowledge'},
    ];
    core.bots = [
      BotView(id: 'b1', name: 'Compii', primary: true, trust: 'full',
          stats: {'jobs': 4, 'accepted': 3, 'rejected': 1}),
      BotView(id: 'b2', name: 'Analyst', job: 'Reads contracts', trust: 'probation',
          mode: 'team', tools: ['mail', 'knowledge'],
          stats: {'jobs': 3, 'accepted': 2, 'rejected': 1, 'success': 67},
          working: [
            {'id': 'c1', 'title': 'Read the lease', 'status': 'running'},
          ]),
    ];
    core.teamProposals = [
      {'id': 'h1', 'name': 'Inbox Manager', 'job': 'Triage mail'},
    ];
    core.teamJobs = [
      {'id': 'j1', 'bot_id': 'b2', 'bot_name': 'Analyst', 'objective': 'Read the lease.',
        'status': 'done', 'verdict': 'accepted', 'started': DateTime.now().millisecondsSinceEpoch / 1000 - 60},
    ];
    final state = AppState();
    await tester.pumpWidget(_page(TeamPage(core: core, state: state, run: (a) => a())));
    await tester.pump();

    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Runs the team'), findsOneWidget);
    expect(find.text('Waiting for your answer'.toUpperCase()), findsOneWidget);
    expect(find.text('Compii suggests Inbox Manager'), findsOneWidget);
    expect(find.text('Reads contracts'), findsWidgets, reason: 'the directory row and the teammate on show');
    expect(find.text('Probation'), findsOneWidget);
    expect(find.text('Team player · Mail & calendar · Memory & knowledge'), findsOneWidget);
    expect(find.text('Working on “Read the lease”'), findsOneWidget);
    expect(find.text('3 jobs · 2 accepted · 1 sent back · 67%'), findsOneWidget);
    expect(find.text('Read the lease.'), findsOneWidget);
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('HOW WORK MOVES'), findsOneWidget);
    expect(find.textContaining('Compii leads —', findRichText: true), findsOneWidget);
    expect(find.textContaining('Team players and leads —', findRichText: true), findsOneWidget);
    expect(find.textContaining('Solo —', findRichText: true), findsOneWidget);
    expect(find.text('HOW TRUST WORKS'), findsOneWidget);
  });
}
