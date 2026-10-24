// A teammate can be given an AI of its own. These tests keep the two honest things that have to
// happen: the app sends the user's choice to Core, and every page names the AI that is really
// answering rather than the one the user once picked.
import 'package:compii/src/console/console_screen.dart';
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/bots.dart';
import 'package:compii/src/ui/shell.dart' show AppState;
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _compii = 'bcompii';
const _anaId = 'bana';

const _ais = [
  {'provider': 'groq', 'label': 'Groq', 'model': 'openai/gpt-oss-120b', 'where': '', 'price': '', 'hasKey': true},
  {'provider': 'mistral', 'label': 'Mistral', 'model': 'mistral-large-latest', 'where': '', 'price': '',
    'hasKey': false},
];

BotView _ana({String provider = '', String model = '', String answersWith = '', String modelNote = ''}) => BotView(
      id: _anaId,
      name: 'Ana',
      job: 'Research',
      avatar: 'a1.gem.11',
      color: '#E08BD0',
      provider: provider,
      model: model,
      answersWith: answersWith,
      modelNote: modelNote,
    );

class _Recorded extends CoreClient {
  _Recorded() {
    bots = [
      BotView(id: _compii, name: 'Compii', primary: true, trust: 'full', avatar: 'a1.orb.1'),
      _ana(),
    ];
    primaryBotId = _compii;
    aiPresets = List.of(_ais);
  }

  final List<Map<String, Object?>> edits = [];
  final List<Map<String, dynamic>> creates = [];

  @override
  Future<void> fetchBrain() async {
    // The list the test already put in `aiPresets` stands in for Core's; no socket is opened.
  }

  @override
  Future<List<TaskView>> fetchConversations(String botId) async => const [];

  @override
  Future<void> editBot(String id, Map<String, Object?> changes) async => edits.add({'id': id, ...changes});

  @override
  Future<void> createBot({
    required String name,
    String template = '',
    String job = '',
    String instructions = '',
    String color = '',
    String avatar = '',
    String mode = '',
    List<String>? tools,
    String provider = '',
    String model = '',
  }) async =>
      creates.add({'name': name, 'provider': provider, 'model': model});
}

