import 'package:compii/src/ui/trust.dart';
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
              width: 720,
              child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      ),
    );

Map<String, dynamic> _report({
  int steps = 4,
  int prompt = 1850,
  int completion = 310,
  int ms = 75000,
  int heard = 0,
  int failed = 0,
  double local = 0.25,
}) =>
    {
      'days': 7,
      'total': {
        'steps': steps, 'prompt': prompt, 'completion': completion, 'tokens': prompt + completion,
        'ms': ms, 'heard_ms': heard, 'failed': failed, 'estimated': 1,
      },
      'by_model': [
        {'model': 'groq · openai/gpt-oss-20b', 'steps': 2, 'tokens': 1260, 'ms': 1500},
        {'model': 'ollama · qwen3', 'steps': 1, 'tokens': 900, 'ms': 9000},
      ],
      'by_day': [],
      'by_kind': [],
      'last_minute_tokens': 210,
      'local_share': local,
      'note': 'Token counts marked estimated were measured by counting characters. '
          'Compii doesn’t guess prices.',
    };

void main() {
  testWidgets('the week’s numbers are shown as what they are', (tester) async {
    await tester.pumpWidget(_app(UsageSummary(report: _report())));

    expect(find.text('2,160'), findsOneWidget);
    expect(find.text('1,850 in · 310 out'), findsOneWidget);
    expect(find.text('4 answers'), findsOneWidget);
    expect(find.text('1.3 min'), findsOneWidget); // 75 seconds, said as waiting, not as money
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('210'), findsOneWidget);
    expect(find.textContaining('groq · openai/gpt-oss-20b'), findsOneWidget);
    expect(find.textContaining('1,260 tokens · 2 steps'), findsOneWidget);
    expect(find.textContaining('guess prices'), findsOneWidget);
    // No price is invented anywhere on the card.
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('speech heard and failed steps only appear when they happened', (tester) async {
    await tester.pumpWidget(_app(UsageSummary(report: _report(heard: 9000, failed: 2))));
    expect(find.text('9 s of speech heard'), findsOneWidget);
    expect(find.text('2 steps failed'), findsOneWidget);

    await tester.pumpWidget(_app(UsageSummary(report: _report())));
    expect(find.text('9 s of speech heard'), findsNothing);
    expect(find.text('2 steps failed'), findsNothing);
  });

  testWidgets('an empty ledger says nothing is counted yet instead of showing zeroes', (tester) async {
    await tester.pumpWidget(_app(UsageSummary(report: _report(steps: 0, prompt: 0, completion: 0, ms: 0))));

    expect(find.textContaining('Nothing counted in this window yet'), findsOneWidget);
    expect(find.textContaining('groq · openai/gpt-oss-20b'), findsNothing);
  });
}
