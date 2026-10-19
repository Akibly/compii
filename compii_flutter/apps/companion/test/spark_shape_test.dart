import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/overlay/buddy_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('spark shape sheet', (tester) async {
    tester.view.physicalSize = const Size(600, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    Widget one(SparkPainter p) => Transform.scale(scale: 3.5, child: CustomPaint(size: const Size(34, 34), painter: p));
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: Container(
          color: const Color(0xFFF3F2EF),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            one(SparkPainter(t: 0, tint: const Color(0xFF6E8BFF), listening: false, thinking: false, level: 0, active: false)),
            one(SparkPainter(t: .3, tint: const Color(0xFF5CE1E6), listening: true, thinking: false, level: .6, active: true)),
            one(SparkPainter(t: .1, tint: const Color(0xFF6E8BFF), listening: false, thinking: true, level: 0, active: true)),
            one(SparkPainter(t: 0, tint: const Color(0xFFFF7D72), listening: false, thinking: false, level: 0, active: true, recording: true)),
          ]),
        ),
      ),
    ));
    if (!const bool.fromEnvironment('CAPTURE')) return;
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
    final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
    await tester.runAsync(() => File('../../../docs/compii/build-previews/v4/buddy-spark-sheet.png').writeAsBytes(bytes!.buffer.asUint8List()));
  });
}
