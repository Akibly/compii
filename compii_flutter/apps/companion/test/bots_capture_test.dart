// Renders a bot's own home and the bot editor with sample data (no Core needed).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/console_screen.dart';
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CoreClient _core() {
  final core = CoreClient()
    ..status = CoreStatus.online
    ..brain = 'opencode_go';
  core.bots = [
    BotView(id: 'b1', name: 'Compii', job: 'Your right hand on this PC', primary: true),
    BotView(
      id: 'b2',
      name: 'Inbox Manager',
      job: 'Triage mail and leave replies ready to send',
      avatar: 'a1.capsule.12',
      color: '#6FC9E8',
      facts: ['Replies stay under 80 words.', 'Fridays are meeting-free.', 'Escalate anything from the bank.'],
    ),
    BotView(id: 'b3', name: 'Researcher', job: 'Turns a question into a sourced brief', color: '#7C9CFF', pinned: true),
  ];
  core.primaryBotId = 'b1';
  final now = DateTime.now().millisecondsSinceEpoch / 1000;
  String iso(double secondsFromNow) =>
      DateTime.fromMillisecondsSinceEpoch(((now + secondsFromNow) * 1000).round()).toIso8601String();
  core.plansCache = {
    'routines': [
      {
        'id': 'r1',
        'title': 'Morning mail triage',
        'instruction': 'Sort today’s mail and leave replies ready.',
        'schedule': {'kind': 'weekdays', 'at': '08:00'},
        'when': 'Every weekday at 08:00',
        'enabled': true,
        'next_run': iso(12 * 3600),
        'last_run': iso(-24 * 3600),
        'last_task': 't1',
        'bot_id': 'b2',
        'runs': [
          {'at': iso(-24 * 3600), 'task_id': 't1', 'status': 'done'},
          {'at': iso(-48 * 3600), 'task_id': 't0', 'status': 'failed'},
        ],
      },
      {
        'id': 'r2',
        'title': 'Friday research brief',
        'instruction': 'Summarise the week in my field with links.',
        'schedule': {'kind': 'weekly', 'days': ['fri'], 'at': '16:00'},
        'when': 'Every Fri at 16:00',
        'enabled': true,
        'next_run': iso(48 * 3600),
        'last_run': null,
        'last_task': null,
        'bot_id': 'b3',
        'runs': [],
      },
      {
        'id': 'r3',
        'title': 'Tidy Downloads',
        'instruction': 'Sort new files in Downloads by type.',
        'schedule': {'kind': 'daily', 'at': '18:00'},
        'when': 'Every day at 18:00',
        'enabled': false,
        'next_run': iso(20 * 3600),
        'last_run': iso(-3 * 3600),
        'last_task': 't2',
        'bot_id': null,
        'runs': [
          {'at': iso(-3 * 3600), 'task_id': 't2', 'status': 'running'},
        ],
      },
    ],
    'watches': [],
    'inbox': [],
    'unread': 0,
    'brief': {'enabled': true, 'at': '08:00', 'last': null},
    'error': null,
  };
  final done = TaskView(id: 't1', request: 'Triage today’s mail and flag what needs me', status: 'done', botId: 'b2')
    ..events.addAll([
      {'type': 'task_started', 'at': now - 4000},
      {'type': 'task_finished', 'status': 'done', 'text': 'Two things need you: the lease renewal and the bank notice.', 'at': now - 3920},
    ]);
  core.tasks[done.id] = done;
  final running = TaskView(id: 't2', request: 'Compare three budget laptops for writing', status: 'running', botId: 'b3')
    ..events.add({'type': 'task_started', 'at': now - 40});
  core.tasks[running.id] = running;
  return core;
}

Future<void> _loadFonts(WidgetTester tester) async {
  final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await tester.runAsync(icons.load);
  for (final family in ['Segoe UI Variable Text', 'Segoe UI Variable Display', 'Roboto']) {
    final loader = FontLoader(family);
    for (final f in ['SegUIVar.ttf']) {
      final file = File('C:/Windows/Fonts/$f');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await tester.runAsync(loader.load);
  }
  final emoji = File('C:/Windows/Fonts/seguiemj.ttf');
  if (emoji.existsSync()) {
    await tester.runAsync((FontLoader('Segoe UI Emoji')
          ..addFont(Future.value(ByteData.sublistView(emoji.readAsBytesSync()))))
        .load);
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name, {String folder = 'g1'}) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(boundary.toImage))!;
  final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  final out = Directory('../../../docs/compii/build-previews/$folder')..createSync(recursive: true);
  await tester.runAsync(() => File('${out.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
  debugPrint('SHOT ${out.path}/$name.png');
}

Widget _app(CoreClient core, AppState state, GlobalKey key) => RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: compiiTheme(Brightness.light),
        darkTheme: compiiTheme(Brightness.dark),
        themeMode: ThemeMode.light,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900), disableAnimations: true),
          child: ConsoleScreen(core: core, state: state),
        ),
      ),
    );

