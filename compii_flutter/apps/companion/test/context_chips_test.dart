import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Compii answers with things it can see on this PC — a saved fact, a window title, an
/// installed recipe. The user has to be able to read that whole list and strike a piece
/// off, and the refusal has to last, or "leave this out" means nothing after one message.
Map<String, dynamic> _item(String id, String label, String kind, String source, String scope) => {
      'id': id,
      'label': label,
      'kind': kind,
      'source': source,
      'scope': scope,
      'sensitivity': kind == 'observation' ? 'personal' : 'normal',
      'at': DateTime.now().millisecondsSinceEpoch / 1000.0,
      'why': kind == 'observation' ? 'Open on this PC when you asked' : 'Compii learned this earlier',
      'chars': label.length,
      'expires_in': kind == 'observation' ? 118.4 : null,
    };

TaskView _task(List<Map<String, dynamic>> events) =>
    TaskView(id: 't1', request: 'what should I export?', status: 'done')..events.addAll(events);

void main() {
  test('the context a turn was answered with stays with that turn', () {
    final turns = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {
        'type': 'context',
        'at': 1,
        'items': [
          _item('cx-a', 'Prefers PDF exports', 'memory', 'remembered', 'memory'),
          _item('cx-b', 'In front: “Excel”', 'observation', 'desktop', 'screen_aware'),
        ],
        'unavailable': [
          {'source': 'what is open on this PC', 'why': 'it could not be read in time'}
        ],
        'refused': ['cx-c'],
        'expired': 1,
        'duplicated': 2,
        'trimmed': 0,
        'budget': 6000,
        'chars': 30,
      },
      {'type': 'task_finished', 'status': 'done', 'text': 'PDF, from Excel.', 'at': 2},
      {'type': 'user_message', 'text': 'and again', 'at': 3},
      {'type': 'task_finished', 'status': 'done', 'text': 'Same.', 'at': 4},
    ]));
    expect(turns.first.context?['items'], hasLength(2));
    expect(turns.last.context, isNull, reason: 'a later turn carries its own list, not this one');
  });

  test('striking a source off is remembered for that conversation only', () {
    final core = CoreClient();
    core.withhold('t1', 'cx-a', true);
    core.withhold('t1', 'cx-a', true);
    expect(core.withheld['t1'], {'cx-a'});
    core.withhold('t2', 'cx-a', true);
    expect(core.withheld['t2'], {'cx-a'}, reason: 'another chat is not covered by this one');
    core.withhold('t1', 'cx-a', false);
    expect(core.withheld['t1'], isEmpty);
    expect(core.withheld['t2'], {'cx-a'});
  });

  testWidgets('every attached item can be read, with where it came from, and left out', (tester) async {
    final core = CoreClient();
    final task = _task([
      {'type': 'task_started', 'at': 0},
      {
        'type': 'context',
        'at': 1,
        'items': [
          _item('cx-a', 'Prefers PDF exports', 'memory', 'remembered', 'memory'),
          _item('cx-b', 'In front: “Excel”', 'observation', 'desktop', 'screen_aware'),
        ],
        'unavailable': [
          {'source': 'the user’s saved instructions', 'why': 'RuntimeError: memory file is locked'}
        ],
        'refused': <String>[],
        'expired': 1,
        'duplicated': 0,
        'trimmed': 0,
        'budget': 6000,
        'chars': 30,
      },
      {'type': 'task_finished', 'status': 'done', 'text': 'PDF, from Excel.', 'at': 2},
    ]);

    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: task, core: core, run: (f) => f())),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Compii used'), findsOneWidget);
    expect(find.textContaining('2 things it could see'), findsOneWidget);
    expect(find.textContaining('1 could not be read'), findsOneWidget,
        reason: 'a source that failed is named on the chip, not left to be guessed about');

    await tester.tap(find.textContaining('things it could see').first);
    await tester.pumpAndSettle();
    expect(find.text('What Compii could see'), findsOneWidget);
    expect(find.text('Prefers PDF exports'), findsOneWidget);
    expect(find.text('In front: “Excel”'), findsOneWidget);
    expect(find.textContaining('allowed by screen_aware'), findsOneWidget);
    expect(find.textContaining('true for'), findsOneWidget, reason: 'a window title goes stale');
    expect(find.textContaining('memory file is locked'), findsOneWidget);
    expect(find.text('Leave out'), findsNWidgets(2));

    await tester.tap(find.text('Leave out').first);
    await tester.pumpAndSettle();
    expect(core.withheld['t1'], {'cx-a'});
    expect(find.text('Left out'), findsOneWidget);

    await tester.tap(find.text('Left out'));
    await tester.pumpAndSettle();
    expect(core.withheld['t1'], isEmpty);
    expect(find.text('Leave out'), findsNWidgets(2));

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('things it could see').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave out').last);
    await tester.pumpAndSettle();
    expect(core.withheld['t1'], {'cx-b'});
  });

  testWidgets('a struck-off item shows in the count, not as a hole', (tester) async {
    final core = CoreClient()..withhold('t1', 'cx-b', true);
    final task = _task([
      {'type': 'task_started', 'at': 0},
      {
        'type': 'context',
        'at': 1,
        'items': [
          _item('cx-a', 'Prefers PDF exports', 'memory', 'remembered', 'memory'),
          _item('cx-b', 'In front: “Excel”', 'observation', 'desktop', 'screen_aware'),
        ],
        'unavailable': <Map<String, String>>[],
        'refused': ['cx-b'],
        'expired': 0,
        'duplicated': 0,
        'trimmed': 0,
        'budget': 6000,
        'chars': 30,
      },
      {'type': 'task_finished', 'status': 'done', 'text': 'PDF.', 'at': 2},
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: task, core: core, run: (f) => f())),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 of 2 things it could see'), findsOneWidget);
    expect(find.textContaining('2 item(s) you struck off'), findsNothing);
    await tester.tap(find.textContaining('things it could see').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('struck off were left out of this answer'), findsOneWidget);
  });
}
