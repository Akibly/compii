import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/clips.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClipsCore extends CoreClient {
  FakeClipsCore(this._status, {this.clips = const [], this.snips = const []});
  final Map<String, dynamic> _status;
  final List<Map<String, dynamic>> clips;
  final List<Map<String, dynamic>> snips;
  int copied = 0;

  @override
  Future<Map<String, dynamic>> clipsStatus() async => _status;

  @override
  Future<List<Map<String, dynamic>>> clipItems({String q = '', int limit = 100, bool? pinned}) async =>
      [for (final c in clips) if (q.isEmpty || '${c['preview']}'.toLowerCase().contains(q.toLowerCase())) c];

  @override
  Future<List<Map<String, dynamic>>> snippets({String q = ''}) async => snips;

  @override
  Future<void> copyClip(int id) async => copied += 1;
}

Map<String, dynamic> status({bool on = false, int items = 0, int pinned = 0, int snippets = 0}) => {
      'enabled': on,
      'items': items,
      'pinned': pinned,
      'snippets': snippets,
      'keep_days': 7.0,
      'max_items': 500,
      'megabytes': 0.2,
    };

void main() {
  Future<void> run(Future<void> Function() f) => f();

  testWidgets('off: explains the privacy, offers the switch, and shows no list', (tester) async {
    final core = FakeClipsCore(status());
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ClipsPage(core: core, run: run)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Clipboard history is off'), findsOneWidget);
    expect(find.text('Turn on clipboard history'), findsOneWidget);
    expect(find.text('Password managers skipped'), findsOneWidget);
    expect(find.text('Recent copies'), findsNothing);
  });

  testWidgets('on: shows copies, pins, and can copy one again', (tester) async {
    final core = FakeClipsCore(
      status(on: true, items: 2, pinned: 1),
      clips: [
        {
          'id': 1, 'preview': 'https://example.com/pay', 'chars': 23, 'kind': 'link',
          'app': 'chrome.exe', 'title': 'Pay', 'at': DateTime.now().millisecondsSinceEpoch / 1000,
          'copies': 2, 'pinned': true,
        },
        {
          'id': 2, 'preview': '12 Market Street', 'chars': 16, 'kind': 'text',
          'app': 'notepad.exe', 'title': 'Address', 'at': DateTime.now().millisecondsSinceEpoch / 1000,
          'copies': 1, 'pinned': false,
        },
      ],
    );
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ClipsPage(core: core, run: run)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Remembering copies'), findsOneWidget);
    expect(find.text('https://example.com/pay'), findsOneWidget);
    expect(find.text('Pinned'), findsOneWidget);

    // The callback directly: tapping would load Flutter's ink-sparkle shader, which this
    // SDK can't verify in tests (the same environmental failure as phone_home_test).
    final copyButton = tester.widget<IconButton>(find.ancestor(
      of: find.byTooltip('Copy again').first,
      matching: find.byType(IconButton),
    ).first);
    copyButton.onPressed!();
    await tester.pumpAndSettle();
    expect(core.copied, 1);
    expect(find.textContaining('press Ctrl+V'), findsOneWidget);
  });

  testWidgets('snippets tab lists the saved names and their use', (tester) async {
    final core = FakeClipsCore(
      status(on: true, snippets: 1),
      snips: [
        {
          'id': 'n1', 'name': 'Work signature', 'body': 'Regards,\nSam',
          'created': 0.0, 'uses': 2, 'last_used': null,
        },
      ],
    );
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: ClipsPage(core: core, run: run)),
    ));
    await tester.pumpAndSettle();
    // Called directly: a tap would load Flutter's ink-sparkle shader, which this
    // SDK can't verify in tests (the same environmental failure as phone_home_test).
    final segmented = tester.widget(find.byWidgetPredicate((w) => w is SegmentedButton)) as dynamic;
    final next = segmented.selected as Set;
    next
      ..clear()
      ..add(segmented.segments[1].value);
    segmented.onSelectionChanged(next);
    await tester.pumpAndSettle();
    expect(find.text('Work signature'), findsOneWidget);
    expect(find.textContaining('used 2×'), findsOneWidget);
    expect(find.text('New snippet'), findsOneWidget);
  });
}
