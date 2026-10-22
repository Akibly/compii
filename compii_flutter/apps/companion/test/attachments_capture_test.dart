// Attachments in a conversation: the file travels with the message and stays visible.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/thread.dart';
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

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(boundary.toImage))!;
  final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  final out = Directory('../../../docs/compii/build-previews/g4')..createSync(recursive: true);
  await tester.runAsync(() => File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
  debugPrint('SHOT ${out.path}/$name.png');
}

void main() {
  testWidgets('an attached file is part of the message, in the box and in the thread', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    tester.view.physicalSize = const Size(820, 980);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    const ask = 'Summarise this report and put the deadlines in my calendar';
    final task = TaskView(id: 't', request: ask, status: 'done')
      ..events.addAll([
        {
          'type': 'task_started',
          'at': 0,
          'request': ask,
          'attachments': [
            {'name': 'Scholarship shortlist.pdf', 'path': r'C:\Compii\uploads\Scholarship shortlist.pdf',
             'size': 284000, 'kind': 'pdf'},
          ],
        },
        {'type': 'action_started', 'tool': 'read_file', 'label': 'Read Scholarship shortlist.pdf', 'at': 1},
        {'type': 'action_done', 'tool': 'read_file', 'label': 'Read Scholarship shortlist.pdf', 'ok': true, 'at': 3},
        {'type': 'task_finished', 'status': 'done', 'at': 6,
         'text': 'Read the shortlist. Nexus closes 12 November and Horizon closes 5 December — I put both '
             'in your calendar with a week’s warning.'},
      ]);
    final core = CoreClient()..status = CoreStatus.online;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: compiiTheme(Brightness.light),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 760,
                height: 940,
                child: Material(
                  color: Colors.white,
                  child: Column(
                    children: [
                      Expanded(child: ThreadView(task: task, core: core, run: (a) => a())),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
                        child: Composer(
                          core: core,
                          hint: 'Ask Compii to do something…',
                          onSend: (_) async {},
                          onSendFiles: (_, _) async {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Scholarship shortlist.pdf'), findsOneWidget);
    expect(find.textContaining('Nexus closes 12 November'), findsOneWidget);
    expect(find.byTooltip('Attach files'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await _shot(tester, key, 'attachments');
  });
}
