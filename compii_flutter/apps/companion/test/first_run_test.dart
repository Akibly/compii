// Every setup step renders; with --dart-define=CAPTURE=true the steps are saved for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/first_run.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first-run setup: every step renders', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
      for (final family in ['Segoe UI Variable Text', 'Segoe UI Variable Display', 'Roboto']) {
        final loader = FontLoader(family);
        final f = File('C:/Windows/Fonts/SegUIVar.ttf');
        if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
        await tester.runAsync(loader.load);
      }
    }
    const size = Size(1100, 820);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final preview = {
      'brain': <String, dynamic>{'keys': {'groq': false, 'nvidia': false}},
      'voice': <String, dynamic>{
        'listen_ready': true, 'natural_voice': true,
        'voices': {'compii_warm': 'Compii (warm)', 'compii_bright': 'Compii (bright)'},
        'settings': {'voice': 'compii_warm', 'cloud_listening': true, 'see_pictures': true},
      },
    };
    for (var step = 0; step < 5; step++) {
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          key: UniqueKey(),
          debugShowCheckedModeBanner: false,
          theme: compiiTheme(Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(size: size, disableAnimations: true),
            child: FirstRun(core: CoreClient(), voice: null, onDone: () async {}, initialStep: step, preview: preview),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'step $step');
      if (capture) {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(boundary.toImage))!;
        final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
        final out = Directory('../../../docs/compii/build-previews/v4')..createSync(recursive: true);
        await tester.runAsync(() => File('${out.path}/first-run-$step.png').writeAsBytes(bytes!.buffer.asUint8List()));
      }
    }
    // Thinking step: Next stays off until a key is stored.
    await tester.pumpWidget(MaterialApp(theme: compiiTheme(Brightness.light), home: FirstRun(
        core: CoreClient(), voice: null, onDone: () async {}, initialStep: 1, preview: preview)));
    await tester.pump(const Duration(milliseconds: 300));
    final next = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'));
    expect(next.onPressed, isNull);
    await tester.pump(const Duration(seconds: 7));
  });
}
