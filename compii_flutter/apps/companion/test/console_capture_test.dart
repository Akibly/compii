// Renders the redesigned screens with sample conversations (no Core needed);
// with --dart-define=CAPTURE=true it saves PNGs for visual review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/console_screen.dart';
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/quick_bar.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:compii/src/ui/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

enum Sample { empty, working, needsYou, done }

const _plan = ["Find last month's invoices", 'Build the spreadsheet', 'Check it', 'Email it to you'];

List<Map<String, dynamic>> _planEvent(int doneCount, double at) => [
  {
    'type': 'plan',
    'at': at,
    'steps': [
      for (final (i, t) in _plan.indexed)
        {'title': t, 'status': i < doneCount ? 'done' : (i == doneCount ? 'active' : 'pending')},
    ],
  },
];

CoreClient sampleCore(Sample state) {
  final core = CoreClient()
    ..status = CoreStatus.online
    ..brain = 'claude';
  if (state == Sample.empty) return core;
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  final ws = r'C:\Users\you\Compii';
  final older = TaskView(id: 't0', request: 'Remember that I prefer short replies', status: 'done')
    ..events.addAll([
      {'type': 'task_started', 'at': now - 7200},
      {'type': 'action_done', 'tool': 'remember', 'label': 'Remember: prefers short replies', 'kind': 'create', 'ok': true, 'detail': '', 'at': now - 7199},
      {'type': 'task_finished', 'status': 'done', 'text': "Got it — I'll keep replies short.", 'at': now - 7198},
    ]);
  core.tasks[older.id] = older;
  final task = TaskView(
    id: 't1',
    request: "Find last month's invoices in Downloads, put them in a spreadsheet and email it to me",
    status: switch (state) {
      Sample.working => 'running',
      Sample.needsYou => 'waiting',
      _ => 'done',
    },
  );
  final t0 = now - 40;
  task.events.addAll([
    {'type': 'task_started', 'at': t0},
    ..._planEvent(0, t0 + 1),
    {'type': 'action_done', 'tool': 'find_files', 'label': 'Search Downloads for *invoice*', 'kind': 'read', 'ok': true, 'detail': '', 'at': t0 + 3},
    ..._planEvent(1, t0 + 4),
    {'type': 'action_done', 'tool': 'create_spreadsheet', 'label': 'Create spreadsheet Invoices last month.xlsx', 'kind': 'create', 'ok': true, 'undoable': true, 'detail': '', 'at': t0 + 7},
    {'type': 'file', 'path': '$ws\\Invoices last month.xlsx', 'action': 'created', 'at': t0 + 7},
    if (state == Sample.working)
      {'type': 'action_started', 'tool': 'read_file', 'label': 'Read Invoices last month.xlsx', 'at': t0 + 8}
    else ...[
      ..._planEvent(2, t0 + 8),
      {'type': 'action_done', 'tool': 'read_file', 'label': 'Read Invoices last month.xlsx', 'kind': 'read', 'ok': true, 'detail': '', 'at': t0 + 9},
      ..._planEvent(3, t0 + 10),
      {
        'type': 'approval_needed',
        'approval_id': 'a1',
        'kind': 'send',
        'tool': 'send_email',
        'label': 'Email me@example.com: “Last month\'s invoices” with 1 attachment(s)',
        'input': {
          'to': ['me@example.com'],
          'subject': "Last month's invoices",
          'body': "Here is the summary of last month's invoices: 3 files, total in the sheet.",
          'attachments': ['Invoices last month.xlsx'],
        },
        'at': t0 + 11,
      },
    ],
    if (state == Sample.done) ...[
      {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': true, 'at': t0 + 15},
      {'type': 'action_done', 'tool': 'send_email', 'label': 'Email me@example.com: “Last month\'s invoices”', 'kind': 'send', 'ok': true, 'detail': 'Sent email to me@example.com', 'at': t0 + 16},
      ..._planEvent(4, t0 + 17),
      {'type': 'task_finished', 'status': 'done', 'text': 'Done — 3 invoices are in “Invoices last month.xlsx” in your Compii folder, and I emailed it to you.', 'at': t0 + 18},
      {'type': 'user_message', 'text': 'Also make a PDF copy of it', 'status': 'running', 'at': t0 + 25},
      {'type': 'action_done', 'tool': 'run_python', 'label': 'Run a Python script', 'kind': 'change', 'ok': true, 'detail': '', 'at': t0 + 29},
      {'type': 'file', 'path': '$ws\\Invoices last month.pdf', 'action': 'created', 'at': t0 + 29},
      {'type': 'task_finished', 'status': 'done', 'text': 'Here’s the PDF copy, next to the spreadsheet.', 'at': t0 + 31},
    ],
  ]);
  core.tasks[task.id] = task;
  if (state == Sample.working) {
    core.tasks['t2'] = TaskView(id: 't2', request: 'Research the three best budget laptops this month', status: 'running')
      ..events.add({'type': 'task_started', 'at': now - 5});
  }
  return core;
}

Future<void> _loadFonts(WidgetTester tester) async {
  final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await tester.runAsync(icons.load);
  for (final family in ['Segoe UI Variable Text', 'Roboto']) {
    final loader = FontLoader(family);
    for (final f in ['segoeui.ttf']) {
      final file = File('C:/Windows/Fonts/$f');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await tester.runAsync(loader.load);
  }
}

void main() {
  testWidgets('redesigned screens render', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    final shots = <(String, Size, Sample, Brightness, String)>[
      ('home', const Size(1440, 900), Sample.empty, Brightness.light, 'workspace'),
      ('conversation-working', const Size(1440, 900), Sample.working, Brightness.light, 'workspace'),
      ('conversation-needs-you', const Size(1440, 900), Sample.needsYou, Brightness.light, 'workspace'),
      ('conversation-done-dark', const Size(1440, 900), Sample.done, Brightness.dark, 'workspace'),
      ('quick-bar', const Size(720, 520), Sample.needsYou, Brightness.light, 'quick'),
      ('phone-landscape-needs-you', const Size(844, 390), Sample.needsYou, Brightness.light, 'workspace'),
      ('home-listening', const Size(1440, 900), Sample.empty, Brightness.light, 'listening'),
      ('conversation-speaking-dark', const Size(1440, 900), Sample.done, Brightness.dark, 'speaking'),
      ('settings-voice', const Size(1440, 900), Sample.empty, Brightness.light, 'settings'),
    ];
    for (final (name, size, sample, brightness, surface) in shots) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      debugPrint('SHOT $name');
      final core = sampleCore(sample);
      final state = AppState()..themeMode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
      if (sample != Sample.empty) state.open('t1');
      final voice = VoiceController(core)
        ..status = {
          'listen_ready': surface != 'settings',
          'natural_voice': false,
          'engine': 'windows',
          'downloading': <String, dynamic>{},
          'download_sizes_mb': {'listen': 145, 'speak': 120},
          'voices': {'af_heart': 'Heart (warm, US)'},
          'settings': {'speak_replies': true, 'voice': 'af_heart', 'speed': 1.05},
        };
      state.voice = voice;
      if (surface == 'listening') {
        voice
          ..listening = true
          ..level = .7
          ..partial = "find last month's invoices and put them in a";
      }
      if (surface == 'speaking') voice.speaking = true;
      if (surface == 'settings') state.go(Section.settings);
      final quick = QuickMode(state)
        ..active = true
        ..task = 't1';
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            theme: compiiTheme(Brightness.light),
            darkTheme: compiiTheme(Brightness.dark),
            themeMode: state.themeMode,
            home: MediaQuery(
              data: MediaQueryData(size: size, disableAnimations: true),
              child: surface == 'quick' ? QuickBar(core: core, quick: quick) : ConsoleScreen(core: core, state: state),
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
        final out = Directory('../../../docs/compii/build-previews/v3')..createSync(recursive: true);
        await tester.runAsync(() => File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
        image.dispose();
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
