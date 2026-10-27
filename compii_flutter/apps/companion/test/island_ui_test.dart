import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/island/island_actions.dart';
import 'package:compii/src/island/island_controller.dart';
import 'package:compii/src/island/island_geometry.dart';
import 'package:compii/src/island/island_platform.dart';
import 'package:compii/src/island/island_prefs.dart';
import 'package:compii/src/island/island_eyes.dart';
import 'package:compii/src/island/island_ui.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Set with --dart-define=CAPTURE=true to write the README's pictures.
const _capture = bool.fromEnvironment('CAPTURE');

/// A Core that never touches the network: the island only reads its state.
class _Core extends CoreClient {
  _Core() {
    bots = [
      BotView(id: 'bcompii', name: 'Compii', primary: true, trust: 'full'),
      BotView(id: 'bana', name: 'Ana', job: 'Research'),
    ];
    status = CoreStatus.online;
  }

  @override
  void start() {
    status = CoreStatus.online;
    notifyListeners();
  }

  void ping() => notifyListeners();

  void put(TaskView task) {
    tasks[task.id] = task;
    notifyListeners();
  }
}

class _Platform implements IslandPlatform {
  bool through = true;
  int restores = 0;
  final toasts = <(String, String)>[];
  String title = 'Visual Studio Code';
  bool fullscreen = false;

  @override
  Future<bool> claim() async => true;

  @override
  Future<Rect?> windowBounds() async => null;

  @override
  Future<void> moveTo(Offset physicalTopLeft) async {}

  @override
  Future<List<IslandDisplay>> displays() async => const <IslandDisplay>[];

  @override
  Future<Offset?> cursor() async => Offset.zero;

  @override
  Future<void> clickThrough(bool through) async => this.through = through;

  @override
  Future<void> focus() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<ForegroundWindow> foreground() async =>
      ForegroundWindow(handle: 42, title: title, fullscreen: fullscreen);

  @override
  Future<bool> restore(int handle) async {
    restores++;
    return true;
  }

  @override
  Future<bool> revealMain() async => true;

  @override
  Future<void> toast(String title, String body) async => toasts.add((title, body));
}

class _Actions implements IslandActions {
  final starts = <String>[];
  final replies = <String>[];

  @override
  Future<String> start(
    String text, {
    String? botId,
    List<String> attachments = const [],
    bool followOn = false,
  }) async {
    starts.add(text);
    return 't1';
  }

  @override
  Future<void> reply(
    String taskId,
    String text, {
    List<String> attachments = const [],
  }) async {
    replies.add(text);
  }

  @override
  Future<void> stop(String taskId) async {}

  @override
  Future<void> decide(String approvalId, {required bool approved}) async {}

  @override
  Future<void> answerQuestion(String questionId, String text) async {}

  @override
  Future<void> finishTakeover(
    String takeoverId, {
    String outcome = 'done',
  }) async {}

  @override
  Future<void> retry(String taskId) async {}

  @override
  Future<void> openInMain(String taskId) async {}

  int inboxOpens = 0;

  @override
  Future<void> openInbox() async => inboxOpens++;

  @override
  Future<Map<String, dynamic>?> attachScreen() async => {
    'path': 'C:/Compii/uploads/screen.png',
  };

  @override
  Future<List<Map<String, dynamic>>> pickFiles() async => const [];
}

TaskView _task({
  String id = 't1',
  String status = 'running',
  String request = 'Sort the receipts',
  List<Map<String, dynamic>> events = const [],
}) =>
    TaskView(id: id, request: request, status: status, botId: 'bcompii')
      ..events.addAll(events);

final _doneEvents = [
  {'type': 'task_started', 'at': 1},
  {
    'type': 'action_done',
    'tool': 'read_file',
    'label': 'Read receipt.pdf',
    'ok': true,
    'at': 2,
  },
  {
    'type': 'task_finished',
    'status': 'done',
    'text': 'Eleven receipts, £240 total.',
    'at': 3,
  },
];

