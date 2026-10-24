import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page Compii cites in its own answer has to be as reachable as the sources
/// listed under it — the user reads a name, and tapping it goes through Core.
class _Recorded extends CoreClient {
  final List<String> opened = [];

  @override
  Future<void> openUrl(String url) async => opened.add(url);
}

List<TextSpan> _walk(InlineSpan s) =>
    s is! TextSpan ? const [] : [s, for (final c in s.children ?? const <InlineSpan>[]) ..._walk(c)];

void main() {
  testWidgets('a cited page in the answer opens through Core', (tester) async {
    final core = _Recorded()
      ..bots = [BotView(id: 'bcompii', name: 'Compii', primary: true, trust: 'full', avatar: 'a1.orb.1')];
    final task = TaskView(id: 't1', request: 'What is the mileage rate?', status: 'done', botId: 'bcompii')
      ..events.addAll([
        {'type': 'task_started', 'at': 0, 'bot_id': 'bcompii'},
        {
          'type': 'task_finished',
          'status': 'done',
          'text': 'The current rate is on [the mileage page](https://example.com/mileage).',
          'at': 2,
          'bot_id': 'bcompii'
        },
      ]);

    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ThreadView(task: task, core: core, run: (f) => f())),
    ));
    await tester.pumpAndSettle();

    TextSpan? link;
    for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      final root = w.textSpan;
      if (root == null) continue;
      for (final s in _walk(root)) {
        if (s.text == 'the mileage page') link = s;
      }
    }
    expect(link, isNotNull, reason: 'the words Compii chose are on screen, not the markdown');
    expect(link!.recognizer, isNotNull);
    (link.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();
    expect(core.opened, ['https://example.com/mileage']);
  });
}
