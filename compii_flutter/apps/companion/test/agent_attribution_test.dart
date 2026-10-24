import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/console/character.dart' show Ember;
import 'package:compii/src/ui/bots.dart';
import 'package:compii/src/ui/shell.dart' show AppState;
import 'package:compii/src/ui/supervisor.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _compii = 'bcompii';
const _ana = 'bana';

final _roster = [
  BotView(id: _compii, name: 'Compii', primary: true, trust: 'full', avatar: 'a1.orb.1'),
  BotView(id: _ana, name: 'Ana', job: 'Research', avatar: 'a1.gem.11', color: '#E08BD0'),
];

TaskView _thread(List<Map<String, dynamic>> events, {String? botId, String? owner, String status = 'done'}) =>
    TaskView(id: 't1', request: 'first ask', status: status, botId: botId, ownerId: owner)..events.addAll(events);

CoreClient _core() => CoreClient()..bots = List.of(_roster);

/// Keeps the app’s requests in a list instead of opening a socket, so a widget test
/// can check what the app asked Core to do without pretending a server is listening.
class _Recorded extends CoreClient {
  final List<String> stopped = [];
  final List<List<String>> transferred = [];

  @override
  Future<void> stop(String taskId) async => stopped.add(taskId);

  @override
  Future<TaskView> transferConversation(String taskId, String botId, {String note = ''}) async {
    transferred.add([taskId, botId]);
    final moved = tasks[taskId]!;
    moved.botId = botId;
    return moved;
  }
}

Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(theme: compiiTheme(Brightness.light), home: Scaffold(body: child)),
    );

