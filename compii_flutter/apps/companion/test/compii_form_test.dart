// Compii is one face rig worn by five selectable bodies in six selectable coats,
// and both choices are local taste kept on this PC. These cover the contracts
// that make that true: every body and coat wears the rig, the global choices
// repaint a character that asked for neither, and both survive a restart.
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
    compiiBody.value = CompiiBody.plush;
    compiiCoat.value = CompiiCoat.blue;
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

  testWidgets('every coat paints on the soft bodies and on the one made of light',
      (tester) async {
    for (final k in CompiiCoat.values) {
      for (final b in const [CompiiBody.plush, CompiiBody.moth, CompiiBody.spark]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: SizedBox.square(
                dimension: 200,
                child: Ember(mood: Mood.acting, body: b, coat: k, animate: false, phase: .4),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '${k.name} coat on ${b.name}');
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
    expect(_painter(tester).coat, CompiiCoat.blue);

    compiiBody.value = CompiiBody.shell;
    compiiCoat.value = CompiiCoat.amber;
    await tester.pump();
    expect(_painter(tester).body, CompiiBody.shell);
    expect(_painter(tester).coat, CompiiCoat.amber);
  });

  test('the form is restored on load and saved when it changes', () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'drop', 'compii_coat': 'rose'});
    final state = AppState();
    await state.load();
    expect(compiiBody.value, CompiiBody.drop);
    expect(compiiCoat.value, CompiiCoat.rose);

    state.setBody(CompiiBody.moth);
    state.setCoat(CompiiCoat.mint);
    await Future<void>.delayed(Duration.zero);
    final p = await SharedPreferences.getInstance();
    expect(p.getString('compii_form'), 'moth');
    expect(p.getString('compii_coat'), 'mint');
  });

  test('a form name that no longer exists falls back to the default rather than throwing',
      () async {
    SharedPreferences.setMockInitialValues({'compii_form': 'butterfly', 'compii_coat': 'tartan'});
    final state = AppState();
    await state.load();
    expect(compiiBody.value, CompiiBody.plush);
    expect(compiiCoat.value, CompiiCoat.blue);
  });
}