Future<void> _openEditor(WidgetTester tester, CoreClient core, {BotView? bot}) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  await tester.pumpWidget(MaterialApp(
    theme: compiiTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showBotEditor(context, core: core, state: state, run: (f) => f(), bot: bot),
          child: const Text('Edit'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Edit'));
  await tester.pump();
}

/// The editor scrolls, so a choice further down the form has to be brought into view first.
Future<void> _reveal(WidgetTester tester, Finder what) => tester.ensureVisible(what);

Future<void> _showBotHome(WidgetTester tester, CoreClient core, BotView bot) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: compiiTheme(Brightness.light),
    home: MediaQuery(
      data: const MediaQueryData(size: Size(1440, 900), disableAnimations: true),
      child: ConsoleScreen(core: core, state: AppState()..pickBot(bot.id)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  test('a teammate’s page names the AI that answers it', () {
    expect(aiLine(_ana()), isNot(contains('groq')));
    expect(aiLine(_ana(provider: 'groq', answersWith: 'groq · openai/gpt-oss-120b')),
        'Answers with groq · openai/gpt-oss-120b — its own AI, not Compii’s.');
    // A choice that can't be built is said out loud instead of quietly swapped for another model.
    expect(aiLine(_ana(provider: 'mistral', modelNote: 'No key for Mistral yet.')),
        contains('Wanted mistral, but it can’t run yet: No key for Mistral yet.'));
  });

  testWidgets('the editor offers the AIs Compii knows and sends the one picked', (tester) async {
    final core = _Recorded();
    await _openEditor(tester, core, bot: core.bots[1]);
    expect(find.text('Answers with'), findsOneWidget);
    expect(find.text('Groq'), findsOneWidget);
    expect(find.text('Mistral'), findsOneWidget);

    await _reveal(tester, find.text('Groq'));
    await tester.tap(find.text('Groq'));
    await tester.pump();
    expect(find.textContaining('Thinks with Groq · openai/gpt-oss-120b'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(core.edits.single['id'], _anaId);
    expect(core.edits.single['provider'], 'groq');
    expect(core.edits.single['model'], 'openai/gpt-oss-120b');
  });

  testWidgets('an AI with no key is offered, but the app says it can’t answer yet', (tester) async {
    final core = _Recorded();
    await _openEditor(tester, core, bot: core.bots[1]);
    await _reveal(tester, find.text('Mistral'));
    await tester.tap(find.text('Mistral'));
    await tester.pump();
    expect(
      find.textContaining('Mistral needs a key in Settings → Brain.'),
      findsOneWidget,
      reason: 'the user is told what happens to this choice until a key exists',
    );
  });

  testWidgets('sending a teammate back to Compii’s AI clears its choice', (tester) async {
    final core = _Recorded();
    core.bots[1] = _ana(provider: 'groq', model: 'openai/gpt-oss-120b');
    await _openEditor(tester, core, bot: core.bots[1]);
    await _reveal(tester, find.text('Compii’s AI'));
    await tester.tap(find.text('Compii’s AI'));
    await tester.pump();
    expect(find.textContaining('Thinks with the AI you chose in Settings → Brain.'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(core.edits.single['provider'], '');
    expect(core.edits.single['model'], '');
  });

  testWidgets('Compii itself is never offered a model of its own', (tester) async {
    final core = _Recorded();
    await _openEditor(tester, core, bot: core.bots.first);
    expect(find.text('Answers with'), findsNothing);
    expect(find.text('Groq'), findsNothing);
  });

  testWidgets('a new teammate can be created already thinking with its own AI', (tester) async {
    final core = _Recorded();
    await _openEditor(tester, core);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Bram');
    await tester.pump();
    await _reveal(tester, find.text('Groq'));
    await tester.tap(find.text('Groq'));
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pump();
    await tester.pump();
    expect(core.creates.single['name'], 'Bram');
    expect(core.creates.single['provider'], 'groq');
    expect(core.creates.single['model'], 'openai/gpt-oss-120b');
  });

  testWidgets('a conversation header names the AI thinking behind it', (tester) async {
    final core = _Recorded();
    core.tasks['t1'] = TaskView(
      id: 't1',
      request: 'find the invoices from september',
      status: 'done',
      botId: _anaId,
      ownerId: _anaId,
      answersWith: 'groq · openai/gpt-oss-120b',
    )..events.addAll([
        {'type': 'task_started', 'at': 0, 'bot_id': _anaId},
        {'type': 'task_finished', 'status': 'done', 'text': 'Nine of them.', 'at': 1, 'bot_id': _anaId},
      ]);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: compiiTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1440, 900), disableAnimations: true),
        child: ConsoleScreen(core: core, state: AppState()..open('t1')..setChatView(true)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'conversation header');
    expect(find.text('groq · openai/gpt-oss-120b'), findsOneWidget);
  });

  testWidgets('a teammate’s page names the AI behind it', (tester) async {
    final core = _Recorded();
    core.bots[1] = _ana(provider: 'groq', model: 'openai/gpt-oss-120b', answersWith: 'groq · openai/gpt-oss-120b');
    await _showBotHome(tester, core, core.bots[1]);
    expect(tester.takeException(), isNull, reason: 'bot home');
    expect(find.textContaining('Answers with groq · openai/gpt-oss-120b'), findsOneWidget);
  });

  testWidgets('a teammate whose own AI can’t run says so on its page', (tester) async {
    final core = _Recorded();
    core.bots[1] = _ana(provider: 'mistral', model: 'mistral-large-latest', modelNote: 'No key for Mistral yet.');
    await _showBotHome(tester, core, core.bots[1]);
    expect(tester.takeException(), isNull, reason: 'bot home');
    expect(find.textContaining('Wanted mistral, but it can’t run yet: No key for Mistral yet.'), findsOneWidget);
  });
}
