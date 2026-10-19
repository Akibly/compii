import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the cursor buddy trails the pointer, listens, answers and flies to what it points at', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
      final loader = FontLoader('Segoe UI Variable Text');
      final f = File('C:/Windows/Fonts/SegUIVar.ttf');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
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
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Stack(children: [
            // Stands in for whatever app is on screen.
            Positioned.fill(child: Container(color: const Color(0xFFF3F2EF))),
            Positioned(left: 560, top: 300, width: 90, height: 30,
                child: Container(color: const Color(0xFFDDE3EE), alignment: Alignment.center,
                    child: const Text('Table', style: TextStyle(fontSize: 13, color: Color(0xFF333333))))),
            Positioned.fill(child: BuddyLayer(events: events.stream, points: points, cursor: () async => mouse)),
          ]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    Offset buddy() => tester.getCenter(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is SparkPainter));
    expect((buddy() - (mouse + const Offset(14, 16))).distance, lessThan(2), reason: 'sits right beside the pointer');

    mouse = const Offset(420, 260);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect((buddy() - (mouse + const Offset(14, 16))).distance, lessThan(3), reason: 'smoothly follows the mouse');

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 60));
      if (!capture) return;
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews/v4')..createSync(recursive: true);
      await tester.runAsync(() => File('${out.path}/buddy-$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
    }

    await shot('idle');
    events.add({'type': 'voice_buddy', 'state': 'listening'});
    await tester.pump();
    events.add({'type': 'voice_partial', 'text': 'how do I add a table here'});
    await tester.pump();
    await tester.pump();
    expect(find.text('how do I add a table here'), findsOneWidget);
    await shot('listening');

    events.add({'type': 'voice_buddy', 'state': 'thinking', 'heard': 'how do I add a table here'});
    await tester.pump();
    await tester.pump();
    await shot('thinking');

    events.add({'type': 'voice_buddy', 'state': 'answer', 'text': 'Open Insert, then click Table.'});
    points.value = {'x': 560, 'y': 300, 'w': 90, 'h': 30, 'message': 'Click Table'};
    await tester.pump();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Click Table'), findsOneWidget);
    expect(buddy().dx, greaterThan(600), reason: 'flew to the item');
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
  });
}
