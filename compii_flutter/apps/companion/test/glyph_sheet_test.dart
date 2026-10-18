import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/ui/glyphs.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders every glyph (plain, active and small) to docs/compii/build-previews/v4/glyphs.png.
void main() {
  testWidgets('glyph sheet', (tester) async {
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget sheet(Brightness b) => Theme(
      data: compiiTheme(b),
      child: Builder(builder: (context) {
        final c = context.c;
        return Container(
          color: c.canvas,
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in G.all.entries)
                Container(
                  width: 64,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.border)),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Glyph(e.value, size: 24, color: c.text),
                      const SizedBox(width: 6),
                      Glyph(e.value, size: 24, color: c.accent, duo: true),
                    ]),
                    const SizedBox(height: 4),
                    Glyph(e.value, size: 16, color: c.muted),
                  ]),
                ),
            ],
          ),
        );
      }),
    );
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(key: key, child: Column(children: [sheet(Brightness.light), sheet(Brightness.dark)])),
    ));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
    final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
    final out = Directory('../../../docs/compii/build-previews/v4')..createSync(recursive: true);
    await tester.runAsync(() => File('${out.path}/glyphs.png').writeAsBytes(bytes!.buffer.asUint8List()));
  });
}
