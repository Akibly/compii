// Renders the console with sample task data (no Core needed); with --dart-define=CAPTURE=true it saves PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/console_screen.dart';
import 'package:compii/src/console/core_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CoreClient sampleCore({required bool approved}) {
  final core = CoreClient()
    ..status = CoreStatus.online
    ..brain = 'claude';
  final task = TaskView(
    id: 't1',
    request: "Find last month's invoices in Downloads, put them in a spreadsheet and email it to me",
    status: approved ? 'done' : 'waiting',
  );
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  task.events.addAll([
    {'type': 'task_started', 'at': now},
    for (final label in ['Search Downloads for *invoice*', 'Create spreadsheet Invoices last month.xlsx', 'Read Invoices last month.xlsx'])
      {'type': 'action_done', 'label': label, 'ok': true, 'tool': 'x', 'detail': '', 'at': now},
    {
      'type': 'approval_needed',
      'approval_id': 'a1',
      'kind': 'send',
      'label': 'Email me@example.com: “Last month\'s invoices” with 1 attachment(s)',
      'input': {'to': ['me@example.com'], 'subject': "Last month's invoices", 'attachments': ['Invoices last month.xlsx']},
      'at': now,
    },
    if (approved) ...[
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': true, 'at': now},
      {'type': 'action_done', 'label': 'Email me@example.com: “Last month\'s invoices”', 'ok': true, 'tool': 'send_email', 'detail': 'Sent email to me@example.com', 'undoable': false, 'at': now},
      {'type': 'task_finished', 'status': 'done', 'text': 'Done! 3 invoices are in "Invoices last month.xlsx" and I emailed it to you.', 'at': now},
    ],
  ]);
  core.tasks[task.id] = task;
  return core;
}

void main() {
  testWidgets('console renders waiting and done states', (tester) async {
    if (const bool.fromEnvironment('CAPTURE')) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await tester.runAsync(icons.load);
      final font = File('C:/Windows/Fonts/segoeui.ttf');
      if (font.existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await tester.runAsync(loader.load);
      }
    }
    tester.view.physicalSize = const Size(1400, 860);
    tester.view.devicePixelRatio = 1;
    for (final approved in [false, true]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            theme: consoleTheme(),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1400, 860), disableAnimations: true),
              child: ConsoleScreen(core: sampleCore(approved: approved)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.text(approved ? 'Done' : 'Needs you'), findsWidgets);
      if (const bool.fromEnvironment('CAPTURE')) {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(boundary.toImage))!;
        final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
        final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
        await tester.runAsync(
          () => File('${out.path}/console-${approved ? 'done' : 'needs-you'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List()),
        );
        image.dispose();
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
