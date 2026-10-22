import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

void main() {
  test('small text keeps readable contrast in both themes', () {
    for (final c in [CompiiColors.light, CompiiColors.night]) {
      for (final fg in [c.text, c.muted, c.faint, c.success, c.warning, c.danger]) {
        expect(_contrast(fg, c.raised), greaterThanOrEqualTo(4.5),
            reason: '${c.dark ? 'night' : 'light'} ${fg.toString()} on ${c.raised.toString()}');
      }
    }
  });

  test('keyboard focus is visible on every button style', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final t = compiiTheme(brightness);
      final c = t.extension<CompiiColors>()!;
      const focused = {WidgetState.focused};
      expect(t.outlinedButtonTheme.style!.side!.resolve(focused)!.color, c.accent);
      expect(t.outlinedButtonTheme.style!.backgroundColor!.resolve(focused), c.accentSoft);
      expect(t.textButtonTheme.style!.side!.resolve(focused)!.color, c.accent);
      expect(t.textButtonTheme.style!.backgroundColor!.resolve(focused), c.accentSoft);
      expect(t.iconButtonTheme.style!.side!.resolve(focused)!.color, c.accent);
      expect(t.iconButtonTheme.style!.backgroundColor!.resolve(focused), c.accentSoft);
      expect(t.segmentedButtonTheme.style!.side!.resolve(focused)!.color, c.accent);
      expect(t.filledButtonTheme.style!.side!.resolve(focused), isNotNull);
    }
  });
}
