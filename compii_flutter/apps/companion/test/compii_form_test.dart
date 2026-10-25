// Compii is one face rig worn by six selectable fur creatures in any colour,
// and both choices are local taste kept on this PC. These cover the contracts
// that make that true: every body and coat wears the rig, the global choices
// repaint a character that asked for neither, and both survive a restart.
import 'package:compii/src/art/halo.dart';
import 'package:compii/src/console/character.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

EmberPainter _painter(WidgetTester tester) {
  for (final e in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final p = e.painter;
    if (p is EmberPainter) return p;
  }
  throw StateError('no EmberPainter on screen');
}

void main() {
  tearDown(() {
    compiiBody.value = HaloForm.orb;
    compiiColor.value = haloBlue;
  });

  testWidgets('every body wears the same face rig without complaint', (tester) async {
    for (final b in CompiiBody.values) {
      for (final m in Mood.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: SizedBox.square(
                dimension: 200,
                child: Ember(mood: m, body: b, animate: false, phase: .86, followPointer: false),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '${b.name} wearing ${m.name} mid-blink');
      }
    }
  });

  testWidgets('any colour paints on every creature, pale, dark and in between',
      (tester) async {
    for (final k in const [haloBlue, Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFF12AB34), Color(0xFFEEE4D4)]) {
      for (final b in HaloForm.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: SizedBox.square(
                dimension: 200,
                child: Ember(mood: Mood.acting, body: b, color: k, animate: false, phase: .4),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '${colorHex(k)} on ${b.name}');
      }
    }
  });

  testWidgets('the global choice repaints a character that asked for no particular body',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const SizedBox.square(
            dimension: 200,
            child: Ember(mood: Mood.idle, animate: false),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_painter(tester).body, HaloForm.orb);
    expect(_painter(tester).color, haloBlue);

    compiiBody.value = HaloForm.gem;
    compiiColor.value = const Color(0xFFFF6FAE);
    await tester.pump();
    expect(_painter(tester).body, HaloForm.gem);
    expect(_painter(tester).color, const Color(0xFFFF6FAE));
  });

  test('the form is restored on load and saved when it changes', () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'pill', 'compii_coat': '#12AB34'});
    final state = AppState();
    await state.load();
    expect(compiiBody.value, HaloForm.pill);
    expect(compiiColor.value, const Color(0xFF12AB34));

    state.setBody(HaloForm.tower);
    state.setColor(const Color(0xFFB45CFF));
    await Future<void>.delayed(Duration.zero);
    final p = await SharedPreferences.getInstance();
    expect(p.getString('compii_form'), 'tower');
    expect(p.getString('compii_coat'), '#B45CFF');
  });

  test('a look saved by an earlier build carries over to the closest creature and colour', () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'moth', 'compii_coat': 'rose'});
    await AppState().load();
    expect(compiiBody.value, HaloForm.gem);
    expect(compiiColor.value, const Color(0xFFFF6FAE));
  });

  test('a form name that no longer exists falls back to the default rather than throwing',
      () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'butterfly', 'compii_coat': 'tartan'});
    final state = AppState();
    await state.load();
    expect(compiiBody.value, HaloForm.orb);
    expect(compiiColor.value, haloBlue);
  });
}
