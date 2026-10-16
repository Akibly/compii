// Renders the pointing overlay over a mock desktop; with --dart-define=CAPTURE=true it saves a PNG.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/overlay/overlay_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('overlay points at the target and fades out', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
      final font = File('C:/Windows/Fonts/segoeui.ttf');
      if (font.existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await tester.runAsync(loader.load);
      }
    }
    tester.view.physicalSize = const Size(1000, 560);
    tester.view.devicePixelRatio = 1;
    final points = ValueNotifier<Map<String, dynamic>?>(null);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: key,
          child: Stack(
            children: [
              // A mock app window underneath, with a "Save" button at (300,120) on a 1.5x screen.
              Positioned.fill(child: Container(color: const Color(0xFFE9EEF5))),
              Positioned(
                left: 40,
                top: 40,
                right: 40,
                bottom: 40,
                child: Container(
                  color: Colors.white,
                  child: const Align(
                    alignment: Alignment(-.42, -.68),
                    child: SizedBox(
                      width: 80,
                      height: 32,
                      child: Material(
                        color: Color(0xFF2B579A),
                        child: Center(child: Text('Save', style: TextStyle(color: Colors.white))),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: PointerLayer(points: points, scale: 1.5, showFor: const Duration(seconds: 2)),
              ),
            ],
          ),
        ),
      ),
    );
    final save = tester.getRect(find.ancestor(of: find.text('Save'), matching: find.byType(SizedBox)).first);
    // Core reports physical pixels (here 1.5x).
    points.value = {
      'type': 'point',
      'x': save.left * 1.5,
      'y': save.top * 1.5,
      'w': save.width * 1.5,
      'h': save.height * 1.5,
      'message': 'Click Save to keep your changes.',
    };
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);
    expect(find.text('Click Save to keep your changes.'), findsOneWidget);
    if (capture) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(boundary.toImage))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
      await tester.runAsync(() => File('${out.path}/desktop-pointing-overlay.png').writeAsBytes(bytes!.buffer.asUint8List()));
      image.dispose();
    }
    // It fades away on its own.
    await tester.pump(const Duration(seconds: 3));
    final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(fade.opacity, 0);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
