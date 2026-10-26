// The cursor companion's pieces: Compii's eyes in every state, the halo around the
// pointer and the spotlight. With --dart-define=CAPTURE=true it saves a sheet.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/art/halo.dart';
import 'package:compii/src/console/character.dart' show Mood;
import 'package:compii/src/overlay/halo_cursor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every buddy state wears a mood, and an answer only smiles once it stops talking', () {
    expect(moodForBuddy('listening'), Mood.listening);
    expect(moodForBuddy('thinking'), Mood.thinking);
    expect(moodForBuddy('needs_you'), Mood.waiting);
    expect(moodForBuddy('error'), Mood.problem);
    expect(moodForBuddy('answer', speaking: true), Mood.speaking);
    expect(moodForBuddy('answer'), Mood.happy);
    expect(moodForBuddy('anything else'), Mood.idle);
  });

  testWidgets('the cursor pieces paint in every state', (tester) async {
    tester.view.physicalSize = const Size(1100, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    Widget mark(String state) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(88, 88),
          painter: CursorMarkPainter(
            mood: moodForBuddy(state),
            color: state == 'needs_you' ? const Color(0xFFFF9B3D) : haloBlue,
            t: .3,
            engaged: state != 'idle',
            level: state == 'listening' ? .7 : 0,
            gaze: const Offset(-.7, -.7),
          ),
        ),
        Text(state, style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
      ],
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFFF3F2EF),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final s in ['idle', 'listening', 'thinking', 'needs_you', 'answer', 'error']) mark(s),
                const CustomPaint(
                  size: Size(80, 80),
                  painter: _Ring(),
                ),
                SizedBox(
                  width: 160,
                  height: 120,
                  child: CustomPaint(
                    painter: SpotlightPainter(
                      target: const Rect.fromLTWH(50, 45, 60, 26),
                      color: haloBlue,
                      progress: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews/halo')..createSync(recursive: true);
      await tester.runAsync(() => File('${out.path}/cursor-pieces.png').writeAsBytes(bytes!.buffer.asUint8List()));
    }
  });
}

class _Ring extends CustomPainter {
  const _Ring();
  @override
  void paint(Canvas canvas, Size size) =>
      CursorRingPainter(color: haloBlue, t: .3, level: .6).paint(canvas, size);
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
