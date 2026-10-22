import 'package:compii/src/ui/proactive.dart';
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

Map<String, dynamic> _day(String date, String title, String lead) => {
  'date': date,
  'title': title,
  'lead': lead,
  'at': 1760000000.0,
  'bytes': 812,
};

final _days = [
  _day('2026-10-21', 'Wednesday 21 October 2026', '2 tasks finished, 3 actions taken'),
  _day('2026-10-20', 'Tuesday 20 October 2026', '1 task finished, 1 still needs you'),
];

void main() {
  testWidgets('off says so plainly, and nothing is kept until the user switches it on', (tester) async {
    bool? turned;
    await tester.pumpWidget(_app(JournalCard(
      settings: const {'enabled': false, 'at': '21:00'},
      days: const [],
      folder: r'C:\Users\me\Compii\journal',
      onToggle: (on) => turned = on,
      onAt: () {},
      onNow: () {},
      onRead: (_) {},
    )));

    expect(find.textContaining('Off. Turning it on'), findsOneWidget);
    expect(find.text('Nothing is written down yet.'), findsOneWidget);
    expect(find.textContaining('Saved in'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(turned, isTrue, reason: 'the switch is the only thing that starts the journal');
  });

  testWidgets('the days it wrote are listed with what each one holds, newest first', (tester) async {
    late Map<String, dynamic> opened;
    await tester.pumpWidget(_app(JournalCard(
      settings: const {'enabled': true, 'at': '19:45'},
      days: _days,
      folder: r'C:\Users\me\Compii\journal',
      onToggle: (_) {},
      onAt: () {},
      onNow: () {},
      onRead: (d) => opened = d,
    )));

    expect(find.textContaining('When a day closes'), findsOneWidget);
    expect(find.text('19:45'), findsOneWidget);
    expect(find.text('Wednesday 21 October 2026'), findsOneWidget);
    expect(find.textContaining('2 tasks finished, 3 actions taken'), findsOneWidget);
    expect(find.text('Nothing is written down yet.'), findsNothing);

    await tester.tap(find.text('Tuesday 20 October 2026'));
    await tester.pump();
    expect(opened['date'], '2026-10-20');
  });

  testWidgets('while the journal is being changed nothing else can be clicked', (tester) async {
    await tester.pumpWidget(_app(JournalCard(
      settings: const {'enabled': true, 'at': '21:00'},
      days: _days,
      folder: '',
      busy: true,
      onToggle: (_) {},
      onAt: () {},
      onNow: () {},
      onRead: (_) {},
    )));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '21:00')).onPressed, isNull);
    expect(find.text('Saved in'), findsNothing, reason: 'no folder named means nothing to point at');
  });

  testWidgets('a day that Core could not open is said out loud, not swallowed', (tester) async {
    await tester.pumpWidget(_app(JournalCard(
      settings: const {'enabled': true, 'at': '21:00'},
      days: _days,
      folder: r'C:\Users\me\Compii\journal',
      error: 'Core is not reachable',
      onToggle: (_) {},
      onAt: () {},
      onNow: () {},
      onRead: (_) {},
    )));

    expect(find.text('Core is not reachable'), findsOneWidget);
  });
}
