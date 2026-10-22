import 'package:compii/src/ui/reader.dart';
import 'package:compii/src/ui/timeline.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1200, 1400), disableAnimations: true),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 760,
          child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  ),
);

Map<String, dynamic> _book({Object? undo}) => {
  'headline': 'In the last day: 1 task finished, 1 still needs you, 2 actions taken.',
  'counts': {'done': 1, 'waiting': 1, 'actions': 2, 'apps': 0},
  'left_off': {
    'task_id': 't2',
    'request': 'Draft a reply to Priya',
    'last': 'Waiting for your approval',
    'status': 'waiting',
  },
  'undo': undo == null ? null : {'task_id': 't1', 'summary': 'Moved report.txt to Archive'},
  'markdown': '**In the last day: 1 task finished, 1 still needs you, 2 actions taken.**\n\n'
      '### Finished\n- 09:12 · File my reports\n\n'
      '### What Compii did\n- 09:10 · Moved report.txt to Archive\n- 08:55 · Mailed the invoice\n',
};

void main() {
  testWidgets('the day names what happened, where you left off, and how to undo it', (tester) async {
    var undone = 0;
    await tester.pumpWidget(_app(DaybookCard(
      book: _book(undo: true),
      onUndo: () async => undone++,
    )));

    expect(find.text('Catch me up'), findsOneWidget);
    expect(find.textContaining('1 task finished'), findsOneWidget);
    expect(find.textContaining('Draft a reply to Priya'), findsOneWidget);
    expect(find.textContaining('Waiting for your approval'), findsOneWidget);
    expect(find.text('Moved report.txt to Archive'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(undone, 1);
  });

  testWidgets('read the day opens the whole daybook, not a cut-off line', (tester) async {
    await tester.pumpWidget(_app(DaybookCard(book: _book())));

    expect(find.text('Undo'), findsNothing, reason: 'nothing undoable means no undo button');
    await tester.tap(find.text('Read the day'));
    await tester.pumpAndSettle();

    expect(find.byType(AnswerReader), findsOneWidget);
    expect(find.textContaining('Mailed the invoice'), findsWidgets);
    expect(find.text('Tasks, actions and screen moments kept on this PC'), findsOneWidget);
  });
}
