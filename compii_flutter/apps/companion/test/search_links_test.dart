import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/clips.dart';
import 'package:compii/src/ui/pages.dart';
import 'package:compii/src/ui/timeline.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeLinksCore extends CoreClient {
  FakeLinksCore({this.facts = const [], this.clips = const [], this.snips = const []});

  final List<Map<String, dynamic>> facts;
  final List<Map<String, dynamic>> clips;
  final List<Map<String, dynamic>> snips;
  String? lastClipQuery;
  String? lastSnippetQuery;
  String? lastMomentQuery;
  double? lastMomentAfter;

  @override
  Future<List<Map<String, dynamic>>> memories() async => facts;

  @override
  Future<Map<String, dynamic>> clipsStatus() async => {
        'enabled': true,
        'items': clips.length,
        'pinned': 0,
        'snippets': snips.length,
        'keep_days': 7.0,
        'max_items': 500,
        'megabytes': 0.2,
      };

  @override
  Future<List<Map<String, dynamic>>> clipItems({String q = '', int limit = 100, bool? pinned}) async {
    lastClipQuery = q;
    return [
      for (final c in clips)
        if (q.isEmpty || '${c['preview']}'.toLowerCase().contains(q.toLowerCase())) c
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> snippets({String q = ''}) async {
    lastSnippetQuery = q;
    return [
      for (final s in snips)
        if (q.isEmpty ||
            '${s['name']}'.toLowerCase().contains(q.toLowerCase()) ||
            '${s['body']}'.toLowerCase().contains(q.toLowerCase()))
          s
    ];
  }

  @override
  Future<Map<String, dynamic>> timelineStatus() async => {
        'enabled': true,
        'paused': false,
        'reason': '',
        'ocr': 'ok',
        'moments': 1,
        'oldest': null,
        'newest': null,
        'megabytes': 0.1,
        'every_seconds': 30,
        'keep_days': 3.0,
        'pictures': true,
      };

  @override
  Future<List<Map<String, dynamic>>> timelineMoments(
      {String q = '', double? after, double? before, String app = '', int limit = 60, bool full = true}) async {
    lastMomentQuery = q;
    lastMomentAfter = after;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return [
      {
        'id': 7,
        'started': now - 120,
        'ended': now - 90,
        'app': 'chrome.exe',
        'title': 'Invoice - Acme',
        'excerpt': 'Total due 120',
        'text': 'Invoice total due 120',
        'has_picture': false,
      },
    ];
  }
}

Future<void> run(Future<void> Function() f) => f();

Widget host(Widget page) => MaterialApp(theme: compiiTheme(Brightness.light), home: Scaffold(body: page));

void main() {
  testWidgets('a memory from search is called out on the memory page', (tester) async {
    final core = FakeLinksCore(facts: [
      {'id': 1, 'fact': 'Prefers short replies', 'at': null},
      {'id': 2, 'fact': 'Works in Berlin', 'at': null},
    ]);
    await tester.pumpWidget(host(MemoryPage(core: core, run: run, focusId: '2')));
    await tester.pumpAndSettle();

    ListTile tileOf(String fact) => tester.widget<ListTile>(
        find.ancestor(of: find.text(fact), matching: find.byType(ListTile)));

    expect(tileOf('Works in Berlin').tileColor, isNotNull);
    expect(tileOf('Prefers short replies').tileColor, isNull);
  });

  testWidgets('a clip from search lands in history with the words already filtered', (tester) async {
    final core = FakeLinksCore(clips: [
      {
        'id': 1, 'preview': 'https://example.com/invoice', 'chars': 27, 'kind': 'link',
        'app': 'chrome.exe', 'title': 'Invoice', 'at': 0.0, 'copies': 1, 'pinned': false,
      },
      {
        'id': 2, 'preview': '12 Market Street', 'chars': 16, 'kind': 'text',
        'app': 'notepad.exe', 'title': 'Address', 'at': 0.0, 'copies': 1, 'pinned': false,
      },
    ]);
    await tester.pumpWidget(host(ClipsPage(core: core, run: run, focusQuery: 'invoice')));
    await tester.pumpAndSettle();

    expect(core.lastClipQuery, 'invoice');
    expect(find.text('https://example.com/invoice'), findsOneWidget);
    expect(find.text('12 Market Street'), findsNothing);
    expect(find.text('invoice'), findsOneWidget); // the search field itself
  });

  testWidgets('a snippet from search opens the snippets tab, not history', (tester) async {
    final core = FakeLinksCore(
      clips: [
        {
          'id': 1, 'preview': 'hello invoice', 'chars': 13, 'kind': 'text',
          'app': 'notepad.exe', 'title': 'Note', 'at': 0.0, 'copies': 1, 'pinned': false,
        },
      ],
      snips: [
        {'id': 'n1', 'name': 'Work signature', 'body': 'Regards,\nSam', 'created': 0.0, 'uses': 2, 'last_used': null},
      ],
    );
    await tester.pumpWidget(host(ClipsPage(core: core, run: run, focusQuery: 'signature', focusSnippets: true)));
    await tester.pumpAndSettle();

    expect(core.lastSnippetQuery, 'signature');
    expect(core.lastClipQuery, isNull);
    expect(find.text('Work signature'), findsOneWidget);
    expect(find.text('hello invoice'), findsNothing);
  });

  testWidgets('a screen moment from search looks across all time', (tester) async {
    final core = FakeLinksCore();
    await tester.pumpWidget(host(TimelinePage(core: core, run: run, focusQuery: 'invoice')));
    await tester.pumpAndSettle();

    expect(core.lastMomentQuery, 'invoice');
    expect(core.lastMomentAfter, isNull);
    expect(find.text('Invoice - Acme'), findsOneWidget);
    expect(find.text('invoice'), findsOneWidget); // the search field itself
  });
}
