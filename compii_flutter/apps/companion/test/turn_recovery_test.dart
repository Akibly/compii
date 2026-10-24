import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _compii = 'bcompii';

final _roster = [
  BotView(id: _compii, name: 'Compii', primary: true, trust: 'full', avatar: 'a1.orb.1'),
];

TaskView _thread(List<Map<String, dynamic>> events, {String status = 'done'}) =>
    TaskView(id: 't1', request: 'Summarise the invoice', status: status, botId: _compii)
      ..events.addAll(events);

/// Records what the app asks Core to do, instead of opening a socket a test can't use.
class _Recorded extends CoreClient {
  final List<String> again = [];
  final List<List<String>> replies = [];

  @override
  Future<void> answerAgain(String taskId) async => again.add(taskId);

  @override
  Future<void> reply(String taskId, String text, {List<String> attachments = const []}) async {
    replies.add([taskId, text]);
  }
}

CoreClient _core() => _Recorded()..bots = List.of(_roster);

Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(theme: compiiTheme(Brightness.light), home: Scaffold(body: child)),
    );

final _done = [
  {'type': 'task_started', 'at': 0, 'bot_id': _compii},
  {'type': 'action_done', 'tool': 'read_file', 'label': 'Read invoice.pdf', 'ok': true, 'at': 1, 'bot_id': _compii},
  {'type': 'task_finished', 'status': 'done', 'text': 'Two charges: £40 and £12.', 'at': 2, 'bot_id': _compii},
];

void main() {
  test('answering the same ask again starts a new exchange, leaving the first answer alone', () {
    final turns = turnsOf(_thread([
      ..._done,
      {'type': 'retry', 'text': 'Summarise the invoice', 'status': 'running', 'at': 30, 'bot_id': _compii},
      {'type': 'task_finished', 'status': 'done', 'text': '£52 in total, across two charges.', 'at': 31, 'bot_id': _compii},
    ]));
    expect(turns, hasLength(2));
    expect(turns.first.reply, 'Two charges: £40 and £12.', reason: 'the earlier words are not rewritten');
    expect(turns.last.ask, 'Summarise the invoice');
    expect(turns.last.reply, '£52 in total, across two charges.');
  });

  test('a retry with no words of its own repeats the conversation’s ask', () {
    final turns = turnsOf(_thread([
      ..._done,
      {'type': 'retry', 'text': '', 'status': 'running', 'at': 30},
      {'type': 'task_finished', 'status': 'done', 'text': 'Again: £52.', 'at': 31},
    ]));
    expect(turns.last.ask, 'Summarise the invoice');
    expect(turns.last.reply, 'Again: £52.');
  });

  testWidgets('the last answer can be copied, and copied words are what reach the clipboard', (tester) async {
    final copied = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _show(tester, ThreadView(task: _thread(_done), core: _core(), run: (f) => f()));
    await tester.tap(find.byKey(const Key('copy-answer')));
    await tester.pump();
    expect(copied, ['Two charges: £40 and £12.']);
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Copy'), findsOneWidget, reason: 'the confirmation is only a moment of feedback');
  });

  testWidgets('“Again” asks Core for a fresh answer to the same ask', (tester) async {
    final core = _Recorded()..bots = List.of(_roster);
    await _show(tester, ThreadView(task: _thread(_done), core: core, run: (f) => f()));
    expect(find.text('Again'), findsOneWidget);
    await tester.tap(find.byKey(const Key('answer-again')));
    await tester.pump();
    expect(core.again, ['t1']);
  });

  testWidgets('an answer that stopped on a problem is offered as “Try again”', (tester) async {
    await _show(
      tester,
      ThreadView(
        task: _thread([
          {'type': 'task_started', 'at': 0},
          {'type': 'task_finished', 'status': 'failed', 'text': 'I could not open that file.', 'at': 1},
        ]),
        core: _core(),
        run: (f) => f(),
      ),
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Again'), findsNothing);
  });

  testWidgets('only the newest exchange offers again and edit', (tester) async {
    await _show(
      tester,
      ThreadView(
        task: _thread([
          ..._done,
          {'type': 'user_message', 'text': 'And in euros?', 'at': 10},
          {'type': 'task_finished', 'status': 'done', 'text': 'About €60.', 'at': 11},
        ]),
        core: _core(),
        run: (f) => f(),
      ),
    );
    expect(find.text('Again'), findsOneWidget);
    expect(find.byKey(const Key('edit-ask-button')), findsOneWidget);
    expect(find.text('And in euros?'), findsOneWidget);
  });

  testWidgets('nothing is offered while Compii is still working', (tester) async {
    final task = _thread(_done, status: 'running');
    await _show(tester, ThreadView(task: task, core: _core(), run: (f) => f()));
    expect(find.byKey(const Key('answer-again')), findsNothing);
    expect(find.byKey(const Key('edit-ask-button')), findsNothing);
  });

  testWidgets('editing the last message sends the edited words as a new message', (tester) async {
    final core = _Recorded()..bots = List.of(_roster);
    await _show(tester, ThreadView(task: _thread(_done), core: core, run: (f) => f()));
    await tester.tap(find.byKey(const Key('edit-ask-button')));
    await tester.pump();
    expect(find.text('Summarise the invoice'), findsWidgets);
    await tester.enterText(find.byKey(const Key('edit-ask')), 'Summarise the invoice and find the due date');
    await tester.pump();
    await tester.tap(find.byKey(const Key('resend-ask')));
    await tester.pump();
    expect(core.replies, [
      ['t1', 'Summarise the invoice and find the due date'],
    ]);
    expect(find.byKey(const Key('edit-ask')), findsNothing, reason: 'the box closes once it is sent');
  });

  testWidgets('a cleared message cannot be sent', (tester) async {
    final core = _Recorded()..bots = List.of(_roster);
    await _show(tester, ThreadView(task: _thread(_done), core: core, run: (f) => f()));
    await tester.tap(find.byKey(const Key('edit-ask-button')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('edit-ask')), '   ');
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const Key('resend-ask'))).onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(core.replies, isEmpty);
    expect(find.byKey(const Key('edit-ask')), findsNothing);
  });
}
