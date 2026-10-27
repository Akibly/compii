// Compii's app icon at every size the platforms ask for. With
// --dart-define=ICONS=true it writes them to build/icon/ for scripts/make_icons.py.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/art/app_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sizes = [16, 20, 24, 29, 32, 40, 48, 58, 64, 72, 76, 80, 87, 96, 120, 128, 144, 152, 167, 180, 192, 256, 512, 1024];

Future<List<int>> _png(WidgetTester tester, int size, {double margin = 0}) async {
  final rec = ui.PictureRecorder();
  AppIconPainter(margin: margin).paint(Canvas(rec), Size.square(size.toDouble()));
  final image = await rec.endRecording().toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  testWidgets('the icon paints at every size without a hitch', (tester) async {
    for (final s in _sizes) {
      final png = (await tester.runAsync(() => _png(tester, s)))!;
      expect(png, isNotEmpty, reason: '$s px');
    }
    if (!const bool.fromEnvironment('ICONS')) return;
    final out = Directory('build/icon')..createSync(recursive: true);
    for (final s in _sizes) {
      final full = (await tester.runAsync(() => _png(tester, s)))!;
      File('${out.path}/icon_$s.png').writeAsBytesSync(full);
      // macOS: the tile sits inside a margin, like every other app on the dock.
      final mac = (await tester.runAsync(() => _png(tester, s, margin: .1)))!;
      File('${out.path}/mac_$s.png').writeAsBytesSync(mac);
    }
  });
}
