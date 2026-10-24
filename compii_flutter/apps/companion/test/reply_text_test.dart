import 'package:compii/src/ui/reply_text.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(String text, {OpenLink? onOpen}) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(20), child: ReplyText(text, onOpen: onOpen)))),
);

String _shown(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
    .join('\n');

/// The run of type carrying exactly these words, so a test can look at what it is
/// allowed to do — open a link, or not.
TextSpan? _spanFor(WidgetTester tester, String words) {
  List<TextSpan> walk(InlineSpan s) =>
  s is! TextSpan ? const [] : [s, for (final c in s.children ?? const <InlineSpan>[]) ...walk(c)];
  for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    final root = w.textSpan;
    if (root == null) continue;
    for (final s in walk(root)) {
      if (s.text == words) return s;
    }
  }
  return null;
}

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

  testWidgets('a link in the answer shows the words, and opens the address behind them', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_app(
      'The rate is on [the mileage page](https://example.com/mileage), rest is below.',
      onOpen: opened.add,
    ));
    await tester.pumpAndSettle();

    expect(_shown(tester), isNot(contains('https://example.com/mileage')),
        reason: 'the user reads a name, not raw markdown');
    final link = _spanFor(tester, 'the mileage page');
    expect(link, isNotNull);
    expect(link!.recognizer, isNotNull, reason: 'a cited page is reachable, not dead colour');
    (link.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, ['https://example.com/mileage']);
  });

  testWidgets('a link with no way out is set apart but never a dead button', (tester) async {
    await tester.pumpWidget(_app('See [the mileage page](https://example.com/mileage).'));
    await tester.pumpAndSettle();
    final link = _spanFor(tester, 'the mileage page');
    expect(link, isNotNull);
    expect(link!.recognizer, isNull);
  });

  testWidgets('a block of code can be taken away whole', (tester) async {
    final copied = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_app('```\npm run build\nflutter test\n```'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('copy-code')));
    await tester.pump();
    expect(copied, ['pm run build\nflutter test'], reason: 'the code, not the fences or the language');
    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Copy code'), findsOneWidget);
  });

  testWidgets('a block with nothing in it offers nothing to copy', (tester) async {
    await tester.pumpWidget(_app('```\n\n```'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy-code')), findsNothing);
  });
}
