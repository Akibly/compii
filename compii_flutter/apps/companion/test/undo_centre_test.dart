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

final _now = DateTime.now().millisecondsSinceEpoch / 1000.0;

Map<String, dynamic> _moved({String id = 'e111'}) => {
  'id': id,
  'task_id': 't1',
  'tool': 'move_file',
  'kind': 'change',
  'summary': 'Moved report.txt to Archive',
  'at': _now - 600,
  'about': 'File my reports',
  'what': {'op': 'move', 'src': r'C:\Downloads\report.txt', 'dst': r'C:\Documents\Archive\report.txt'},
};

Map<String, dynamic> _made({String id = 'e222'}) => {
  'id': id,
  'task_id': 't2',
  'tool': 'write_text_file',
  'kind': 'create',
  'summary': 'Wrote draft.md',
  'at': _now - 90,
  'about': 'Write me a covering letter',
  'what': {'op': 'created', 'path': r'C:\Documents\draft.md'},
};

void main() {
  testWidgets('each change says what it was, when, and what putting it back means', (tester) async {
    late Map<String, dynamic> tapped;
    await tester.pumpWidget(_app(
      UndoCentre(actions: [_moved(), _made()], onUndo: (a) async => tapped = a),
    ));

    expect(find.text('Put things back'), findsOneWidget);
    expect(find.textContaining('only the last change of each conversation'), findsOneWidget);
    expect(find.text('Moved report.txt to Archive'), findsOneWidget);
    expect(find.textContaining('asked as “File my reports”'), findsOneWidget);
    expect(find.text('Move it back'), findsOneWidget);
    expect(find.text('Remove it'), findsOneWidget, reason: 'a file Compii made goes away again');

    await tester.tap(find.text('Move it back'));
    await tester.pump();
    expect(tapped['id'], 'e111');
  });

  testWidgets('while one is being put back nothing else can be clicked', (tester) async {
    await tester.pumpWidget(_app(
      UndoCentre(actions: [_moved(), _made()], busyId: 'e222', onUndo: (_) async {}),
    ));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Move it back')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Remove it')).onPressed, isNull);
  });

  testWidgets('a change from an earlier day is dated, not called Today', (tester) async {
    final old = _moved(id: 'e333')..['at'] = _now - 3 * 86400;
    await tester.pumpWidget(_app(UndoCentre(actions: [old], onUndo: (_) async {})));

    expect(find.textContaining('asked as'), findsOneWidget);
    expect(find.textContaining('Today'), findsNothing);
  });
}
