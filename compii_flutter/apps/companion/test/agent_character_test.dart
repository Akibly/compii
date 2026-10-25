import 'package:compii/src/console/character.dart' show Mood, moodLabel;
import 'package:compii/src/art/halo.dart';
import 'package:compii/src/ui/agent_character.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('saved looks round-trip, and a missing one is still a drawn character', () {
    final gem = AgentLook.parse('a3.gem.42');
    expect(gem.shape, HaloForm.gem);
    expect(gem.seed, 42);
    expect(gem.encode(), 'a3.gem.42');
    // Teammates saved with either earlier character set keep their seed and get
    // the glass form that took that shape's place.
    expect(AgentLook.parse('a1.capsule.42').encode(), 'a3.tower.42');
    expect(AgentLook.parse('a2.mop.42').encode(), 'a3.pill.42');
    // A teammate saved before characters existed, or with a token from
    // somewhere else, gets a stable one from its name rather than a fallback
    // glyph.
    expect(AgentLook.parse('', name: 'Sammy').shape, AgentLook.forName('Sammy').shape);
    expect(AgentLook.parse('o1.6.6.3.3.3.6.0.13', name: 'Sammy').seed, AgentLook.forName('Sammy').seed);
    expect(AgentLook.parse('a1.nope.42').encode(), 'a3.orb.1');
  });

  testWidgets('no character is drawn as text', (tester) async {
    await tester.pumpWidget(_host(
      Wrap(
        children: [
          for (final shape in HaloForm.values)
            AgentFace(key: ValueKey(shape), color: haloBlue, shape: shape, seed: 7, size: 64),
        ],
      ),
    ));
    expect(find.byType(Text), findsNothing);
    for (final shape in HaloForm.values) {
      final paint = tester.widget<CustomPaint>(find.descendant(
        of: find.byKey(ValueKey(shape)),
        matching: find.byType(CustomPaint),
      ));
      expect(paint.painter, isA<HaloPainter>());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('every 3D character wears every state without a hitch', (tester) async {
    await tester.pumpWidget(_host(
      Wrap(
        children: [
          for (final shape in HaloForm.values)
            for (final mood in Mood.values)
              AgentFace(
                key: ValueKey('${shape.name}-${mood.name}'),
                color: haloBlue,
                shape: shape,
                seed: shape.index * 13 + 7,
                size: 64,
                mood: mood,
              ),
        ],
      ),
    ));
    expect(tester.takeException(), isNull);
    final working = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const ValueKey('pill-acting')),
        matching: find.byType(CustomPaint),
      ),
    );
    expect((working.painter as HaloPainter).pose.mood, Mood.acting);
  });

  testWidgets('a state is said out loud, not only drawn', (tester) async {
    await tester.pumpWidget(_host(
      AgentFace(color: const Color(0xFF59C3A6), shape: HaloForm.tile, seed: 3, size: 64, mood: Mood.waiting),
    ));
    expect(
      tester.getSemantics(find.byType(AgentFace)).label,
      '${HaloForm.tile.desc}, ${moodLabel(Mood.waiting)}',
      reason: 'the state is spoken as well as drawn',
    );
  });

  testWidgets('the picker shows creatures without names and returns any colour', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    ({AgentLook look, Color color})? picked;
    await tester.pumpWidget(_host(Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          picked = await showAgentPicker(
            context,
            color: haloBlue,
            look: const AgentLook(HaloForm.orb, 1),
          );
        },
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    for (final shape in HaloForm.values) {
      expect(find.text(shape.name), findsNothing, reason: 'no creature carries a name');
      expect(find.bySemanticsLabel(shape.desc), findsWidgets, reason: 'every creature can be chosen');
    }

    await tester.tap(find.bySemanticsLabel(HaloForm.tower.desc).first);
    await tester.pump();
    // Open "Any colour" and type a colour that is in no preset.
    await tester.tap(find.text('Any colour'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Hex'), '#12AB34');
    await tester.pump();
    await tester.tap(find.text('Use this character'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(picked, isNotNull);
    expect(picked!.look.shape, HaloForm.tower);
    expect(colorHex(picked!.color), '#12AB34');
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
