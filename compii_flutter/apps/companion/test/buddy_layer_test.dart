import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:compii/src/overlay/halo_cursor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'the eyes stay on the pointer while Compii works, and a long answer opens beside '
    'the cursor, outcome first, and stays put while you read',
    (tester) async {
      const size = Size(1400, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final events = StreamController<Map<String, dynamic>>.broadcast();
      var mouse = const Offset(200, 200);
      final key = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: size),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: key,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(color: const Color(0xFFF3F2EF)),
                  ),
                  Positioned(
                    left: 200,
                    top: 380,
                    width: 620,
                    height: 220,
                    child: Container(
                      color: Colors.white,
                      alignment: Alignment.topLeft,
                      padding: const EdgeInsets.all(14),
                      child: const Text(
                        'Quarterly numbers\nRevenue grew 18 per cent in the second '
                        'quarter, mostly from the two new regions, and the margin '
                        'held at 41 per cent.',
                        style: TextStyle(
                          fontSize: 15,
                          color: Color(0xFF222222),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: BuddyLayer(
                      events: events.stream,
                      cursor: () async => mouse,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      const capture = bool.fromEnvironment('CAPTURE');
      Future<void> shot(String name) async {
        await tester.pump(const Duration(milliseconds: 60));
        if (!capture) return;
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1),
        ))!;
        final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        );
        final out = Directory('../../../docs/compii/build-previews/halo')
          ..createSync(recursive: true);
        await tester.runAsync(
          () => File(
            '${out.path}/dock-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List()),
        );
      }

      await tester.pump(const Duration(milliseconds: 100));
      BuddyLayerState state() =>
          tester.state<BuddyLayerState>(find.byType(BuddyLayer));
      // Idle: it rides the pointer.
      expect(
        (state().buddyPosition - mouse).distance,
        lessThan(48),
        reason: 'a free mark stays beside the cursor',
      );

      events.add({'type': 'voice_buddy', 'state': 'thinking', 'heard': 'do some work'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        (state().buddyPosition - mouse).distance,
        lessThan(48),
        reason: 'busy or not, the mark never leaves the pointer — only the words move',
      );

      mouse = const Offset(1050, 430);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        (state().buddyPosition - mouse).distance,
        lessThan(64),
        reason: 'the pointer still drags the mark along while Compii works',
      );

      // A researched answer: a wide card of its own, its first sentence the headline.
      const head =
          'Revenue grew 18 per cent in the second quarter, mostly from the two new '
          'regions, and the margin held at 41 per cent even after the shipping increase.';
      final long = '$head ${'$head ' * 2}'.trim();
      events.add({'type': 'voice_buddy', 'state': 'answer', 'text': long});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await shot('answer');
      expect(find.text(head), findsOneWidget, reason: 'the outcome leads, as its own headline');
      final rest = find.text(long.substring(head.length + 1));
      expect(rest, findsOneWidget, reason: 'and the detail follows under it');
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      final card = tester.getRect(rest);
      expect(card.width, greaterThan(300), reason: 'the card is wide enough for paragraphs');
      expect(card.right, lessThan(mouse.dx), reason: 'the pointer is on the right, so it opens to its left');
      expect(card.right, greaterThan(mouse.dx - 80), reason: 'but beside the cursor, not in a far corner');
      expect(card.top, greaterThan(mouse.dy), reason: 'and below the pointer, clear of what it is on');
      expect(
        (state().buddyPosition - mouse).distance,
        lessThan(64),
        reason: 'answering never sends the eyes off to a corner',
      );

      // Moving the mouse while you read does not drag the card along.
      mouse = const Offset(240, 300);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.getRect(rest).topLeft, card.topLeft, reason: 'the card is latched while it is up');
      expect(
        (state().buddyPosition - mouse).distance,
        lessThan(64),
        reason: 'and the eyes came to the new pointer anyway',
      );
      // All of it fits, so Compii does not claim a part of it is elsewhere.
      expect(find.text('The full answer is in Compii'), findsNothing);

      // Longer than the card can hold: then, and only then, the note appears.
      final huge = '$long ' * 24;
      events.add({'type': 'voice_buddy', 'state': 'answer', 'text': huge});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('The full answer is in Compii'), findsOneWidget);
      final cut = tester.getSize(find.text(huge.trim().substring(head.length + 1)));
      expect(
        cut.height,
        allOf(greaterThan(card.height), lessThan(900 * .5)),
        reason: 'it fills the card and stops there, instead of running down the screen',
      );
      await shot('truncated');

      // Copy puts the whole answer on the clipboard, not just what fits.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, huge);
      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(find.text('Copy'), findsNothing, reason: 'Dismiss closes it');

      // Free again: it goes back to the pointer.
      events.add({'type': 'voice_buddy', 'state': 'idle', 'text': ''});
      await tester.pump();
      mouse = const Offset(300, 600);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        (state().buddyPosition - mouse).distance,
        lessThan(48),
        reason: 'an idle mark rides the cursor again',
      );
      await events.close();
    },
  );

  testWidgets(
    'the eyes ride beside the pointer without covering it, listen, answer, and spotlight what they show you',
    (tester) async {
      const capture = bool.fromEnvironment('CAPTURE');
      if (capture) {
        final loader = FontLoader('Segoe UI Variable Text');
        final f = File('C:/Windows/Fonts/SegUIVar.ttf');
        if (f.existsSync()) {
          loader.addFont(
            Future.value(ByteData.sublistView(f.readAsBytesSync())),
          );
        }
        await tester.runAsync(loader.load);
      }
      const size = Size(900, 520);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final points = ValueNotifier<Map<String, dynamic>?>(null);
      var mouse = const Offset(300, 200);
      final key = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: size),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: key,
              child: Stack(
                children: [
                  // Stands in for whatever app is on screen.
                  Positioned.fill(
                    child: Container(color: const Color(0xFFF3F2EF)),
                  ),
                  Positioned(
                    left: 560,
                    top: 300,
                    width: 90,
                    height: 30,
                    child: Container(
                      color: const Color(0xFFDDE3EE),
                      alignment: Alignment.center,
                      child: const Text(
                        'Table',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF333333),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: BuddyLayer(
                      events: events.stream,
                      points: points,
                      cursor: () async => mouse,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      Offset buddy() => tester.getCenter(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is CursorMarkPainter,
        ),
      );
      BuddyLayerState buddyState() =>
          tester.state<BuddyLayerState>(find.byType(BuddyLayer));
      final parked = buddy() - mouse;
      expect(
        parked.distance,
        inInclusiveRange(22, 44),
        reason: 'parked clear of the pixel you point at, still obviously yours',
      );
      expect(parked.dx, greaterThan(0), reason: 'to the right of the pointer');
      expect(parked.dy, greaterThan(0), reason: 'and below it, the reading side');

      // Nothing revolves: a mark that moves in front of text is unreadable, so it holds
      // its place while the pointer rests and only the light breathes.
      final firstRest = buddy();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        (buddy() - firstRest).distance,
        lessThan(1),
        reason: 'it stays put instead of orbiting',
      );

      mouse = const Offset(420, 260);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        (buddy() - mouse).distance,
        lessThan(44),
        reason: 'the badge follows the mouse',
      );

      // Near an edge it moves to the other shoulder rather than falling off screen.
      mouse = const Offset(888, 512);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final edge = buddy();
      expect(edge.dx, lessThan(mouse.dx), reason: 'flipped left of the pointer');
      expect(edge.dy, lessThan(mouse.dy), reason: 'and above it');
      expect(edge.dx, greaterThan(10), reason: 'still on the screen');
      expect(edge.dy, greaterThan(10), reason: 'and clear of the edge');

      mouse = const Offset(300, 200);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final home = buddy() - mouse;
      expect(
        home.dx,
        greaterThan(0),
        reason: 'it goes back to the reading side once the edge is behind you',
      );
      expect(home.dy, greaterThan(0), reason: 'and below the pointer again');

      Future<void> shot(String name) async {
        await tester.pump(const Duration(milliseconds: 60));
        if (!capture) return;
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: 2),
        ))!;
        final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        );
        final out = Directory('../../../docs/compii/build-previews/halo')
          ..createSync(recursive: true);
        await tester.runAsync(
          () => File(
            '${out.path}/buddy-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List()),
        );
      }

      await shot('idle');
      events.add({'type': 'voice_buddy', 'state': 'listening'});
      await tester.pump();
      events.add({
        'type': 'voice_partial',
        'text': 'how do I add a table here',
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('how do I add a table here'), findsOneWidget);
      expect(find.text('Listening'), findsOneWidget, reason: 'the card says what it is doing');
      expect(
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CursorRingPainter),
        findsOneWidget,
        reason: 'a halo rings the pointer while it listens',
      );
      await shot('listening');

      events.add({
        'type': 'voice_buddy',
        'state': 'thinking',
        'heard': 'how do I add a table here',
      });
      await tester.pump();
      await tester.pump();
      await shot('thinking');

      events.add({
        'type': 'voice_buddy',
        'state': 'answer',
        'text': 'Open Insert, then click Table.',
      });
      points.value = {
        'x': 560,
        'y': 300,
        'w': 90,
        'h': 30,
        'message': 'Click Table',
      };
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Click Table'), findsOneWidget);
      final state = buddyState();
      expect(
        state.isPointing,
        isTrue,
        reason: 'it flew to the item and settled',
      );
      expect(
        (state.buddyPosition - const Offset(605, 315)).distance,
        lessThan(130),
        reason: 'it really moves over to what it points at',
      );
      final wanted = math.atan2(
        315 - state.buddyPosition.dy,
        605 - state.buddyPosition.dx,
      );
      expect(
        (state.aimAngle - wanted).abs(),
        lessThan(.05),
        reason: 'its eyes look at the exact spot',
      );
      expect(state.pointingAt, isNotNull);
      expect(find.text('Showing you'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter is SpotlightPainter),
        findsOneWidget,
        reason: 'the screen dims around the one thing it is showing',
      );
      await shot('pointing');

      // The label closes by itself once Compii has finished talking.
      events.add({'type': 'voice_speaking', 'on': true});
      await tester.pump();
      events.add({'type': 'voice_speaking', 'on': false});
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Open Insert, then click Table.'), findsNothing);
      points.value = null;
      await events.close();
    },
  );
}
