// Compii is one face rig worn by five selectable bodies, and the choice is local
// taste kept on this PC. These cover the three contracts that make that true:
// every body wears the rig, the global choice repaints a character that asked for
// no particular body, and the choice survives a restart.
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
  tearDown(() => compiiBody.value = CompiiBody.plush);

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
    expect(_painter(tester).body, CompiiBody.plush);

    compiiBody.value = CompiiBody.shell;
    await tester.pump();
    expect(_painter(tester).body, CompiiBody.shell);
  });

  test('the form is restored on load and saved when it changes', () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'drop'});
    final state = AppState();
    await state.load();
    expect(compiiBody.value, CompiiBody.drop);

    state.setBody(CompiiBody.moth);
    await Future<void>.delayed(Duration.zero);
    expect((await SharedPreferences.getInstance()).getString('compii_form'), 'moth');
  });

  test('a form name that no longer exists falls back to the default rather than throwing',
      () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'butterfly'});
    final state = AppState();
    await state.load();
    expect(compiiBody.value, CompiiBody.plush);
  });
}
