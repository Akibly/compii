import 'dart:async';

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('permission: Yes / No beside the cursor, clickable only while the mouse is over it', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    var mouse = const Offset(300, 200);
    final decided = <(String, bool)>[];
    final through = <bool>[];
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: BuddyLayer(
          events: events.stream,
          cursor: () async => mouse,
          onDecide: (id, ok) async => decided.add((id, ok)),
          setClickThrough: (t) async => through.add(t),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    events.add({'type': 'voice_buddy', 'state': 'needs_you', 'approval_id': 'a1', 'text': 'Move holiday.jpg to Photos?'});
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Move holiday.jpg to Photos?'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(through, isEmpty); // still click-through: the mouse isn't on the card

    // The card stays where it appeared while the mouse moves onto it.
    final yes = tester.getCenter(find.text('Yes'));
    mouse = yes;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.getCenter(find.text('Yes')), yes);
    expect(through, [false]); // now it catches clicks

    await tester.tap(find.text('Yes'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(decided, [('a1', true)]);
    expect(through.last, true); // clicks pass through again
    expect(find.text('Yes'), findsNothing);
    await tester.pump(const Duration(seconds: 13));
  });

  testWidgets('a question: one button per choice, plus “you decide”, answered from beside the cursor', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    var mouse = const Offset(300, 200);
    final answers = <(String, String)>[];
    final through = <bool>[];
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: BuddyLayer(
          events: events.stream,
          cursor: () async => mouse,
          onAnswer: (id, text) async => answers.add((id, text)),
          setClickThrough: (t) async => through.add(t),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    events.add({
      'type': 'voice_buddy', 'state': 'needs_you', 'question_id': 'q1',
      'text': 'Which scholarship should I open?',
      'choices': ['Nexus', 'Horizon'],
    });
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Which scholarship should I open?'), findsOneWidget);
    expect(find.text('Nexus'), findsOneWidget);
    expect(find.text('Horizon'), findsOneWidget);
    expect(find.text('You decide'), findsOneWidget);

    final tap = tester.getCenter(find.text('Horizon'));
    mouse = tap;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(through, [false]); // clickable only once the mouse is over the card
    await tester.tap(find.text('Horizon'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(answers, [('q1', 'Horizon')]);
    expect(find.text('Which scholarship should I open?'), findsNothing, reason: 'the card goes away');
    expect(find.text('You decide'), findsNothing);
    expect(through.last, true);
    await tester.pump(const Duration(seconds: 13));
  });

  testWidgets('hold Ctrl+Alt and drag to draw: the overlay takes the mouse only while you talk', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final through = <bool>[];
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: BuddyLayer(events: events.stream, cursor: () async => const Offset(300, 200),
            setClickThrough: (t) async => through.add(t)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    events.add({'type': 'voice_buddy', 'state': 'listening'});
    await tester.pump(const Duration(milliseconds: 50));
    expect(through, [false]); // catching the mouse to draw
    final g = await tester.startGesture(const Offset(400, 250));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(Offset(400 + 10.0 * i, 250 + 5.0 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    final state = tester.state<BuddyLayerState>(find.byType(BuddyLayer));
    expect(state.inkStrokes, 1);
    events.add({'type': 'voice_buddy', 'state': 'thinking', 'heard': 'what is this'});
    await tester.pump(const Duration(milliseconds: 50));
    expect(through.last, true); // let go of Ctrl+Alt: clicks pass through again
    await tester.pump(const Duration(seconds: 13));
  });
}
