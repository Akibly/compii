// The teach review: keep what worked, drop what didn't, and check the rest
// without touching the desktop.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/ui/teach.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadFonts(WidgetTester tester) async {
  final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await tester.runAsync(icons.load);
  for (final family in ['Segoe UI Variable Text', 'Segoe UI Variable Display', 'Roboto']) {
    final loader = FontLoader(family);
    final file = File('C:/Windows/Fonts/SegUIVar.ttf');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await tester.runAsync(loader.load);
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name, {String folder = 'g3'}) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(boundary.toImage))!;
  final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  final out = Directory('../../../docs/compii/build-previews/$folder')..createSync(recursive: true);
  await tester.runAsync(() => File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
  debugPrint('SHOT ${out.path}/$name.png');
}

void main() {
  testWidgets('a recorded demo can be trimmed, tested and kept', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    List<int> kept = const [];
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: compiiTheme(Brightness.light),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 640,
                child: Material(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: TeachSteps(
                      steps: const [
                        'Switch to the “File Explorer” window',
                        'Click button “New folder” in “File Explorer”',
                        'Type the text into “Name”',
                        'Press enter',
                      ],
                      kinds: const ['switch', 'click', 'type', 'keys'],
                      tester: (keep) async => [
                        for (final i in keep)
                          {
                            'step': i + 1,
                            'ok': i != 2 || !keep.contains(3),
                            'detail': i == 0
                                ? '“File Explorer” is open.'
                                : i == 1
                                    ? 'Found “New folder” in “File Explorer”.'
                                    : i == 2
                                        ? 'Nothing called “Name” is on screen right now.'
                                        : 'Keys can be pressed when it runs.',
                          },
                      ],
                      onKeepChanged: (k) => kept = k,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('STEPS'), findsOneWidget);
    expect(find.text('4 of 4 kept'), findsOneWidget);
    expect(kept, [0, 1, 2, 3]);

    await tester.tap(find.text('Test'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('can’t be found right now'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();
    expect(find.text('3 of 4 kept'), findsOneWidget);
    expect(kept, [0, 1, 3]);

    await tester.tap(find.text('Test'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Every kept step can be found on screen right now.'), findsOneWidget);
    expect(find.text('Keep all'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await _shot(tester, key, 'teach-review');
  });
}
