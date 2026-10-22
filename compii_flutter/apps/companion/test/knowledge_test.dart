import 'package:compii/src/ui/knowledge.dart';
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

Map<String, dynamic> _folder({bool exists = true}) => {
      'path': r'C:\Users\me\Documents\Acme',
      'name': 'Acme',
      'files': 12,
      'chars': 24000,
      'updated': DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch / 1000,
      'exists': exists,
    };

void main() {
  testWidgets('a folder shows what is indexed and its two actions', (tester) async {
    var refreshed = 0;
    var removed = 0;
    await tester.pumpWidget(_app(KnowledgeFolderCard(
      folder: _folder(),
      onRefresh: () => refreshed++,
      onRemove: () => removed++,
    )));

    expect(find.text('Acme'), findsOneWidget);
    expect(find.text(r'C:\Users\me\Documents\Acme'), findsOneWidget);
    expect(find.textContaining('12 files'), findsOneWidget);
    expect(find.textContaining('24k characters'), findsOneWidget);
    expect(find.textContaining('refreshed 2 h ago'), findsOneWidget);

    await tester.tap(find.text('Refresh'));
    await tester.tap(find.byTooltip('Remove from Knowledge'));
    expect(refreshed, 1);
    expect(removed, 1);
  });

  testWidgets('a folder that moved says so plainly', (tester) async {
    await tester.pumpWidget(_app(KnowledgeFolderCard(
      folder: _folder(exists: false),
      onRefresh: () {},
      onRemove: () {},
    )));
    expect(find.textContaining('no longer there'), findsOneWidget);
  });

  testWidgets('a hit shows the file it came from and copies the path', (tester) async {
    var copied = 0;
    await tester.pumpWidget(_app(KnowledgeHitCard(
      hit: {
        'path': r'C:\Users\me\Documents\Acme\contract.md',
        'title': 'Acme services agreement',
        'part': 2,
        'excerpt': 'The [cancellation] deadline is 30 days before renewal.',
      },
      onCopy: () => copied++,
    )));

    expect(find.text('Acme services agreement'), findsOneWidget);
    expect(find.text(r'C:\Users\me\Documents\Acme\contract.md'), findsOneWidget);
    expect(find.textContaining('30 days'), findsOneWidget);
    expect(find.text('part 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy file path'));
    expect(copied, 1);
  });
}
