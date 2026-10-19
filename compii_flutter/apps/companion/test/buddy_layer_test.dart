import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the cursor buddy listens, thinks and answers beside the pointer', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
      final loader = FontLoader('Segoe UI Variable Text');
      final f = File('C:/Windows/Fonts/SegUIVar.ttf');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await tester.runAsync(loader.load);
    }
    tester.view.physicalSize = const Size(460, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final placed = <Offset>[];
    final key = GlobalKey();
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(460, 360), disableAnimations: true),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFFE9E6E0), // stands in for whatever app is behind
            child: BuddyLayer(
              events: events.stream,
              cursor: () async => const Offset(300, 200),
              window: const Size(460, 360),
              screen: const Size(1920, 1080),
              onPlace: (o) async => placed.add(o),
            ),
          ),
        ),
      ),
    ));
    expect(find.text('Listening…'), findsNothing, reason: 'nothing shows until you hold the keys');

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 100));
      if (!capture) return;
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews/v4')..createSync(recursive: true);
      await tester.runAsync(() => File('${out.path}/buddy-$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
    }

    events.add({'type': 'voice_buddy', 'state': 'listening'});
    await tester.pump();
    events.add({'type': 'voice_partial', 'text': 'how do I add a table here'});
    await tester.pump();
    expect(find.text('how do I add a table here'), findsOneWidget);
    expect(placed.last, const Offset(314, 216), reason: 'sits just below-right of the pointer');
    await shot('listening');

    events.add({'type': 'voice_buddy', 'state': 'thinking', 'heard': 'how do I add a table here'});
    await tester.pump();
    await tester.pump();
    expect(find.text('“how do I add a table here”'), findsOneWidget);
    await shot('thinking');

    events.add({'type': 'voice_buddy', 'state': 'answer', 'text': 'Open the Insert tab, then click Table — I’m pointing at it.'});
    await tester.pump();
    expect(find.textContaining('Insert tab'), findsOneWidget);
    await shot('answer');

    events.add({'type': 'voice_buddy', 'state': 'idle'});
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Insert tab'), findsNothing);
    await events.close();
  });
}
