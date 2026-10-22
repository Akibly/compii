import 'package:compii/src/console/character.dart' show Mood, moodLabel;
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
    final gem = AgentLook.parse('a1.gem.42');
    expect(gem.shape, AgentShape.gem);
    expect(gem.seed, 42);
    expect(gem.encode(), 'a1.gem.42');
    // A teammate saved before characters existed, or with a token from
    // somewhere else, gets a stable one from its name rather than a fallback
    // glyph.
    expect(AgentLook.parse('', name: 'Sammy').shape, AgentLook.forName('Sammy').shape);
    expect(AgentLook.parse('o1.6.6.3.3.3.6.0.13', name: 'Sammy').seed, AgentLook.forName('Sammy').seed);
    expect(AgentLook.parse('a1.nope.42').encode(), 'a1.orb.1');
  });

  testWidgets('no character is drawn as text', (tester) async {
    await tester.pumpWidget(_host(
      Wrap(
        children: [
          for (final shape in AgentShape.values)
            AgentFace(key: ValueKey(shape), color: const Color(0xFF7C9CFF), shape: shape, seed: 7, size: 64),
        ],
      ),
    ));
    expect(find.byType(Text), findsNothing);
    for (final shape in AgentShape.values) {
      final paint = tester.widget<CustomPaint>(find.descendant(
        of: find.byKey(ValueKey(shape)),
        matching: find.byType(CustomPaint),
      ));
      expect(paint.painter, isA<AgentFacePainter>());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('every 3D character wears every state without a hitch', (tester) async {
    await tester.pumpWidget(_host(
      Wrap(
        children: [
          for (final shape in AgentShape.values)
            for (final mood in Mood.values)
              AgentFace(
                key: ValueKey('${shape.name}-${mood.name}'),
                color: const Color(0xFF7C9CFF),
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
        of: find.byKey(const ValueKey('gyro-acting')),
        matching: find.byType(CustomPaint),
      ),
    );
    expect((working.painter as AgentFacePainter).mood, Mood.acting);
  });

  testWidgets('a state is said out loud, not only drawn', (tester) async {
    await tester.pumpWidget(_host(
      const AgentFace(color: Color(0xFF59C3A6), shape: AgentShape.planet, seed: 3, size: 64, mood: Mood.waiting),
    ));
    expect(
      tester.getSemantics(find.byType(AgentFace)).label,
      'Orbit character, ${moodLabel(Mood.waiting)}',
      reason: 'the state is spoken as well as drawn',
    );
  });

  testWidgets('the picker offers only drawn characters', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    AgentLook? picked;
    await tester.pumpWidget(_host(Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          picked = await showAgentPicker(
            context,
            color: const Color(0xFF59C3A6),
            look: const AgentLook(AgentShape.orb, 1),
          );
        },
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('CLASSIC'), findsNothing);
    expect(find.text('CHARACTERS'), findsOneWidget);
    for (final shape in AgentShape.values) {
      expect(find.text(shape.label), findsWidgets, reason: 'every character can be chosen');
    }

    await tester.tap(find.text('Comet'));
    await tester.pump();
    await tester.tap(find.text('Use this character'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(picked, isNotNull);
    expect(picked!.shape, AgentShape.comet);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
