// Renders every mood; with --dart-define=CAPTURE=true it also saves the character sheet for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/character.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _paper = Color(0xFFF7F5F2);
const _ink = Color(0xFF15122E);

class _Sheet extends StatelessWidget {
  const _Sheet();
  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: _ink, fontSize: 18, fontWeight: FontWeight.w600);
    const note = TextStyle(color: Color(0xFF5E5A70), fontSize: 15);
    return ColoredBox(
      color: _paper,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox.square(
                  dimension: 460,
                  child: Orbling(mood: Mood.acting, jobs: 3, animate: false, phase: .1),
                ),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 30),
                      const Text('Compii', style: TextStyle(color: _ink, fontSize: 56, fontWeight: FontWeight.w700)),
                      const Text('An Orbling: a small, gentle creature that carries its own orbit.',
                          style: TextStyle(color: _ink, fontSize: 22)),
                      const SizedBox(height: 24),
                      for (final line in const [
                        'Each golden firefly circling it is a job it is doing.',
                        'Its soft hands float free, so they can go and do things: point, type, carry.',
                        'The golden sprout on top is its signature outline.',
                        'Warm and gentle, like its voice.',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text('•  $line', style: note.copyWith(fontSize: 18)),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          for (final (c, name) in const [
                            (OrblingPalette.body, 'Orbling indigo'),
                            (OrblingPalette.mitten, 'Cream'),
                            (OrblingPalette.gold, 'Firefly gold'),
                            (OrblingPalette.cheek, 'Cheek pink'),
                            (OrblingPalette.ink, 'Ink'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 18),
                              child: Column(
                                children: [
                                  Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: c,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: const Color(0x22000000)),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(name, style: note),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      Row(
                        children: [
                          const Text('Silhouette test', style: label),
                          const SizedBox(width: 18),
                          for (final d in const [90.0, 48.0, 24.0])
                            Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: ColorFiltered(
                                colorFilter: const ColorFilter.mode(_ink, BlendMode.srcIn),
                                child: SizedBox.square(
                                  dimension: d,
                                  child: const Orbling(mood: Mood.idle, animate: false),
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
            const SizedBox(height: 20),
            Row(
              children: [
                for (final m in Mood.values)
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox.square(
                          dimension: 200,
                          child: Orbling(mood: m, jobs: m == Mood.acting ? 3 : 0, animate: false),
                        ),
                        Text(moodLabel(m), style: label),
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
  testWidgets('character sheet renders every mood without errors', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
      final font = File('C:/Windows/Fonts/segoeui.ttf');
      if (font.existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await tester.runAsync(loader.load);
      }
    }
    tester.view.physicalSize = const Size(1600, 980);
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
}
