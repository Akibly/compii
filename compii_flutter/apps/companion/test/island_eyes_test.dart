// The island's eyes wear the island's real state, follow nothing they cannot
// see, and keep still under reduced motion. With --dart-define=CAPTURE=true it
// also saves a sheet of the eyes in every state for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/art/halo.dart';
import 'package:compii/src/console/character.dart' show compiiColor;
import 'package:compii/src/island/island_controller.dart';
import 'package:compii/src/island/island_eyes.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool still = false}) => MaterialApp(
  theme: compiiTheme(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: still),
    child: Scaffold(backgroundColor: Colors.black, body: Center(child: child)),
  ),
);

void main() {
  tearDown(() => compiiColor.value = haloBlue);

  testWidgets('every island state is worn by the eyes without a hitch', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(_host(
      RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: Colors.black,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 28,
              runSpacing: 20,
              children: [
                for (final s in IslandSignal.values)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IslandEyes(signal: s, size: 40),
                      const SizedBox(height: 6),
                      Text(s.name, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IslandEyes(signal: IslandSignal.listening, size: 40, listening: true, level: .9),
                    SizedBox(height: 6),
                    Text('loud voice', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Compii'), findsNWidgets(IslandSignal.values.length + 1));

    if (const bool.fromEnvironment('CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
      await tester.runAsync(
        () => File('${out.path}/compii-island-eyes.png').writeAsBytes(bytes!.buffer.asUint8List()),
      );
      image.dispose();
    }
  });

  testWidgets('the eyes take Compii\'s chosen colour as soon as it changes', (tester) async {
    await tester.pumpWidget(_host(const IslandEyes(signal: IslandSignal.none, size: 30), still: true));
    final painter = tester.widget<CustomPaint>(
      find.descendant(of: find.byType(IslandEyes), matching: find.byType(CustomPaint)),
    ).painter!;
    compiiColor.value = const Color(0xFFFF6FAE);
    await tester.pump(const Duration(milliseconds: 400));
    final after = tester.widget<CustomPaint>(
      find.descendant(of: find.byType(IslandEyes), matching: find.byType(CustomPaint)),
    ).painter!;
    expect(after.shouldRepaint(painter), isTrue);
  });

  testWidgets('with reduced motion nothing is scheduled: no blinking, no wandering', (tester) async {
    await tester.pumpWidget(_host(const IslandEyes(signal: IslandSignal.working, size: 30), still: true));
    await tester.pump();
    // A pending blink or pointer poll would show up here as a live timer.
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