void main() {
  test('a turn remembers which teammate spoke it', () {
    final turns = turnsOf(_thread([
      {'type': 'task_started', 'at': 0, 'bot_id': _ana},
      {'type': 'task_finished', 'status': 'done', 'text': 'Mine.', 'at': 1, 'bot_id': _ana},
      {'type': 'user_message', 'text': 'now Ana', 'at': 2, 'bot_id': _ana},
      {'type': 'handoff', 'at': 3, 'bot_id': _compii, 'from_id': _ana, 'to_id': _compii, 'by': 'user', 'note': ''},
      {'type': 'task_finished', 'status': 'done', 'text': 'Theirs.', 'at': 4, 'bot_id': _compii},
    ]));
    expect(turns.map((t) => t.botId), [_ana, _compii]);
    expect(turns.last.handoffs, hasLength(1));
  });

  test('a turn falls back to the thread’s own bot when its events name nobody', () {
    final turns = turnsOf(_thread([
      {'type': 'task_started', 'at': 0},
      {'type': 'task_finished', 'status': 'done', 'text': 'Done.', 'at': 1},
    ], botId: _ana));
    expect(turns.single.botId, _ana);
  });

  test('a thread belongs to whoever opened it, answers it, or shares it', () {
    final task = TaskView(id: 'x', request: 'r', status: 'done', botId: 'b2', ownerId: 'b1', team: ['b1', 'b3']);
    expect(task.belongsTo('b1'), isTrue);
    expect(task.belongsTo('b2'), isTrue);
    expect(task.belongsTo('b3'), isTrue);
    expect(task.belongsTo('b4'), isFalse);
  });

  testWidgets('a teammate answers in its own face, not Compii’s', (tester) async {
    final task = _thread([
      {'type': 'task_started', 'at': 0, 'bot_id': _ana},
      {'type': 'action_done', 'tool': 'search_web', 'label': 'Searched', 'ok': true, 'at': 1, 'bot_id': _ana},
      {'type': 'task_finished', 'status': 'done', 'text': 'Three sources.', 'at': 2, 'bot_id': _ana},
    ], botId: _ana, owner: _ana);
    await _show(tester, ThreadView(task: task, core: _core(), run: (f) => f()));
    expect(find.byType(Ember), findsNothing);
    expect(find.byType(BotAvatar), findsOneWidget);
  });

  testWidgets('Compii still wears its own character', (tester) async {
    final task = _thread([
      {'type': 'task_started', 'at': 0, 'bot_id': _compii},
      {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.', 'at': 1, 'bot_id': _compii},
    ], botId: _compii, owner: _compii);
    await _show(tester, ThreadView(task: task, core: _core(), run: (f) => f()));
    expect(find.byType(Ember), findsOneWidget);
    expect(find.byType(BotAvatar), findsNothing);
  });

  testWidgets('a handed-over turn says who took it and what travelled with it', (tester) async {
    final task = _thread([
      {'type': 'task_started', 'at': 0, 'bot_id': _ana},
      {'type': 'user_message', 'text': 'take this from here', 'at': 2, 'bot_id': _ana},
      {
        'type': 'handoff', 'at': 3, 'bot_id': _compii, 'from_id': _ana, 'from': 'Ana', 'to_id': _compii,
        'to': 'Compii', 'by': 'user', 'note': 'the two files are in Downloads',
        'shared': {'request': 'first ask', 'turns': 2, 'tools': ['read_file'], 'files': ['a.pdf', 'b.csv']},
      },
      {'type': 'task_finished', 'status': 'done', 'text': 'Picked it up.', 'at': 4, 'bot_id': _compii},
    ], botId: _compii, owner: _ana);
    await _show(tester, ThreadView(task: task, core: _core(), run: (f) => f()));
    expect(find.text('the two files are in Downloads'), findsOneWidget);
    expect(find.textContaining('Shared with Compii: 2 exchanges · 2 files'), findsOneWidget);
  });

  testWidgets('a teammate that takes the thread says so on its own turn', (tester) async {
    final task = _thread([
      {'type': 'task_started', 'at': 0, 'bot_id': _compii},
      {'type': 'task_finished', 'status': 'done', 'text': 'This one is Ana’s.', 'at': 1, 'bot_id': _compii},
      {'type': 'user_message', 'text': 'Ana, you finish it', 'at': 2, 'bot_id': _compii},
      {
        'type': 'handoff', 'at': 3, 'bot_id': _ana, 'from_id': _compii, 'from': 'Compii', 'to_id': _ana,
        'to': 'Ana', 'by': 'user', 'note': '', 'shared': {'turns': 2, 'files': []},
      },
      {'type': 'task_finished', 'status': 'done', 'text': 'Two left.', 'at': 4, 'bot_id': _ana},
    ], botId: _ana, owner: _compii);
    await _show(tester, ThreadView(task: task, core: _core(), run: (f) => f()));
    expect(find.text('took this over'), findsOneWidget);
    expect(find.text('Ana'), findsWidgets);
  });

  testWidgets('a running job can be stopped from its own card', (tester) async {
    final core = _Recorded()
      ..bots = List.of(_roster)
      ..tasks['tchild'] = TaskView(id: 'tchild', request: 'job', status: 'running');
    await _show(
      tester,
      DelegationCard(
        event: {
          'type': 'delegation', 'task_id': 't1', 'at': 0, 'bot_id': _ana, 'bot_name': 'Ana',
          'objective': 'Summarise the invoice', 'done_when': 'a summary exists', 'budget_min': 8,
          'child_task': 'tchild', 'trust': 'probation',
        },
        core: core,
        run: (f) => f(),
        onOpen: (_) {},
      ),
    );
    expect(find.text('Watch'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    // The card spins while the job runs, so pump a frame rather than settling.
    await tester.pump();
    expect(core.stopped, ['tchild']);
  });

  testWidgets('the user moves a conversation to a teammate, and the thread follows', (tester) async {
    final core = _Recorded()..bots = List.of(_roster);
    final state = AppState();
    final task = TaskView(id: 't9', request: 'sort these invoices', status: 'done',
        botId: _compii, ownerId: _compii);
    core.tasks['t9'] = task;
    await _show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showHandover(context, core: core, state: state, run: (f) => f(), task: task),
          child: const Text('Hand over'),
        ),
      ),
    );
    await tester.tap(find.text('Hand over'));
    await tester.pump();
    expect(find.text('Hand this conversation to…'), findsOneWidget);
    // Compii is the one answering, so it isn't offered as a destination; Ana is.
    expect(find.text('Compii'), findsNothing);
    await tester.tap(find.text('Ana'));
    await tester.pump();
    expect(core.transferred, [
      ['t9', _ana],
    ]);
    expect(state.selected, 't9');
    expect(core.tasks['t9']!.botId, _ana);
    // The user came to Compii, so the thread keeps that owner even while Ana answers it.
    expect(core.tasks['t9']!.ownerId, _compii);
  });
}
