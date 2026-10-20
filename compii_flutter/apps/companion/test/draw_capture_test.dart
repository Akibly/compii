import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Compii draws on screen: circle, underline, box and arrow', (tester) async {
    const size = Size(900, 520);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final key = GlobalKey();
    Widget item(double l, double t, String label) => Positioned(left: l, top: t, width: 90, height: 30,
        child: Container(color: const Color(0xFFDDE3EE), alignment: Alignment.center,
            child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF333333)))));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Stack(children: [
            Positioned.fill(child: Container(color: const Color(0xFFF3F2EF))),
            item(120, 120, 'Add'), item(120, 300, 'Mesh'), item(520, 120, 'Cube'), item(520, 300, 'Render'),
            Positioned.fill(child: BuddyLayer(events: events.stream, cursor: () async => const Offset(700, 450))),
          ]),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    Map<String, dynamic> at(String kind, double x, double y, [Map<String, dynamic>? from]) =>
        {'kind': kind, 'x': x, 'y': y, 'w': 90, 'h': 30, 'from': ?from};
    events.add({'type': 'voice_draw', 'message': '', 'shapes': [
      at('circle', 120, 120),
      at('arrow', 120, 300, {'x': 120, 'y': 120, 'w': 90, 'h': 30}),
      at('underline', 520, 120),
      at('box', 520, 300),
    ]});
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 2400)); // drawn
    expect(find.byType(BuddyLayer), findsOneWidget);
    if (const bool.fromEnvironment('CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      await tester.runAsync(() => File('../../../docs/compii/build-previews/v4/compii-draws.png')
          .writeAsBytes(bytes!.buffer.asUint8List()));
    }
    await tester.pump(const Duration(seconds: 13));
  });
}