final _failedEvents = [
  {'type': 'task_started', 'at': 1},
  {
    'type': 'task_finished',
    'status': 'failed',
    'text': 'Core stopped before finishing.',
    'at': 2,
  },
];

Future<void> _show(
  WidgetTester tester,
  IslandController c, {
  Size size = const Size(900, 1000),
  double textScale = 1,
  bool highContrast = false,
  bool disableAnimations = false,
  ValueChanged<IslandDock>? onDock,
  ValueChanged<String>? onShortcut,
  ValueChanged<IslandAttention>? onAttention,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context).copyWith(
            size: size,
            textScaler: TextScaler.linear(textScale),
            highContrast: highContrast,
            disableAnimations: disableAnimations,
          );
          return MediaQuery(
            data: data,
            child: Scaffold(
              backgroundColor: Colors.white,
              body: IslandView(
                controller: c,
                cardKey: GlobalKey(),
                shortcut: 'ctrl_alt_space',
                hotkeyError: null,
                onDock: onDock ?? (_) {},
                onResetLayout: () {},
                onShortcut: onShortcut ?? (_) {},
                onAttention: onAttention ?? (_) {},
                onRevealMain: () {},
                onDragStart: () {},
                onDragUpdate: () {},
                onDragEnd: () {},
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
}

Finder _sendButton() => find.byWidgetPredicate(
  (w) => w is IconButton && w.tooltip == 'Send (Enter)',
);

Finder _iconButton(String tooltip) =>
    find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// Let the pill finish growing into the card: the first pump starts the morph,
/// the second advances past its 380 ms.
Future<void> _grow(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 420));
}

/// The pill on the dark of a desktop rather than on a test page, wrapped in a
/// boundary that can be written out as a picture.
Future<void> _showOnDesktop(
  WidgetTester tester,
  IslandController c,
  GlobalKey boundary, {
  Size size = const Size(1100, 620),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: compiiTheme(Brightness.dark),
      home: Builder(
        builder: (context) {
          final data = MediaQuery.of(context).copyWith(size: size);
          return MediaQuery(
            data: data,
            child: Scaffold(
              backgroundColor: const Color(0xFF070617),
              body: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: const Color(0xFF070617),
                  child: IslandView(
                    controller: c,
                    cardKey: GlobalKey(),
                    shortcut: 'ctrl_alt_space',
                    hotkeyError: null,
                    onDock: (_) {},
                    onResetLayout: () {},
                    onShortcut: (_) {},
                    onAttention: (_) {},
                    onRevealMain: () {},
                    onDragStart: () {},
                    onDragUpdate: () {},
                    onDragEnd: () {},
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
}

/// A test run has no fonts, so words would come out as grey blocks. Loaded from
/// Windows the way the other capture tests do it, for pictures only.
Future<void> _loadIslandFonts(WidgetTester tester) async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await tester.runAsync(icons.load);
  for (final family in [
    'Segoe UI Variable Text',
    'Segoe UI Variable Display',
    'Roboto',
  ]) {
    final file = File('C:/Windows/Fonts/SegUIVar.ttf');
    if (!file.existsSync()) continue;
    await tester.runAsync(
      (FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(file.readAsBytesSync())),
            ))
          .load,
    );
  }
}

/// One state as the pixels say it. Reached only from a CAPTURE run.
Future<void> _writeOut(WidgetTester tester, GlobalKey boundary, String name) async {
  final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => render.toImage(pixelRatio: 2)))!;
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  final out = Directory('../../../docs/compii/build-previews')
    ..createSync(recursive: true);
  await tester.runAsync(
    () => File('${out.path}/island-$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List()),
  );
  image.dispose();
}

/// The island at rest is its eyes; that is what you click.
Finder _eyes() => find.byType(IslandEyes);

void main() {
  late _Core core;
  late _Actions actions;
  late _Platform platform;
  late IslandController c;

  setUp(() {
    core = _Core();
    actions = _Actions();
    platform = _Platform();
    c = IslandController(core: core, actions: actions, platform: platform);
  });

  tearDown(() => c.dispose());

  testWidgets(
    'the compact capsule is quiet: no idle movement and no progress theatre',
    (tester) async {
      await _show(tester, c);
      expect(find.text('Ask Compii'), findsNothing, reason: 'at rest it is only the eyes');
      expect(_eyes(), findsOneWidget);

      final before = tester.getCenter(_eyes());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.getCenter(_eyes()),
        before,
        reason: 'nothing moves while idle',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets('the pill is never narrower than the words it carries', (
    tester,
  ) async {
    Future<void> fits(String label) async {
      expect(find.text(label), findsOneWidget);
      final style = tester.widget<Text>(find.text(label)).style!;
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(tester.element(find.text(label))),
      )..layout();
      expect(
        tester.getSize(find.text(label)).width,
        greaterThanOrEqualTo(painter.width - .5),
        reason: '"$label" must not be ellipsized',
      );
    }

    await _show(tester, c);
    core.status = CoreStatus.offline;
    core.ping();
    await tester.pump();
    await fits('Offline');
    core.status = CoreStatus.online;
    core.put(_task());
    await tester.pump();
    await fits('Working');
  });

  testWidgets('a tap opens the ask card with the caret already in the field', (
    tester,
  ) async {
    await _show(tester, c);
    await tester.tap(_eyes());
    await tester.pump();

    expect(c.stage, IslandStage.ask);
    expect(find.text('Ask anything…'), findsOneWidget);
    expect(find.textContaining('Enter to send'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets(
    'an ask shows honest progress while Core has not reported the thread yet',
    (tester) async {
      await _show(tester, c);
      await tester.tap(_eyes());
      await _grow(tester);

      await tester.enterText(find.byType(TextField), 'Sort the receipts');
      await tester.pump();
      await tester.tap(_sendButton());
      await tester.pump();

      expect(actions.starts, ['Sort the receipts']);
      expect(find.text('Compii is picking it up…'), findsOneWidget);
      expect(find.text('Sending to Compii…'), findsNothing);
      expect(find.text('This conversation is no longer here.'), findsNothing);
      expect(c.stage, IslandStage.working);
    },
  );

  testWidgets(
    'the real thread appears as it runs, then restrains itself when done',
    (tester) async {
      await _show(tester, c);
      await tester.tap(_eyes());
      await _grow(tester);
      await tester.enterText(find.byType(TextField), 'Sort the receipts');
      await tester.pump();
      await tester.tap(_sendButton());
      await tester.pump();

      core.put(
        _task(
          events: [
            {'type': 'task_started', 'at': 1},
            {
              'type': 'plan',
              'at': 2,
              'steps': [
                {'text': 'Read the receipts'},
                {'text': 'Add them up'},
              ],
            },
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Sort the receipts'), findsOneWidget);
      expect(find.text('Planning'), findsWidgets);
      expect(find.text('Stop'), findsOneWidget);
      expect(
        find.textContaining('%'),
        findsNothing,
        reason: 'no invented progress',
      );
      await tester.tap(_iconButton('Recent conversations'));
      await tester.pump();
      expect(find.text('New ask'), findsOneWidget);
      await tester.tap(_iconButton('Recent conversations'));
      await tester.pump();

      core.tasks['t1']!
        ..status = 'done'
        ..events.addAll(_doneEvents.sublist(2));
      core.ping();
      await tester.pump();

      expect(c.stage, IslandStage.completed);
      expect(find.text('Eleven receipts, £240 total.'), findsOneWidget);
      expect(find.text('Done'), findsWidgets);
      expect(find.text('Try again'), findsNothing);
      expect(find.textContaining('Finished'), findsWidgets);
      expect(find.text('Stop'), findsNothing);
      await _close(tester);
    },
  );

  testWidgets(
    'an approval shows the exact step, both decisions, and what approving does not cover',
    (tester) async {
      core.put(
        _task(
          events: [
            {'type': 'task_started', 'at': 1},
            {
              'type': 'approval_needed',
              'approval_id': 'ap1',
              'kind': 'send',
              'at': 2,
              'label': 'Email Sam the sorted list',
              'input': {'to': 'sam@example.com'},
            },
          ],
        ),
      );
      await c.openTask('t1');
      await _show(tester, c);

      expect(find.text('Needs your okay'), findsWidgets);
      expect(find.text('Email Sam the sorted list'), findsOneWidget);
      expect(find.text('sam@example.com'), findsOneWidget);
      // Named after the action, as on the Halo canvas's Approval board: an email is sent or not sent.
      expect(find.text('Send it'), findsOneWidget);
      expect(find.text('Don’t send'), findsOneWidget);
      expect(
        find.textContaining('Approving covers this step only'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failure is shown as failure, with a retry only where retrying helps',
    (tester) async {
      core.put(_task(status: 'failed', events: _failedEvents));
      await c.openTask('t1');
      await _show(tester, c);

      expect(find.text('Didn’t finish'), findsWidgets);
      expect(find.text('Compii stopped before finishing'), findsOneWidget);
      expect(find.text('Core stopped before finishing.'), findsOneWidget);
      expect(find.text('Try again'), findsWidgets);
      expect(c.stage, IslandStage.failed);
      await _close(tester);
    },
  );

  testWidgets(
    'an unreachable Core keeps the words and offers a reconnect, not a fake send',
    (tester) async {
      core.status = CoreStatus.offline;
      await _show(tester, c);
      expect(find.text('Offline'), findsOneWidget);
      await tester.tap(find.text('Offline'));
      await _grow(tester);
      await tester.enterText(find.byType(TextField), 'Still there?');
      await tester.pump();
      await tester.tap(_sendButton());
      await tester.pump();

      expect(actions.starts, isEmpty);
      expect(find.textContaining('reconnects by itself'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(c.draft.text, 'Still there?');
    },
  );

  testWidgets('recent conversations are listed and open from the island', (
    tester,
  ) async {
    core.put(
      _task(
        id: 't2',
        request: 'Plan the trip',
        status: 'done',
        events: _doneEvents,
      ),
    );
    core.put(
      _task(request: 'Sort the receipts', status: 'done', events: _doneEvents),
    );
    await _show(tester, c);
    await tester.tap(_eyes());
    await _grow(tester);
    await tester.tap(_iconButton('Recent conversations'));
    await tester.pump();

    expect(find.text('Plan the trip'), findsOneWidget);
    expect(find.text('Sort the receipts'), findsOneWidget);

    await tester.tap(find.text('Plan the trip'));
    await tester.pump();
    expect(c.taskId, 't2');
    expect(c.stage, IslandStage.completed);
    await _close(tester);
  });

  testWidgets(
    'the capsule menu offers placement, reset, the wake shortcut, and the main window',
    (tester) async {
      IslandDock? dock;
      String? shortcut;
      await _show(
        tester,
        c,
        onDock: (d) => dock = d,
        onShortcut: (s) => shortcut = s,
      );

      await tester.tap(_eyes(), buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(find.text('PLACEMENT'), findsOneWidget);
      expect(find.text('Top centre'), findsOneWidget);
      expect(find.text('WAKE SHORTCUT'), findsOneWidget);

      await tester.tap(find.text('Top left'));
      await tester.pump();
      expect(dock, IslandDock.left);
      expect(
        find.text('PLACEMENT'),
        findsNothing,
        reason: 'the menu closes after a choice',
      );

      await tester.tap(_eyes(), buttons: kSecondaryMouseButton);
      await tester.pump();
      await tester.tap(find.text(IslandShortcuts.label('f8')));
      await tester.pump();
      expect(shortcut, 'f8');
    },
  );

  testWidgets('the capsule menu chooses how loudly Compii tells you', (
    tester,
  ) async {
    IslandAttention? chosen;
    await _show(tester, c, onAttention: (a) => chosen = a);

    await tester.tap(_eyes(), buttons: kSecondaryMouseButton);
    await tester.pump();
    expect(find.text('WHEN COMPII NEEDS YOU'), findsOneWidget);
    expect(find.text('Tell me: Mark and a notification'), findsOneWidget);

    await tester.tap(find.text('Tell me: Mark and a notification'));
    await tester.pump();
    expect(chosen, IslandAttention.expanded);
    expect(
      find.text('Tell me: Mark and a notification'),
      findsNothing,
      reason: 'the menu closes after a choice',
    );
  });

  testWidgets(
    'a thread waiting while you are elsewhere is offered inside the composer',
    (tester) async {
      await _show(tester, c);
      core.put(
        _task(
          id: 't9',
          events: [
            {'type': 'task_started'},
            {
              'type': 'approval_needed',
              'approval_id': 'ap1',
              'kind': 'send',
              'label': 'Email Sam the sorted list',
            },
          ],
        ),
      );
      core.ping();
      await tester.pump();
      expect(c.isOpen, isFalse, reason: 'a notification does not open a card');
      expect(c.capsuleLabel, 'Needs your okay');

      await c.openAsk();
      await _grow(tester);
      expect(find.textContaining('Compii needs your OK'), findsOneWidget);

      await tester.tap(find.textContaining('Compii needs your OK'));
      await tester.pump();
      expect(c.taskId, 't9');
      expect(c.phase, IslandPhase.approval);
      expect(
        find.text('Send it'),
        findsOneWidget,
        reason: 'an approval with no detail fields is still answerable',
      );
      expect(c.backgroundAttention, isNull, reason: 'you are looking at it now');
      await _close(tester);
    },
  );

  testWidgets('what you add while Compii works waits in the thread, and comes back on request', (
    tester,
  ) async {
    core.put(
      _task(
        id: 't9',
        events: [
          {'type': 'task_started'},
          {'type': 'action_started', 'tool': 'read_file'},
        ],
      ),
    );
    await c.openTask('t9');
    await _show(tester, c);

    await tester.enterText(find.byType(TextField), 'It is the March one');
    await tester.tap(find.byTooltip('Queue for the end of this turn'));
    await tester.pump();

    expect(actions.replies, isEmpty, reason: 'a running step is not interrupted');
    expect(find.textContaining('It is the March one'), findsOneWidget);
    expect(find.text('Take back'), findsOneWidget);

    await tester.tap(find.text('Take back'));
    await tester.pump();
    expect(c.queuedText, isNull);
    expect(find.text('It is the March one'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('news with no conversation of its own marks the pill and waits in the composer', (
    tester,
  ) async {
    c.setAttention(IslandAttention.indicator);
    await _show(tester, c);
    core.updates.add({
      'type': 'update',
      'id': 'u1',
      'kind': 'brief',
      'title': 'Your brief for Friday',
      'body': 'Three things worth reading.',
      'task_id': '',
    });
    core.ping();
    await tester.pump();

    expect(find.text('New from Compii'), findsOneWidget);
    expect(c.isOpen, isFalse, reason: 'a mark is not a card');

    await c.openAsk();
    await _grow(tester);
    expect(find.text('Your brief for Friday'), findsOneWidget);

    await tester.tap(find.text('Your brief for Friday'));
    await tester.pump();
    expect(actions.inboxOpens, 1);
    expect(c.newsCount, 0, reason: 'you have now been shown it');
    await _close(tester);
  });

  testWidgets('reduced motion really removes the transition durations', (
    tester,
  ) async {
    await _show(tester, c, disableAnimations: true);
    final capsule = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    expect(capsule.duration, Duration.zero);
  });

  for (final size in [const Size(900, 1000), const Size(480, 900)]) {
    testWidgets(
      'every state stays whole at 2x type on ${size.width.round()}x${size.height.round()}',
      (tester) async {
        await _show(tester, c, size: size, textScale: 2, highContrast: true);
        expect(tester.takeException(), isNull);

        await c.openAsk();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Ask anything…'), findsOneWidget);

        core.put(_task(status: 'done', events: _doneEvents));
        await c.openTask('t1');
        await tester.pump();
        expect(tester.takeException(), isNull);
        // ignore: avoid_print
        expect(find.text('Eleven receipts, £240 total.'), findsOneWidget);

        core.put(_task(status: 'failed', events: _failedEvents));
        await c.openTask('t1');
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Try again'), findsWidgets);
        await _close(tester);
      },
    );
  }

  // The README shows the pill as it really draws, so these reuse the fakes and
  // the pumps the rest of the suite already trusts. Nothing is written unless
  // asked for with --dart-define=CAPTURE=true, so a normal run stays headless.
  final sheet = GlobalKey();

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Size size,
    Future<void> Function()? drive,
  }) async {
    await _loadIslandFonts(tester);
    await _showOnDesktop(tester, c, sheet, size: size);
    if (drive != null) await drive();
    // The card's height animates by a fraction of the surface, so let it land
    // before writing: a shot taken mid-morph crops what it is meant to show.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await _writeOut(tester, sheet, name);
  }

  testWidgets('writes the capsule for the README', (tester) async {
    if (!_capture) return;
    await shoot(tester, 'capsule', size: const Size(760, 130));
  });

  testWidgets('writes the capsule with something to say', (tester) async {
    if (!_capture) return;
    core.put(
      _task(
        id: 't1',
        events: [
          {'type': 'task_started'},
          {
            'type': 'approval_needed',
            'approval_id': 'ap1',
            'kind': 'send',
            'label': 'Email Sam the sorted list',
          },
        ],
      ),
    );
    await shoot(tester, 'capsule-busy', size: const Size(760, 130));
  });

  testWidgets('writes the composer for the README', (tester) async {
    if (!_capture) return;
    await shoot(
      tester,
      'ask',
      size: const Size(1100, 1200),
      drive: () async {
        await c.openAsk(stealFocus: false);
        await _grow(tester);
      },
    );
  });

  testWidgets('writes a running thread for the README', (tester) async {
    if (!_capture) return;
    core.put(
      _task(
        id: 't1',
        events: [
          {'type': 'task_started'},
          {
            'type': 'action_done',
            'tool': 'find_files',
            'label': 'Found 12 in Downloads',
            'ok': true,
          },
          {
            'type': 'action_started',
            'tool': 'spreadsheet',
            'label': 'Build the sheet',
          },
        ],
      ),
    );
    await shoot(
      tester,
      'working',
      size: const Size(1100, 1100),
      drive: () async {
        await c.openTask('t1', stealFocus: false);
        await _grow(tester);
      },
    );
  });

  testWidgets('writes an approval for the README', (tester) async {
    if (!_capture) return;
    core.put(
      _task(
        id: 't1',
        events: [
          {'type': 'task_started'},
          {
            'type': 'approval_needed',
            'approval_id': 'ap1',
            'kind': 'send',
            'label': 'Email Sam the sorted list',
            'detail': {'to': 'sam@example.com', 'subject': 'Receipts'},
          },
        ],
      ),
    );
    await shoot(
      tester,
      'approval',
      size: const Size(1100, 1100),
      drive: () async {
        await c.openTask('t1', stealFocus: false);
        await _grow(tester);
      },
    );
  });

  testWidgets('writes a finished answer for the README', (tester) async {
    if (!_capture) return;
    core.put(_task(id: 't1', status: 'done', events: _doneEvents));
    await shoot(
      tester,
      'done',
      size: const Size(1100, 1100),
      drive: () async {
        await c.openTask('t1', stealFocus: false);
        await _grow(tester);
      },
    );
  });
}
