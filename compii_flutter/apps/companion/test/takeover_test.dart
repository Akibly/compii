import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTakeoverCore extends CoreClient {
  final calls = <(String, String)>[];

  @override
  Future<void> finishTakeover(String takeoverId, {String outcome = 'done'}) async =>
      calls.add((takeoverId, outcome));
}

Map<String, dynamic> event({String what = 'Type your password in the sign-in window.'}) => {
      'type': 'takeover',
      'takeover_id': 'k1',
      'what': what,
      'fields': [
        {'label': 'Password', 'kind': 'secret'},
        {'label': 'One-time code', 'kind': 'secret'},
      ],
      'url': 'https://example.com/login',
    };

Future<void> run(Future<void> Function() f) => f();

Widget host(Widget child) => MaterialApp(theme: compiiTheme(Brightness.light), home: Scaffold(body: child));

void main() {
  testWidgets('a secret step names the fields, promises privacy, and hands back on demand', (tester) async {
    final core = FakeTakeoverCore();
    await tester.pumpWidget(host(TakeoverCard(event: event(), core: core, run: run)));
    await tester.pumpAndSettle();

    expect(find.text('Type your password in the sign-in window.'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('One-time code'), findsOneWidget);
    expect(find.textContaining('example.com'), findsOneWidget);
    expect(find.textContaining('never sees or keeps'), findsOneWidget);
    expect(find.text('Your turn'), findsOneWidget);

    // Called directly: a tap would load Flutter's ink-sparkle shader, which this
    // SDK can't verify in tests (the same environmental failure as phone_home_test).
    final button = tester.widget<FilledButton>(find.ancestor(
      of: find.text('I’ve done it — continue'),
      matching: find.byType(FilledButton),
    ));
    button.onPressed!();
    await tester.pumpAndSettle();

    expect(core.calls, [('k1', 'done')]);
    expect(find.text('Handed back — Compii is carrying on.'), findsOneWidget);
  });

  testWidgets('skipping is an honest choice with its own outcome', (tester) async {
    final core = FakeTakeoverCore();
    await tester.pumpWidget(host(TakeoverCard(event: event(), core: core, run: run)));
    await tester.pumpAndSettle();

    final skip = tester.widget<TextButton>(find.ancestor(
      of: find.text('Skip this step'),
      matching: find.byType(TextButton),
    ).first);
    skip.onPressed!();
    await tester.pumpAndSettle();

    expect(core.calls, [('k1', 'skip')]);
    expect(find.textContaining('Compii is carrying on without that step'), findsOneWidget);
  });
}
