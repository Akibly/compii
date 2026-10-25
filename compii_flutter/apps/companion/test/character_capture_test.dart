// Renders every mood and every body; with --dart-define=CAPTURE=true it also saves the character sheet for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/art/halo.dart';
import 'package:compii/src/console/character.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Compii is only ever seen in the dark of the app, so the sheet is the room it
/// lives in, not a page.
const _paper = Color(0xFF120E22);
const _ink = Color(0xFFF3EEE4);

class _Sheet extends StatelessWidget {
  const _Sheet();
  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w600);
    const note = TextStyle(color: Color(0xFFB9B2C8), fontSize: 15);
    return ColoredBox(
      color: _paper,
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox.square(
                  dimension: 400,
                  child: Ember(mood: Mood.acting, jobs: 3, animate: false, phase: .1),
                ),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      const Text('Compii', style: TextStyle(color: _ink, fontSize: 54, fontWeight: FontWeight.w700)),
                      const Text('Black glass, two eyes of light, a halo in any colour.',
                          style: TextStyle(color: _ink, fontSize: 21)),
                      const SizedBox(height: 20),
                      for (final line in const [
                        'One material: black glass, the same as the island Compii lives in. Nothing imitates life.',
                        'Two eyes of light carry every feeling, by changing shape — taller, narrower, slanted, arcs.',
                        'The halo is effort: it breathes at rest, races while thinking, flares when you speak.',
                        'The eyes follow your pointer and blink on their own slow clock, so nothing loops.',
                        'Five shapes, any colour, blue to start. No shape has a name on screen.',
                        'Each job it runs circles it as a small light; feelings live in the eyes, work in the lights.',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text('•  $line', style: note.copyWith(fontSize: 16.5)),
                        ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          for (final (c, name) in [
                            (haloBlue, 'Coat · blue'),
                            (EmberPalette.deep, 'Ink'),
                            (EmberPalette.frame, 'Indigo'),
                            (EmberPalette.core(Mood.idle), 'Light · ready'),
                            (EmberPalette.core(Mood.acting), 'Light · working'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: SizedBox(
                                width: 88,
                                child: Column(
                                  children: [
                                    Container(
                                      width: 50,
                                      height: 50,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: const Color(0x33FFFFFF)),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(name, maxLines: 2, textAlign: TextAlign.center, style: note),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('Five shapes — no names, because the shape is the choice',
                style: TextStyle(color: Color(0xFFB9B2C8), fontSize: 15)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final b in CompiiBody.values)
                  Expanded(
                    child: SizedBox.square(
                      dimension: 150,
                      child: Ember(mood: Mood.idle, body: b, animate: false, phase: .3),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('Any colour', style: TextStyle(color: Color(0xFFB9B2C8), fontSize: 15)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, k) in haloSwatches.take(8).indexed)
                  Expanded(
                    child: SizedBox.square(
                      dimension: 124,
                      child: Ember(mood: Mood.idle, body: HaloForm.values[i % HaloForm.values.length], color: k, animate: false, phase: .3),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final m in Mood.values)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox.square(
                          dimension: 112,
                          child: Ember(mood: m, jobs: m == Mood.acting ? 3 : 0, animate: false),
                        ),
                        Text(moodLabel(m), style: label),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(width: 96, child: Text('At every size', style: label)),
                const SizedBox(width: 24),
                for (final (d, noteText) in const [
                  (120.0, 'hero'),
                  (72.0, 'dock'),
                  (44.0, 'bar'),
                  (30.0, 'row'),
                  (18.0, 'chip'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 26),
                    child: Column(
                      children: [
                        SizedBox.square(
                          dimension: d,
                          child: const Ember(mood: Mood.idle, animate: false, phase: .2),
                        ),
                        const SizedBox(height: 4),
                        Text('${d.toInt()} · $noteText', style: note),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('character sheet renders every mood and every body without errors', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
      final font = File('C:/Windows/Fonts/segoeui.ttf');
      if (font.existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await tester.runAsync(loader.load);
      }
    }
    tester.view.physicalSize = const Size(1600, 1440);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(home: Material(child: RepaintBoundary(key: key, child: const _Sheet()))),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (capture) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(boundary.toImage))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
      await tester.runAsync(
        () => File('${out.path}/compii-character-sheet.png').writeAsBytes(bytes!.buffer.asUint8List()),
      );
      image.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('presence view and every small size render without errors', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: Row(
            children: [
              const Expanded(
                child: ColoredBox(
                  color: Color(0xFF070617),
                  child: Ember(mood: Mood.listening, face: true, animate: false, phase: .3, level: .6),
                ),
              ),
              for (final d in const [90.0, 56.0, 34.0, 24.0, 16.0])
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: d,
                    child: Ember(mood: Mood.thinking, animate: false, jobs: 2),
                  ),
                ),
            ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (capture) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
      final bytes = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
      await tester.runAsync(
        () => File('${out.path}/compii-presence-view.png')
            .writeAsBytes(bytes!.buffer.asUint8List()),
      );
      image.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
