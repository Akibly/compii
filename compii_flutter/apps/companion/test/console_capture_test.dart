// Renders the console and the phone Face View with sample task data (no Core
// needed); with --dart-define=CAPTURE=true it saves PNGs for visual review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/console_screen.dart';
import 'package:compii/src/console/core_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

enum Sample { working, needsYou, done }

CoreClient sampleCore(Sample state) {
  final core = CoreClient()
    ..status = CoreStatus.online
    ..brain = 'claude';
  final task = TaskView(
    id: 't1',
    request: "Find last month's invoices in Downloads, put them in a spreadsheet and email it to me",
    status: switch (state) {
      Sample.working => 'running',
      Sample.needsYou => 'waiting',
      Sample.done => 'done',
    },
  );
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  task.events.addAll([
    {'type': 'task_started', 'at': now},
    for (final label in ['Search Downloads for *invoice*', 'Create spreadsheet Invoices last month.xlsx'])
      {'type': 'action_done', 'label': label, 'ok': true, 'tool': 'x', 'detail': '', 'at': now},
    if (state == Sample.working)
      {'type': 'action_started', 'label': 'Read Invoices last month.xlsx', 'tool': 'read_file', 'at': now}
    else ...[
      {'type': 'action_done', 'label': 'Read Invoices last month.xlsx', 'ok': true, 'tool': 'x', 'detail': '', 'at': now},
      {
        'type': 'approval_needed',
        'approval_id': 'a1',
        'kind': 'send',
        'label': 'Email me@example.com: “Last month\'s invoices” with 1 attachment(s)',
        'input': {'to': ['me@example.com'], 'subject': "Last month's invoices", 'attachments': ['Invoices last month.xlsx']},
        'at': now,
      },
    ],
    if (state == Sample.done) ...[
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': true, 'at': now},
      {'type': 'action_done', 'label': 'Email me@example.com: “Last month\'s invoices”', 'ok': true, 'tool': 'send_email', 'detail': 'Sent email to me@example.com', 'undoable': false, 'at': now},
      {'type': 'task_finished', 'status': 'done', 'text': 'Done! 3 invoices are in "Invoices last month.xlsx" and I emailed it to you.', 'at': now},
    ],
  ]);
  if (state == Sample.working) {
    // Two older background jobs, so three motes orbit.
    for (final id in ['t2', 't3']) {
      core.tasks[id] = TaskView(id: id, request: 'Background job $id', status: 'running');
    }
  }
  core.tasks[task.id] = task;
  return core;
}

void main() {
  testWidgets('console and phone face view render', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) {
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
    for (final (name, size, state) in [
      ('console-needs-you', const Size(1400, 860), Sample.needsYou),
      ('console-done', const Size(1400, 860), Sample.done),
      ('phone-landscape-working', const Size(844, 390), Sample.working),
      ('phone-landscape-needs-you', const Size(844, 390), Sample.needsYou),
      ('phone-portrait-done', const Size(390, 844), Sample.done),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            theme: consoleTheme(),
            home: MediaQuery(
              data: MediaQueryData(size: size, disableAnimations: true),
              child: ConsoleScreen(core: sampleCore(state)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull, reason: name);
      if (capture) {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(boundary.toImage))!;
        final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
        final out = Directory('../../../docs/compii/build-previews')..createSync(recursive: true);
        await tester.runAsync(() => File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
        image.dispose();
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
