// The agents directory: find a teammate, narrow the team to one kind of work, and start a new
// one from an existing one. Every number and label here comes from what Core said about the bot.
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/chrome.dart' show Keyable;
import 'package:compii/src/ui/shell.dart' show AppState;
import 'package:compii/src/ui/team.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorded extends CoreClient {
  _Recorded() {
    bots = [
      BotView(id: 'bcompii', name: 'Compii', primary: true, trust: 'full', avatar: 'a1.orb.1'),
      BotView(id: 'bana', name: 'Ana', job: 'Research', avatar: 'a1.gem.11', template: 'researcher',
          category: 'Research', provider: 'groq', model: 'openai/gpt-oss-120b',
          answersWith: 'groq · openai/gpt-oss-120b'),
      BotView(id: 'binbox', name: 'Inbox Manager', job: 'Triage mail', avatar: 'a1.capsule.12',
          template: 'inbox', category: 'Personal', tools: ['mail']),
      BotView(id: 'bnite', name: 'Night Auditor', job: 'Reconciles the till', avatar: 'a1.orb.42'),
      BotView(id: 'baway', name: 'Dana', job: 'Nightly audit', avatar: 'a1.gem.7', archived: true),
    ];
    primaryBotId = 'bcompii';
    botPacks = [
      {'key': 'mail', 'label': 'Mail & calendar'},
      {'key': 'web', 'label': 'Web & research'},
    ];
  }

  final List<Map<String, dynamic>> creates = [];
  final List<(String, Map<String, Object?>)> edits = [];
  final Map<String, List<TaskView>> conversations = {
    'bana': [TaskView(id: 't2', request: 'Compare two laptops', status: 'done')],
    'binbox': [TaskView(id: 't1', request: 'Triage last week’s mail', status: 'done')],
  };

  @override
  Future<List<TaskView>> fetchConversations(String botId) async => conversations[botId] ?? const [];

  @override
  Future<void> editBot(String id, Map<String, Object?> changes) async {
    edits.add((id, changes));
    final bot = bots.firstWhere((b) => b.id == id);
    if (changes['archived'] is bool) bot.archived = changes['archived']! as bool;
    if (changes['pinned'] is bool) bot.pinned = changes['pinned']! as bool;
  }

  @override
  Future<void> fetchBrain() async {}

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
      creates.add({
        'name': name,
        'template': template,
        'job': job,
        'tools': tools,
        'provider': provider,
        'model': model,
      });
}

