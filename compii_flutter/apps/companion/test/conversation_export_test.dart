import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/conversation_io.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _compii = 'bcompii';
const _ana = 'bana';

final _roster = [
  BotView(id: _compii, name: 'Compii', primary: true, trust: 'full', avatar: 'a1.orb.1'),
  BotView(id: _ana, name: 'Ana', job: 'Research', template: 'researcher', avatar: 'a1.gem.11'),
];

TaskView _thread(List<Map<String, dynamic>> events, {String status = 'done', String answersWith = ''}) =>
    TaskView(id: 't1', request: 'Sort the receipts', status: status, botId: _compii, ownerId: _compii,
        answersWith: answersWith)
      ..events.addAll(events);

class _Recorded extends CoreClient {
  final List<String> deleted = [];

  _Recorded() {
    bots = List.of(_roster);
  }

  @override
  Future<void> deleteConversation(String taskId) async => deleted.add(taskId);
}

Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(theme: compiiTheme(Brightness.light), home: Scaffold(body: child)),
    );

/// Opens the conversation’s own menu.
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('conversation-menu')));
  await tester.pumpAndSettle();
}

const _threaded = [
  {'type': 'task_started', 'at': 0, 'bot_id': _compii},
  {'type': 'action_done', 'tool': 'read_file', 'label': 'Read receipt.pdf', 'ok': true, 'at': 1, 'bot_id': _compii},
  {'type': 'file', 'path': r'C:\Compii\out\sorted.csv', 'action': 'created', 'at': 2, 'bot_id': _compii},
  {'type': 'task_finished', 'status': 'done', 'text': 'Eleven receipts, £240 total.', 'at': 3, 'bot_id': _compii},
  {'type': 'user_message', 'text': 'Now the travel ones', 'at': 10, 'bot_id': _ana},
  {
    'type': 'delegation', 'task_id': 't1', 'at': 11, 'bot_id': _ana, 'job_id': 'j1',
    'bot_name': 'Ana', 'objective': 'group the travel receipts', 'child_task': 't2',
  },
  {'type': 'delegation_done', 'at': 12, 'job_id': 'j1', 'status': 'done', 'bot_id': _ana},
  {'type': 'sources', 'at': 13, 'bot_id': _ana, 'items': [
    {'title': 'Mileage rates', 'url': 'https://example.com/mileage'},
  ]},
  {'type': 'task_finished', 'status': 'done', 'text': 'Four travel receipts: £88.', 'at': 14, 'bot_id': _ana},
];

void main() {
  test('the exported thread holds what happened, in the order it happened', () {
    final text = threadMarkdown(_thread(_threaded, answersWith: 'groq · gpt-oss'), _Recorded());
    expect(text, contains('# Sort the receipts'));
    expect(text, contains('answered by groq · gpt-oss'));
    expect(text, contains('## 1. Sort the receipts'));
    expect(text, contains('Eleven receipts, £240 total.'));
    expect(text, contains('- Read receipt.pdf'));
    expect(text, contains('created C:\\Compii\\out\\sorted.csv'));
    expect(text, contains('## 2. Now the travel ones'));
    expect(text, contains('_Ana answered._'), reason: 'who spoke is part of the record');
    expect(text, contains('- Asked Ana to group the travel receipts — finished'));
    expect(text, contains('https://example.com/mileage'));
    expect(text.indexOf('## 1.'), lessThan(text.indexOf('## 2.')));
    expect(text, isNot(contains('task_finished')), reason: 'no raw event names in the export');
  });

  test('a turn that ended without words says so instead of being left out', () {
    final text = threadMarkdown(
        _thread([
          {'type': 'task_started', 'at': 0},
          {'type': 'action_done', 'tool': 'search_web', 'label': 'Searched', 'ok': false, 'at': 1},
          {'type': 'task_finished', 'status': 'done', 'at': 2},
        ]),
        _Recorded());
    expect(text, contains('_No answer was recorded._'));
    expect(text, contains('- Searched (didn’t work)'));
  });

  test('the file name says what the conversation was about', () {
    expect(threadFileName('Sort the receipts, please!'), 'compii-sort-the-receipts-please.md');
    expect(threadFileName('???'), 'compii-conversation.md');
    expect(threadFileName('a'.padRight(120, 'b')).length, lessThanOrEqualTo('compii-'.length + 41 + 3));
  });

  testWidgets('copying the thread puts the whole conversation on the clipboard', (tester) async {
    final copied = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final state = AppState();
    await _show(tester, ConversationMenu(task: _thread(_threaded), core: _Recorded(), state: state));
    await _openMenu(tester);
    await tester.tap(find.text('Copy the whole thread'));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect('${copied.single}', contains('Four travel receipts: £88.'));
    expect(find.text('Copied the conversation'), findsOneWidget);
  });

  testWidgets('deleting asks first, and only goes through Core once the user confirms', (tester) async {
    final core = _Recorded();
    final state = AppState()..open('t1');
    await _show(tester, ConversationMenu(task: _thread(_threaded), core: core, state: state));
    await _openMenu(tester);
    await tester.tap(find.text('Delete this conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this conversation?'), findsOneWidget);
    expect(core.deleted, isEmpty, reason: 'the question is not the answer');
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(core.deleted, isEmpty);

    await _openMenu(tester);
    await tester.tap(find.text('Delete this conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(core.deleted, ['t1']);
    expect(state.section, Section.home, reason: 'the thread is gone, so the app leaves it');
  });

  testWidgets('a conversation still working cannot be deleted', (tester) async {
    final core = _Recorded();
    await _show(tester, ConversationMenu(task: _thread(_threaded, status: 'running'), core: core, state: AppState()));
    await _openMenu(tester);
    final item = tester.widget<PopupMenuItem<String>>(
      find.ancestor(of: find.text('Delete it (stop Compii first)'), matching: find.byType(PopupMenuItem<String>)),
    );
    expect(item.enabled, isFalse);
    expect(core.deleted, isEmpty);
  });
}
