import 'package:compii/src/ui/proactive.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1000, 1200), disableAnimations: true),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 620,
              child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      ),
    );

Map<String, dynamic> _offer({
  String kind = 'routine',
  int count = 4,
  String when = 'Every weekday at 09:00',
  List<String> steps = const [],
}) =>
    {
      'id': 'g1234567',
      'kind': kind,
      'title': 'Summarize the new files in Downloads',
      'instruction': 'Summarize the new files in Downloads',
      'why': "You've asked for this $count times since 12 October, usually on weekdays around 09:00. "
          'Last asked 2 days ago. Compii only counted the conversations saved on this PC — '
          "it hasn't done any of this by itself yet.",
      'count': count,
      'schedule': {'kind': 'weekdays', 'at': '09:00'},
      'when': when,
      'steps': steps,
      'status': 'open',
    };

void main() {
  testWidgets('a repeated ask is offered with the count and the time it guessed', (tester) async {
    String? acted;
    await tester.pumpWidget(_app(HabitRow(
      suggestion: _offer(),
      onAccept: () => acted = 'accept',
      onDecline: () => acted = 'decline',
    )));

    expect(find.text('Summarize the new files in Downloads'), findsOneWidget);
    expect(find.text('4 times asked'), findsOneWidget);
    expect(find.text('Every weekday at 09:00'), findsOneWidget);
    expect(find.textContaining("hasn't done any of this by itself"), findsOneWidget);

    await tester.tap(find.text('Put it on the clock'));
    expect(acted, 'accept');
    await tester.tap(find.text('Not now'));
    expect(acted, 'decline');
  });

  testWidgets('a scattered habit is offered as steps to remember, not a clock', (tester) async {
    await tester.pumpWidget(_app(HabitRow(
      suggestion: _offer(kind: 'skill', when: '', steps: const ['Found the receipts', 'Wrote the sheet']),
      onAccept: () {},
      onDecline: () {},
    )));

    expect(find.text('Save the steps'), findsOneWidget);
    expect(find.text('Put it on the clock'), findsNothing);
    expect(find.text('2 steps that worked'), findsOneWidget);
    expect(find.text('Every weekday at 09:00'), findsNothing);
  });

  testWidgets('answering once is enough: the card goes quiet while Core works', (tester) async {
    await tester.pumpWidget(_app(HabitRow(
      suggestion: _offer(),
      busy: true,
      error: "That offer has already been answered.",
      onAccept: () => fail('must not act while busy'),
      onDecline: () => fail('must not act while busy'),
    )));

    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(find.text('That offer has already been answered.'), findsOneWidget);
  });
}