Future<void> _show(WidgetTester tester, CoreClient core,
    {Size size = const Size(1440, 1400), double scale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: compiiTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: Scaffold(body: TeamPage(core: core, state: AppState(), run: (f) => f())),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the team lists every teammate with what it thinks with', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    expect(tester.takeException(), isNull, reason: 'team page');
    expect(find.text('Inbox Manager'), findsOneWidget);
    expect(find.text('Night Auditor'), findsOneWidget);
    expect(find.text('Ana'), findsWidgets, reason: 'once in the directory, once as the teammate on show');
    // Ana was given an AI of her own; the card says which one is answering.
    expect(find.textContaining('groq · openai/gpt-oss-120b'), findsOneWidget);
    expect(find.text('Every kind'), findsOneWidget);
  });

  testWidgets('a search narrows the directory and says when nothing matches', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    await tester.enterText(find.byType(TextField).first, 'audit');
    await tester.pump();
    expect(find.text('Night Auditor'), findsWidgets);
    expect(find.text('Inbox Manager'), findsNothing);
    expect(find.text('TEAMMATES'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'nothing here');
    await tester.pump();
    expect(find.text('Night Auditor'), findsNothing);
    expect(find.textContaining('No teammate matches “nothing here”. There are 3 in the team.'), findsOneWidget);
    await tester.tap(find.text('Show everyone'));
    await tester.pump();
    expect(find.text('Inbox Manager'), findsOneWidget);
  });

  testWidgets('the team can be narrowed to one kind of work', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    // Only the roles Core grouped: a teammate the user wrote themselves has no kind.
    expect(find.text('Every kind'), findsOneWidget);
    expect(find.text('Research'), findsWidgets);

    await tester.tap(find.text('Personal').last);
    await tester.pump();
    expect(find.text('Inbox Manager'), findsWidgets);
    expect(find.text('Ana'), findsNothing);
    expect(find.text('Night Auditor'), findsNothing);

    await tester.tap(find.text('Every kind'));
    await tester.pump();
    expect(find.text('Night Auditor'), findsOneWidget);
  });

  testWidgets('a teammate can be started from an existing one', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    await tester.ensureVisible(find.byTooltip('Start another like this').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Start another like this').first);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);
    // The copy starts as itself: same job, same lane, a name that doesn't collide.
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Name')).controller!.text, 'Ana copy');
    expect(find.text('Research'), findsWidgets);

    await tester.tap(find.text('Create'));
    await tester.pump();
    await tester.pump();
    expect(core.creates.single['name'], 'Ana copy');
    expect(core.creates.single['template'], 'researcher');
    expect(core.creates.single['job'], 'Research');
    expect(core.creates.single['provider'], 'groq', reason: 'a copy starts on the same AI');
    expect(core.creates.single['model'], 'openai/gpt-oss-120b');
  });

  testWidgets('a put-away teammate waits behind one switch and comes back from there', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    expect(find.text('Dana'), findsNothing, reason: 'the team you work from is the team on duty');
    expect(find.text('Archive (1)'), findsOneWidget);

    await tester.tap(find.text('Archive (1)'));
    await tester.pump();
    expect(find.text('ARCHIVED TEAMMATES'), findsOneWidget);
    expect(find.text('Dana'), findsWidgets);
    expect(find.text('Ana'), findsNothing, reason: 'the archive shows the put-away, not the team');
    expect(find.text('TEAMMATES'), findsNothing);
    expect(find.text('Put away — no new work reaches it until it comes back'), findsOneWidget);

    await tester.tap(find.text('Bring back'));
    await tester.pump();
    expect(core.edits.single.$1, 'baway');
    expect(core.edits.single.$2['archived'], isFalse);
  });

  testWidgets('archiving asks first and keeps the teammate if you say no', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    // The directory opens on the first teammate; pick the one to archive.
    await tester.tap(find.text('Inbox Manager'));
    await tester.pump();
    final archive = find.byTooltip('Archive Inbox Manager — its conversations stay');
    await tester.ensureVisible(archive);
    await tester.pump();
    await tester.tap(archive);
    await tester.pump();
    expect(find.text('Archive Inbox Manager?'), findsOneWidget);
    expect(find.textContaining('Nothing is thrown away'), findsOneWidget);

    await tester.tap(find.text('Keep it on the team'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(core.edits, isEmpty);
    expect(find.text('Inbox Manager'), findsWidgets);

    await tester.tap(archive);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(core.edits.single.$1, 'binbox');
    expect(core.edits.single.$2['archived'], isTrue);
  });

  testWidgets('a wide window keeps the directory beside the teammate and its conversations', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    // Ana is on show; her own conversations are the pane under her card.
    expect(find.text('Compare two laptops'), findsOneWidget);
    expect(find.text('Triage last week’s mail'), findsNothing);

    await tester.tap(find.text('Inbox Manager'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Triage last week’s mail'), findsOneWidget);
    expect(find.text('Compare two laptops'), findsNothing);
    expect(find.textContaining('Open Inbox Manager’s lane'), findsOneWidget);
  });

  testWidgets('a wide window holds all three panes at double type', (tester) async {
    final core = _Recorded();
    await _show(tester, core, scale: 2);
    expect(tester.takeException(), isNull, reason: 'no pane may overflow at 2.0 text');
    expect(find.text('TEAMMATES'), findsOneWidget);
    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.textContaining('Compare two laptops'), findsOneWidget);
  });

  testWidgets('every directory row is a keyboard-reachable choice', (tester) async {
    final core = _Recorded();
    await _show(tester, core);
    // The directory is a list of real choices, not pointer-only cards: each row is one tab
    // stop, activated by Enter or Space, and only the teammate on show is marked selected.
    final rows = [for (final k in tester.widgetList<Keyable>(find.byType(Keyable))) if (k.selected != null) k];
    expect(rows.map((k) => k.label),
        containsAll(['Ana, Research', 'Inbox Manager, Triage mail', 'Night Auditor, Reconciles the till']));
    expect(rows.where((k) => k.selected == true).length, 1, reason: 'the teammate on show, and no other');
  });

  testWidgets('a narrow window stacks the directory into cards', (tester) async {
    final core = _Recorded();
    await _show(tester, core, size: const Size(700, 1400));
    expect(tester.takeException(), isNull, reason: 'narrow team page');
    expect(find.text('Inbox Manager'), findsOneWidget);
    expect(find.text('Night Auditor'), findsOneWidget);
    expect(find.text('CONVERSATIONS'), findsNothing, reason: 'no third pane where there is no room for one');
  });
}