void main() {
  testWidgets('a bot home and its editor render', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final core = _core();
    final state = AppState()..pickBot('b2');
    final key = GlobalKey();
    await tester.pumpWidget(_app(core, state, key));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'bot home');
    expect(find.text('Inbox Manager'), findsWidgets);
    expect(find.text('REMEMBERS'), findsOneWidget);
    expect(find.text('ROUTINES'), findsOneWidget);
    expect(find.text('Morning mail triage'), findsOneWidget);
    if (capture) await _shot(tester, key, 'bot-home');

    await tester.tap(find.text('Edit'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'bot editor');
    expect(find.text('How it works'), findsOneWidget);
    expect(find.text('WHAT INBOX MANAGER REMEMBERS'), findsOneWidget);
    if (capture) await _shot(tester, key, 'bot-editor');
  });

  testWidgets('the routines page shows owners, history and an editor', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final core = _core();
    final state = AppState()..go(Section.routines);
    final key = GlobalKey();
    await tester.pumpWidget(_app(core, state, key));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'routines page');
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Scheduled'), findsOneWidget);
    expect(find.text('Teach a task'), findsOneWidget);
    // Each routine appears once in the week view and once in the list.
    expect(find.text('Morning mail triage'), findsWidgets);
    expect(find.text('Friday research brief'), findsWidgets);
    expect(find.text('Inbox Manager'), findsWidgets);
    if (capture) await _shot(tester, key, 'routines', folder: 'g3');

    // The list tile (below the week view) opens the studio.
    final tile = find.text('Morning mail triage').last;
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'routine studio');
    expect(find.text('WHAT IT DOES'), findsOneWidget);
    expect(find.text('RUN HISTORY'), findsOneWidget);
    expect(find.text('NEXT RUN'), findsOneWidget);
    expect(find.text('KEPT RUNS'), findsOneWidget);
    expect(find.text('Run now'), findsOneWidget);
    expect(find.text('failed'), findsOneWidget);
    if (capture) await _shot(tester, key, 'routine-studio', folder: 'g3');

    await tester.tap(find.text('Edit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'routine editor');
    expect(find.text('Edit routine'), findsOneWidget);
    if (capture) await _shot(tester, key, 'routine-editor', folder: 'g3');
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('WHAT IT DOES'), findsOneWidget);
  });

  testWidgets('a team home and a handoff in the thread render', (tester) async {
    const capture = bool.fromEnvironment('CAPTURE');
    if (capture) await _loadFonts(tester);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final core = _core();
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final teamTask = TaskView(
      id: 't3',
      request: 'Clear my inbox and research a laptop',
      status: 'done',
      botId: 'b3',
      team: ['b1', 'b2', 'b3'],
    )..events.addAll([
        {'type': 'task_started', 'at': now - 300, 'team': ['b1', 'b2', 'b3']},
        {
          'type': 'handoff',
          'at': now - 260,
          'from_id': 'b2',
          'from': 'Inbox Manager',
          'to_id': 'b3',
          'to': 'Researcher',
          'note': 'Two mail items need replies; compare three laptops under €900.',
          'by': 'bot',
        },
        {'type': 'task_finished', 'status': 'done', 'text': 'Inbox is sorted; the laptop brief is below.', 'at': now - 200},
      ]);
    core.tasks[teamTask.id] = teamTask;
    final state = AppState()..pickTeam(['b1', 'b2', 'b3']);
    final key = GlobalKey();
    await tester.pumpWidget(_app(core, state, key));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'team home');
    expect(find.text('Your team'), findsOneWidget);
    expect(find.text('WHO IS HERE'), findsOneWidget);
    if (capture) await _shot(tester, key, 'team-home', folder: 'g2');

    state.chatView = true;
    state.open('t3');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'team thread');
    expect(find.textContaining('teammates'), findsWidgets);
    expect(find.textContaining('compare three laptops'), findsOneWidget);
    if (capture) await _shot(tester, key, 'team-thread', folder: 'g2');
  });
}
