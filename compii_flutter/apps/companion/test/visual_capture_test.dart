// Opt-in raster captures for visual inspection, not native-device screenshots.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:compii/src/app.dart';
import 'package:compii/src/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('capture desktop and phone presentations', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE')) return;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await tester.runAsync(icons.load);
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (font.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await tester.runAsync(loader.load);
    }
    final output = Directory('../../../docs/compii/build-previews');
    output.createSync(recursive: true);
    for (final spec in [
      ('desktop-face', const Size(1280, 900), Presentation.face, false),
      (
        'desktop-full-body',
        const Size(1280, 900),
        Presentation.fullBody,
        false,
      ),
      ('phone-face', const Size(390, 844), Presentation.face, true),
      ('phone-full-body', const Size(390, 844), Presentation.fullBody, true),
      ('phone-landscape', const Size(844, 390), Presentation.face, true),
    ]) {
      tester.view.physicalSize = spec.$2;
      tester.view.devicePixelRatio = 1;
      final preferences = CompanionPreferences(SharedPreferencesAsync());
      await preferences.update(view: spec.$3, reduce: true);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: CompiiApp(key: UniqueKey(), preferences: preferences),
        ),
      );
      await tester.pumpAndSettle();
      if (spec.$4) {
        await tester.tap(find.byTooltip('Open phone preview'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final snapshot = (await tester.runAsync(boundary.toImage))!;
      final bytes = await tester.runAsync(() => snapshot.toByteData(format: ui.ImageByteFormat.png));
      await tester.runAsync(
        () => File(
          '${output.path}/${spec.$1}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List()),
      );
      snapshot.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
