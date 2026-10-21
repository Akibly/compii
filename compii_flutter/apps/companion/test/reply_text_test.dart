import 'package:compii/src/ui/reply_text.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(String text) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(20), child: ReplyText(text)))),
);

String _shown(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
    .join('\n');

void main() {
  test('the face line keeps the words and drops the markers', () {
    expect(plainMarkdown('You have **Qoder** in front with `3` tabs and a [plan](https://x.dev/p).'),
        'You have Qoder in front with 3 tabs and a plan.');
  });

  testWidgets('markdown markers become type, not asterisks on screen', (tester) async {
    await tester.pumpWidget(_app(
      'You have **Qoder** in front, with `3` tabs and a [plan](https://x.dev/p).\n\n'
      '## What is open\n'
      '- read the screen\n'
      '- *then* answer\n\n'
      '1. first thing\n'
      '2. second thing',
    ));
    await tester.pumpAndSettle();

    final shown = _shown(tester);
    expect(shown, isNot(contains('**')), reason: 'bold must not reach the eye as asterisks');
    expect(shown, isNot(contains('`')));
    expect(shown, isNot(contains('##')));
    expect(shown, isNot(contains('](https')));
    expect(shown, contains('Qoder'));
    expect(shown, contains('What is open'));
    expect(shown, contains('read the screen'));
    expect(shown, contains('second thing'));
    expect(find.text('•'), findsNWidgets(2), reason: 'bullets are drawn, not typed');
    expect(find.text('1.'), findsOneWidget);
  });

  testWidgets('a code block stays exactly as Compii wrote it', (tester) async {
    await tester.pumpWidget(_app('Run this:\n\n```\nx = 1  # **not** bold\n```\n\nDone.'));
    await tester.pumpAndSettle();
    expect(_shown(tester), contains('x = 1  # **not** bold'), reason: 'code is shown verbatim, markers and all');
  });
}
