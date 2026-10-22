import 'dart:async';

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const words = 'Revenue is up twelve percent last quarter';

/// Core's report of the tap: the words it read off the app when Ctrl+Alt was pressed.
void offer(StreamController<Map<String, dynamic>> events) => events.add({
  'type': 'voice_buddy',
  'state': 'selected',
  'text': words,
  'words': 7,
  'window': 'Report - Word',
  'cursor': [300, 200],
});

void main() {
  testWidgets('a tap with words highlighted: the exact words and taps for what to do with them', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    var mouse = const Offset(300, 200);
    final asked = <String>[];
    final through = <bool>[];
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: BuddyLayer(
          events: events.stream,
          cursor: () async => mouse,
          onSelect: (instruction) async => asked.add(instruction),
          setClickThrough: (t) async => through.add(t),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    offer(events);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('“$words”'), findsOneWidget);
    expect(find.text('7 words selected in Report - Word — tap what to do'), findsOneWidget);
    for (final tap in ['Explain', 'Summarise', 'Translate', 'Look it up']) {
      expect(find.text(tap), findsOneWidget);
    }
    expect(find.text('Or hold Ctrl+Alt and just say it.'), findsOneWidget);
    expect(through, isEmpty); // still click-through: the mouse isn't on the card

    // Move onto the card: only then does it take the mouse, and the card holds still.
    final summarise = tester.getCenter(find.text('Summarise'));
    mouse = summarise;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.getCenter(find.text('Summarise')), summarise);
    expect(through, [false]);

    await tester.tap(find.text('Summarise'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(asked, ['Summarise this']);
    expect(find.text('Summarise'), findsNothing); // the taps are gone once one is taken
    expect(find.text('Summarise this'), findsOneWidget); // and it says what it is doing
    expect(through.last, true); // clicks pass through again
    await tester.pump(const Duration(seconds: 21));
    await events.close();
  });

  testWidgets('hiding the buddy does not hide the words it is holding', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: BuddyLayer(
          events: events.stream,
          cursor: () async => const Offset(300, 200),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    events.add({'type': 'voice_buddy_visible', 'visible': false});
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Explain'), findsNothing);

    offer(events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('“$words”'), findsOneWidget);
    expect(find.text('Explain'), findsOneWidget);
    await events.close();
  });

  testWidgets('the offer goes away on its own, and a fresh press clears it', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: BuddyLayer(
          events: events.stream,
          cursor: () async => const Offset(300, 200),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    offer(events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Explain'), findsOneWidget);

    // Left alone, it stops offering rather than sitting over the app forever.
    await tester.pump(const Duration(seconds: 21));
    expect(find.text('Explain'), findsNothing);

    offer(events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('“$words”'), findsOneWidget);
    events.add({'type': 'voice_buddy', 'state': 'listening'});
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('“$words”'), findsNothing); // talking replaces the offer
    await events.close();
  });
}
