// Deleting from the app: every delete asks once, says it can't be undone, then
// reports what Core actually did. Compii itself is reset, never deleted.
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/deleting.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Core extends CoreClient {
  final calls = <String>[];

  @override
  Future<void> deleteConversation(String taskId) async => calls.add('delete $taskId');

  @override
  Future<({int deleted, int running})> clearHistory({String botId = ''}) async {
    calls.add('clear ${botId.isEmpty ? 'all' : botId}');
    return (deleted: 3, running: 1);
  }

  @override
  Future<int> forgetAllMemory() async {
    calls.add('forget');
    return 2;
  }

  @override
  Future<void> resetCompii() async => calls.add('reset');

  @override
  Future<void> deleteBot(String id) async => calls.add('bot $id');
}

Future<void> _open(WidgetTester tester, Future<void> Function(BuildContext) flow) async {
  await tester.pumpWidget(MaterialApp(
    theme: compiiTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(builder: (context) => TextButton(onPressed: () => flow(context), child: const Text('go'))),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a conversation is deleted only after a yes, and a running one is refused', (tester) async {
    final core = _Core();
    final done = TaskView(id: 't1', request: 'Plan the trip to Dakar', status: 'done');
    await _open(tester, (ctx) => deleteConversationFlow(ctx, core, done));
    expect(find.text('Delete this conversation?'), findsOneWidget);
    expect(find.textContaining('can’t be undone'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(core.calls, isEmpty, reason: 'cancel deletes nothing');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(core.calls, ['delete t1']);
    expect(find.text('Conversation deleted.'), findsOneWidget);

    final running = TaskView(id: 't2', request: 'Still going', status: 'running');
    await _open(tester, (ctx) => deleteConversationFlow(ctx, core, running));
    expect(find.textContaining('Stop it first'), findsOneWidget);
    expect(core.calls, ['delete t1']);
  });

  testWidgets('clearing history says what went and what was kept', (tester) async {
    final core = _Core();
    await _open(tester, (ctx) => clearHistoryFlow(ctx, core));
    await tester.tap(find.widgetWithText(FilledButton, 'Delete conversations'));
    await tester.pumpAndSettle();
    expect(core.calls, ['clear all']);
    expect(find.text('Deleted 3 conversations. Kept 1 still working.'), findsOneWidget);
  });

  testWidgets('asking to delete Compii resets it instead, with a choice of what goes', (tester) async {
    final core = _Core();
    final compii = BotView(id: 'bc', name: 'Compii', primary: true);
    await _open(tester, (ctx) => deleteTeammateFlow(ctx, core, compii));
    expect(find.text('Reset Compii'), findsOneWidget);
    await tester.tap(find.text('All conversations'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(core.calls, ['forget', 'reset', 'clear all']);
    expect(find.textContaining('Compii reset: forgot 2 saved facts'), findsOneWidget);
  });

  testWidgets('a teammate is deleted by id after a yes', (tester) async {
    final core = _Core();
    final ana = BotView(id: 'bana', name: 'Ana');
    await _open(tester, (ctx) => deleteTeammateFlow(ctx, core, ana));
    expect(find.text('Delete Ana?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete Ana'));
    await tester.pumpAndSettle();
    expect(core.calls, ['bot bana']);
  });
}
