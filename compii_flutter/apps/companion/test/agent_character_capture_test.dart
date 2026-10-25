// Renders the teammate characters; with --dart-define=CAPTURE=true it also
// saves the character sheet for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/character.dart' show Mood, moodLabel;
import 'package:compii/src/art/halo.dart';
import 'package:compii/src/ui/agent_character.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _paper = Color(0xFFF7F5F2);
const _ink = Color(0xFF15122E);
const _faint = Color(0xFF5E5A70);

const _shapeColor = {
  HaloForm.orb: Color(0xFF7C9CFF),
  HaloForm.gem: Color(0xFFB49BFF),
  HaloForm.tile: Color(0xFF59C3A6),
  HaloForm.pill: Color(0xFFF2B45C),
  HaloForm.tower: Color(0xFFE08BD0),
};

Future<void> _loadFonts(WidgetTester tester) async {
  for (final (family, path) in [
    ('Roboto', 'C:/Windows/Fonts/segoeui.ttf'),
    ('Segoe UI Emoji', 'C:/Windows/Fonts/seguiemj.ttf'),
  ]) {
    final font = File(path);
    if (!font.existsSync()) continue;
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await tester.runAsync(loader.load);
  }
}

class _CloseUp extends StatelessWidget {
  const _CloseUp({required this.mood, required this.shape, required this.color});
  final Mood mood;
  final HaloForm shape;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AgentFace(
        color: color,
        shape: shape,
        seed: 12,
        size: 240,
        backgroundDisc: false,
        mood: mood,
      ),
      const SizedBox(height: 8),
      Text(moodLabel(mood), style: const TextStyle(color: _ink, fontSize: 19)),
    ],
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet();
  @override
  Widget build(BuildContext context) {
    const title = TextStyle(color: _ink, fontSize: 56, fontWeight: FontWeight.w700);
    const sub = TextStyle(color: _ink, fontSize: 22);
    const note = TextStyle(color: _faint, fontSize: 15);
    const label = TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w600);
    const tiny = TextStyle(color: _faint, fontSize: 13);
    return ColoredBox(
      color: _paper,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Agent characters', style: title),
            const Text(
                'Six live characters cut from glass, each with a face of its own.',
                style: sub),
            const SizedBox(height: 18),
            for (final line in const [
              'Every teammate wears one of these six — there are no emoji avatars.',
              'They are painted, not sprites: each one breathes, blinks and turns in the light.',
              'One face rig drives all six — eyes, brows and a mouth — so every state reads the same way.',
              'The state is also written next to the character; nothing is carried by the drawing alone.',
              'Lists keep them still; the teammate’s home, the picker and this sheet let them move.',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('•  $line', style: note.copyWith(fontSize: 17)),
              ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final shape in HaloForm.values)
                  Expanded(
                    child: Column(
                      children: [
                        AgentFace(
                          color: _shapeColor[shape]!,
                          shape: shape,
                          seed: shape.index + 7,
                          size: 122,
                          backgroundDisc: false,
                          mood: switch (shape) {
                            HaloForm.orb => Mood.idle,
                            HaloForm.gem => Mood.listening,
                            HaloForm.tile => Mood.thinking,
                            HaloForm.pill => Mood.acting,
                            HaloForm.tower => Mood.happy,
                          },
                        ),
                        const SizedBox(height: 8),
                        Text(shape.desc, textAlign: TextAlign.center, style: note.copyWith(fontSize: 13)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 26),
            Text('ONE FACE, EVERY STATE — the same creature, drawn still', style: label),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final mood in Mood.values)
                  Expanded(
                    child: Column(
                      children: [
                        AgentFace(
                          color: _shapeColor[HaloForm.orb]!,
                          shape: HaloForm.orb,
                          seed: 12,
                          size: 96,
                          backgroundDisc: false,
                          mood: mood,
                        ),
                        const SizedBox(height: 6),
                        Text(moodLabel(mood), style: tiny),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final mood in Mood.values)
                  Expanded(
                    child: Column(
                      children: [
                        AgentFace(
                          color: _shapeColor[HaloForm.tower]!,
                          shape: HaloForm.tower,
                          seed: 31,
                          size: 96,
                          backgroundDisc: false,
                          mood: mood,
                        ),
                        const SizedBox(height: 6),
                        Text(moodLabel(mood), style: tiny),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const SizedBox(width: 120, child: Text('At every size', style: label)),
                for (final d in const [104.0, 72.0, 44.0, 30.0, 22.0])
                  Padding(
                    padding: const EdgeInsets.only(right: 22),
                    child: Column(
                      children: [
                        AgentFace(
                          color: haloBlue,
                          shape: HaloForm.orb,
                          seed: 12,
                          size: d,
                          backgroundDisc: false,
                        ),
                        const SizedBox(height: 4),
                        Text('${d.toInt()}', style: note),
                      ],
                    ),
                  ),
                for (final d in const [72.0, 44.0, 30.0, 22.0])
                  Padding(
                    padding: const EdgeInsets.only(right: 22),
                    child: Column(
                      children: [
                        AgentFace(
                          color: const Color(0xFFE08BD0),
                          shape: HaloForm.tower,
                          seed: 31,
                          size: d,
                          backgroundDisc: false,
                        ),
                        const SizedBox(height: 4),
                        Text('${d.toInt()}', style: note),
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
  testWidgets('a close-up of every state, so the expressions can be judged', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (!capture) return;
    await _loadFonts(tester);
    tester.view.physicalSize = const Size(1500, 1150);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: _paper,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var row = 0; row < 3; row++)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (var col = 0; col < 3; col++)
                            _CloseUp(
                              mood: Mood.values[row * 3 + col],
                              shape: HaloForm.orb,
                              color: haloBlue,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(boundary.toImage))!;
    final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
    final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
    await tester.runAsync(
      () => File('${out.path}/compii-agent-faces.png').writeAsBytes(bytes!.buffer.asUint8List()),
    );
    image.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('agent character sheet renders without errors', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    tester.view.physicalSize = const Size(1600, 1240);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: RepaintBoundary(
            key: key,
            child: const FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(width: 1600, child: _Sheet()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (capture) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(boundary.toImage))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
      await tester.runAsync(
        () => File('${out.path}/compii-agent-characters.png').writeAsBytes(bytes!.buffer.asUint8List()),
      );
      image.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
