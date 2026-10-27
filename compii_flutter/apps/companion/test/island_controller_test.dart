import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/island/island_actions.dart';
import 'package:compii/src/island/island_controller.dart';
import 'package:compii/src/island/island_geometry.dart';
import 'package:compii/src/island/island_platform.dart';
import 'package:compii/src/island/island_prefs.dart';
import 'package:compii/src/ui/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Core that never touches the network: the island only reads its state.
class _Core extends CoreClient {
  _Core() {
    bots = [
      BotView(id: 'bcompii', name: 'Compii', primary: true, trust: 'full'),
      BotView(id: 'bana', name: 'Ana', job: 'Research'),
    ];
    status = CoreStatus.online;
  }

  int starts = 0;

  @override
  void start() {
    starts++;
    status = CoreStatus.online;
    notifyListeners();
  }

  void ping() => notifyListeners();

  void put(TaskView task) {
    tasks[task.id] = task;
    notifyListeners();
  }

  void remove(String id) {
    tasks.remove(id);
    notifyListeners();
  }
}

class _Platform implements IslandPlatform {
  String title = 'Visual Studio Code';
  int handle = 42;
  bool found = true;
  bool fullscreen = false;
  bool lastThrough = false;
  int throughCalls = 0;
  int focuses = 0;
  final restores = <int>[];
  final toasts = <(String, String)>[];
  int reveals = 0;

  @override
  Future<bool> claim() async => true;

  @override
  Future<Rect?> windowBounds() async => const Rect.fromLTWH(0, 0, 720, 860);

  @override
  Future<void> moveTo(Offset physicalTopLeft) async {}

  @override
  Future<List<IslandDisplay>> displays() async => const <IslandDisplay>[];

  @override
  Future<Offset?> cursor() async => const Offset(10, 10);

  @override
  Future<void> clickThrough(bool through) async {
    lastThrough = through;
    throughCalls++;
  }

  @override
  Future<void> focus() async => focuses++;

  @override
  Future<void> hide() async {}

  @override
  Future<ForegroundWindow> foreground() async => found
      ? ForegroundWindow(handle: handle, title: title, fullscreen: fullscreen)
      : ForegroundWindow.none;

  @override
  Future<bool> restore(int handle) async {
    restores.add(handle);
    return true;
  }

  @override
  Future<bool> revealMain() async {
    reveals++;
    return true;
  }

  @override
  Future<void> toast(String title, String body) async => toasts.add((title, body));
}

class _Actions implements IslandActions {
  final starts = <({String text, String? botId, List<String> files})>[];
  final followOns = <bool>[];
  final replies = <({String id, String text, List<String> files})>[];
  final stops = <String>[];
  final retries = <String>[];
  final opened = <String>[];
  final decided = <({String id, bool approved})>[];
  final answered = <({String id, String text})>[];
  final takeovers = <({String id, String outcome})>[];

  Object? failStart;
  Object? failReply;
  bool screenFails = false;
  int screenShots = 0;
  final picked = <Map<String, dynamic>>[];

  @override
  Future<String> start(String text, {String? botId, List<String> attachments = const [], bool followOn = false}) async {
    final failure = failStart;
    if (failure != null) throw failure;
    starts.add((text: text, botId: botId, files: List.of(attachments)));
    followOns.add(followOn);
    return 't1';
  }

  @override
  Future<void> reply(String taskId, String text, {List<String> attachments = const []}) async {
    final failure = failReply;
    if (failure != null) throw failure;
    replies.add((id: taskId, text: text, files: List.of(attachments)));
  }

  @override
  Future<void> stop(String taskId) async => stops.add(taskId);

  @override
  Future<void> decide(String approvalId, {required bool approved}) async =>
      decided.add((id: approvalId, approved: approved));

  @override
  Future<void> answerQuestion(String questionId, String text) async =>
      answered.add((id: questionId, text: text));

  @override
  Future<void> finishTakeover(String takeoverId, {String outcome = 'done'}) async =>
      takeovers.add((id: takeoverId, outcome: outcome));

  @override
  Future<void> retry(String taskId) async => retries.add(taskId);

  @override
  Future<void> openInMain(String taskId) async => opened.add(taskId);

  int inboxOpens = 0;

  @override
  Future<void> openInbox() async => inboxOpens++;

  @override
  Future<Map<String, dynamic>?> attachScreen() async {
    screenShots++;
    if (screenFails) throw CoreError('Compii couldn’t take a picture of the screen.');
    return {'path': 'C:/Compii/uploads/screen.png', 'name': 'Screen right now', 'screen': true};
  }

  @override
  Future<List<Map<String, dynamic>>> pickFiles() async => [
        for (final f in picked) Map<String, dynamic>.from(f),
      ];
}

class _Voice extends VoiceController {
  _Voice(super.core);

  final calls = <String>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<void> start() async {
    calls.add('start');
    error = null;
    listening = true;
    partial = '';
    notifyListeners();
  }

  @override
  Future<void> finish() async {
    calls.add('finish');
    busy = true;
    listening = false;
    notifyListeners();
    busy = false;
    notifyListeners();
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    listening = false;
    partial = '';
    notifyListeners();
  }

  @override
  Future<void> quiet() async => calls.add('quiet');

  void ping() => notifyListeners();
}

TaskView _task({
  String id = 't1',
  String status = 'running',
  String? botId = 'bcompii',
  String request = 'Sort the receipts',
  List<Map<String, dynamic>> events = const [],
}) =>
    TaskView(id: id, request: request, status: status, botId: botId)..events.addAll(events);

Map<String, dynamic> _approval({String id = 'ap1'}) => {
      'type': 'approval_needed',
      'approval_id': id,
      'kind': 'send',
      'label': 'Email Sam the sorted list',
      'input': {'to': 'sam@example.com'},
    };

Map<String, dynamic> _question({String id = 'q1'}) => {
      'type': 'question',
      'question_id': id,
      'text': 'Which folder should I use?',
      'choices': ['Work', 'Home'],
    };

Map<String, dynamic> _takeover({String id = 'tk1'}) => {
      'type': 'takeover',
      'takeover_id': id,
      'reason': 'Two-factor code',
    };

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

  group('opening and closing', () {
    test('a cold capsule opens a fast ask, lets clicks in, and gives focus back on close', () async {
      expect(c.stage, IslandStage.compact);
      await c.rememberForeground();
      expect(c.foregroundTitle, 'Visual Studio Code');

      await c.openAsk();
      expect(c.isOpen, isTrue);
      expect(c.stage, IslandStage.ask);
      expect(platform.lastThrough, isFalse);
      expect(platform.focuses, 1);

      await c.collapse();
      expect(c.isOpen, isFalse);
      expect(platform.lastThrough, isTrue);
      expect(platform.restores, [42]);
    });

    test('the draft survives collapsing and reopening', () async {
      await c.openAsk();
      c.draft.text = 'half a thought';
      await c.collapse();
      await c.openAsk();
      expect(c.draft.text, 'half a thought');
    });

    test('the capsule resumes the thread it was last showing', () async {
      core.put(_task(status: 'done', events: [
        {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.'},
      ]));
      await c.openTask('t1');
      await c.collapse();
      await c.tapCapsule();
      expect(c.taskId, 't1');
      expect(c.stage, IslandStage.completed);
    });

    test('with nothing attached, the capsule opens ask', () async {
      await c.tapCapsule();
      expect(c.stage, IslandStage.ask);
    });

    test('a conversation deleted elsewhere is never shown', () async {
      core.put(_task(events: [
        {'type': 'task_started'},
      ]));
      await c.openTask('t1');
      expect(c.isOpen, isTrue);
      core.remove('t1');
      expect(c.taskId, isNull);
      expect(c.isOpen, isFalse);
    });

    test('dismissing a finished conversation clears it but history stays in Core', () async {
      core.put(_task(status: 'done', events: [
        {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.'},
      ]));
      await c.openTask('t1');
      await c.dismissFinished();
      expect(c.isOpen, isFalse);
      expect(c.taskId, isNull);
      expect(core.tasks.containsKey('t1'), isTrue);
    });
  });

  group('what needs you', () {
    test('an approval is named exactly and opens straight to it', () async {
      core.put(_task(events: [_approval()]));
      expect(c.needsYou, isTrue);
      expect(c.capsuleLabel, 'Needs your okay');
      await c.tapCapsule();
      expect(c.taskId, 't1');
      expect(c.stage, IslandStage.approval);
    });

    test('a question and a takeover are named as themselves, not as generic work', () async {
      core.put(_task(events: [_question()]));
      expect(c.capsuleLabel, 'Has a question');
      await c.openTask('t1');
      expect(c.stage, IslandStage.conversation);

      core.tasks['t1']!.events
        ..clear()
        ..add(_takeover());
      core.ping();
      expect(c.capsuleLabel, 'Your turn');
    });

    test('a finished thread that needs nothing is not attention', () async {
      core.put(_task(status: 'done', events: [
        {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.'},
      ]));
      await c.openTask('t1');
      await c.collapse();
      expect(c.needsYou, isFalse);
      expect(c.capsuleLabel, 'Done');
    });

    test('two running threads are counted, not invented', () async {
      core.put(_task(id: 't1', events: [
        {'type': 'task_started'},
      ]));
      core.put(_task(id: 't2', request: 'Plan the trip', events: [
        {'type': 'task_started'},
      ]));
      expect(c.workingCount, 2);
      expect(c.capsuleLabel, 'Working · 2');
    });

    test('an unreachable Core says so instead of pretending to work', () async {
      core.status = CoreStatus.offline;
      core.ping();
      expect(c.offline, isTrue);
      expect(c.signal, IslandSignal.offline);
      expect(c.capsuleLabel, 'Offline');
    });
  });

  group('what the capsule says it is doing', () {
    String phase(String type, [Map<String, dynamic> extra = const {}]) =>
        islandPhase(_task(events: [
          {'type': type, ...extra},
        ]));

    test('a context step is named for what is actually being read', () {
      expect(phase('context'), 'Reading what it knows');
      expect(phase('context', {
        'items': [
          {'source': 'remembered', 'kind': 'memory'},
          {'source': 'skills', 'kind': 'instruction'},
        ],
      }), 'Reading what it knows');
      expect(phase('context', {
        'items': [
          {'source': 'remembered', 'kind': 'memory'},
          {'source': 'desktop', 'kind': 'observation', 'label': 'Code — repo.py'},
        ],
      }), 'Reading what you have open');
    });

    test('every step keeps its own name instead of blurring into working', () {
      expect(phase('task_started'), 'Thinking');
      expect(phase('plan'), 'Planning');
      expect(phase('answer_delta'), 'Writing');
      expect(phase('screen_seen'), 'Looking at your screen');
      expect(phase('action_done'), 'Checking the result');
      expect(phase('delegation_done'), 'Reviewing the teammate’s work');
      expect(phase('action_started', {'tool': 'read_file'}), 'Using Read file');
      expect(phase('something_core_has_not_learned_yet'), 'Working');
    });
  });

  group('one state at a time', () {
    test('the phase is the thread, not a guess about it', () async {
      expect(c.phase, IslandPhase.idle);

      await c.openAsk();
      expect(c.phase, IslandPhase.ask);
      expect(c.isOpen, isTrue);

      core.put(_task(events: [
        {'type': 'task_started'},
      ]));
      await c.openTask('t1');
      expect(c.phase, IslandPhase.working);

      core.put(_task(events: [
        {'type': 'task_started'},
        _approval(),
      ]));
      core.ping();
      expect(c.phase, IslandPhase.approval);
      expect(c.stage, IslandStage.approval);
      expect(c.asking, isFalse, reason: 'no composer can sit over the step it hides');

      core.put(_task(status: 'done', events: [
        {'type': 'task_started'},
        {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.'},
      ]));
      core.ping();
      expect(c.phase, IslandPhase.result);
      expect(c.stage, IslandStage.completed);
    });

    test('a collapsed island keeps its phase on the mark, never on a card', () async {
      core.put(_task(events: [
        {'type': 'task_started'},
      ]));
      await c.openTask('t1');
      await c.collapse();
      expect(c.phase, IslandPhase.working);
      expect(c.isOpen, isFalse);
      expect(c.stage, IslandStage.compact);
      expect(c.capsuleLabel, 'Working');
    });

    test('offline is only the state when there is nothing of ours to show', () async {
      core.status = CoreStatus.offline;
      core.ping();
      expect(c.phase, IslandPhase.offline);
      await c.openAsk();
      expect(c.phase, IslandPhase.ask, reason: 'typing into a dead Core is still typing');
    });

    test('the composer never hides a thread that is waiting on you', () async {
      await c.openAsk();
      c.draft.text = 'Email Sam about';
      core.put(_task(id: 't9', request: 'Sort the receipts', events: [
        {'type': 'task_started'},
        _approval(),
      ]));
      core.ping();
      expect(c.asking, isTrue, reason: 'their words are the state they chose');
      expect(c.backgroundAttention?.id, 't9');
      expect(c.capsuleLabel, 'Needs your okay');

      await c.openTask('t9');
      expect(c.phase, IslandPhase.approval);
      expect(c.draft.text, 'Email Sam about', reason: 'opening the approval costs nothing');
    });
  });

  group('how loudly it tells you', () {
    void backgroundAsk() {
      core.put(_task(id: 't9', request: 'Sort the receipts', events: [
        {'type': 'task_started'},
        _approval(),
      ]));
      core.ping();
    }

    test('expanded opens that card, but never takes the keyboard', () async {
      c.setAttention(IslandAttention.expanded);
      final focuses = platform.focuses;
      backgroundAsk();
      await pumpEventQueue();
      expect(c.isOpen, isTrue);
      expect(c.taskId, 't9');
      expect(c.phase, IslandPhase.approval);
      expect(
        platform.focuses,
        focuses,
        reason: 'a card you did not ask for must not steal another app’s typing',
      );
    });

    test('nothing opens over a full-screen app', () async {
      c.setAttention(IslandAttention.expanded);
      platform.fullscreen = true;
      await c.rememberForeground();
      expect(c.presenting, isTrue);
      backgroundAsk();
      await pumpEventQueue();
      expect(c.isOpen, isFalse);
      expect(platform.toasts, isEmpty);
      expect(c.needsYou, isTrue, reason: 'the mark still says it when you look');
    });

    test('expanded keeps the composer when you are mid-sentence, and says so instead', () async {
      c.setAttention(IslandAttention.expanded);
      await c.openAsk();
      c.draft.text = 'Email Sam about';
      backgroundAsk();
      await pumpEventQueue();
      expect(c.asking, isTrue);
      expect(c.draft.text, 'Email Sam about');
      expect(platform.toasts, [('Compii needs your OK', 'Email Sam the sorted list')]);
    });

    test('a notification is one toast, once, and nothing on screen', () async {
      c.setAttention(IslandAttention.toast);
      backgroundAsk();
      await pumpEventQueue();
      expect(c.isOpen, isFalse);
      expect(platform.toasts, [('Compii needs your OK', 'Email Sam the sorted list')]);

      core.ping();
      await pumpEventQueue();
      expect(platform.toasts, hasLength(1), reason: 'the same ask is not twice the news');

      // Answered, then asked again: a second ask is a second piece of news.
      core.put(_task(id: 't9', events: [
        {'type': 'task_started'},
        _approval(),
        {'type': 'approval_resolved', 'approval_id': 'ap1', 'approved': true},
        _approval(id: 'ap2'),
      ]));
      core.ping();
      await pumpEventQueue();
      expect(platform.toasts, hasLength(2));
    });

    test('the mark, and silence, both leave the screen alone', () async {
      for (final policy in [IslandAttention.indicator, IslandAttention.silent]) {
        final quiet = _Core();
        final p = _Platform();
        final controller = IslandController(core: quiet, actions: _Actions(), platform: p);
        controller.setAttention(policy);
        quiet.tasks['t9'] = TaskView(id: 't9', request: 'Sort the receipts', status: 'running', botId: 'bcompii')
          ..events.addAll([
            {'type': 'task_started'},
            {'type': 'approval_needed', 'approval_id': 'ap1', 'kind': 'send', 'label': 'Email Sam'},
          ]);
        quiet.ping();
        await pumpEventQueue();
        expect(controller.isOpen, isFalse, reason: '$policy never opens a card');
        expect(p.toasts, isEmpty, reason: '$policy sends no notification');
        expect(controller.needsYou, isTrue);
        expect(controller.stage, IslandStage.compact);
        controller.dispose();
        quiet.dispose();
      }
    });

    test('finishing is news, getting on with work is not', () async {
      c.setAttention(IslandAttention.toast);
      core.put(_task(id: 't9', events: [
        {'type': 'task_started'},
      ]));
      core.ping();
      await pumpEventQueue();
      expect(platform.toasts, isEmpty, reason: 'history you connect to is not news');

      core.put(_task(id: 't9', events: [
        {'type': 'task_started'},
        {'type': 'action_started', 'tool': 'read_file'},
      ]));
      core.ping();
      await pumpEventQueue();
      expect(platform.toasts, isEmpty, reason: 'Compii working is not a reason to interrupt');

      core.put(_task(id: 't9', status: 'done', events: [
        {'type': 'task_started'},
        {'type': 'action_started', 'tool': 'read_file'},
        {'type': 'task_finished', 'status': 'done', 'text': 'Done: 12 receipts.'},
      ]));
      core.ping();
      await pumpEventQueue();
      expect(platform.toasts, [('Compii finished', 'Done: 12 receipts.')]);
    });

    test('a failed send keeps your words, and only opens the card if you asked for that', () async {
      c.setAttention(IslandAttention.indicator);
      await c.openAsk();
      c.draft.text = 'Email Sam';
      await c.collapse();
      actions.failStart = CoreError('Core went away');

      await c.send();
      expect(c.isOpen, isFalse);
      expect(c.draft.text, 'Email Sam');
      expect(c.error, 'Core went away');
      expect(c.capsuleLabel, 'Didn’t finish');

      c.setAttention(IslandAttention.expanded);
      c.retry();
      await pumpEventQueue();
      expect(c.isOpen, isTrue);
      expect(c.asking, isTrue);
      expect(c.draft.text, 'Email Sam');
    });
  });

  group('sending', () {
    test('an ask reaches Core with the chosen teammate, then waits honestly for the thread', () async {
      await c.openAsk();
      c.setBot('bana');
      c.draft.text = 'Find me a scholarship';
      await c.send();

      expect(actions.starts.single.text, 'Find me a scholarship');
      expect(actions.starts.single.botId, 'bana');
      expect(c.sending, isFalse);
      expect(c.draft.text, isEmpty);
      expect(c.starting, isTrue);
      expect(c.stage, IslandStage.working);
      expect(c.speaker?.name, 'Ana', reason: 'the next ask is going to Ana, and no thread exists to say otherwise');

      core.put(_task(id: 't1', request: 'Find me a scholarship', botId: 'bana', events: [
        {'type': 'task_started', 'bot_id': 'bana'},
      ]));
      expect(c.starting, isFalse);
      expect(c.stage, IslandStage.working);
      expect(c.speaker?.name, 'Ana');
    });

    test('the hotkey ask carries on what was just said; New ask and New topic start afresh', () async {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      core.put(_task(id: 't0', status: 'done', request: 'Weather in Accra?', events: [
        {'type': 'task_finished', 'status': 'done', 'text': 'Sunny.', 'at': now - 30},
      ]));
      await c.openAsk();
      expect(c.continuing?.id, 't0');
      c.draft.text = 'and tomorrow?';
      await c.send();
      expect(actions.followOns.last, isTrue);

      await c.openAsk(fresh: true);
      expect(c.continuing, isNull);
      c.draft.text = 'Plan my week';
      await c.send();
      expect(actions.followOns.last, isFalse);

      await c.openAsk();
      c.newTopic();
      expect(c.continuing, isNull);
      c.draft.text = 'Something else';
      await c.send();
      expect(actions.followOns.last, isFalse);
    });

    test('a conversation from an hour ago is not carried on', () async {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      core.put(_task(id: 't0', status: 'done', events: [
        {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.', 'at': now - 3600},
      ]));
      await c.openAsk();
      expect(c.continuing, isNull);
    });

    test('a done turn becomes a restrained finished card, a failed one stays failed', () async {
      core.put(_task(events: [
        {'type': 'task_started'},
      ]));
      await c.openTask('t1');

      core.tasks['t1']!.status = 'done';
      core.tasks['t1']!.events.add({'type': 'task_finished', 'status': 'done', 'text': 'Eleven receipts.'});
      core.ping();
      expect(c.stage, IslandStage.completed);

      core.tasks['t1']!.status = 'failed';
      core.tasks['t1']!.events.add({'type': 'task_finished', 'status': 'failed', 'text': 'Core stopped.'});
      core.ping();
      expect(c.stage, IslandStage.failed);
    });

    test('screen context is attached as a real upload and then cleared', () async {
      await c.openAsk();
      c.toggleScreenContext();
      expect(c.attachmentCount, 1);
      c.draft.text = 'What is this?';
      await c.send();

      expect(actions.screenShots, 1);
      expect(actions.starts.single.files, ['C:/Compii/uploads/screen.png']);
      expect(c.screenContext, isFalse);
    });

    test('a screen picture that cannot be taken sends nothing', () async {
      actions.screenFails = true;
      await c.openAsk();
      c.toggleScreenContext();
      c.draft.text = 'What is this?';
      await c.send();

      expect(actions.starts, isEmpty);
      expect(c.error, contains('couldn’t take a picture'));
      expect(c.draft.text, 'What is this?', reason: 'their words are never thrown away');
    });

    test('offline sends keep the words and say Core will come back', () async {
      await c.openAsk();
      core.status = CoreStatus.offline;
      core.ping();
      c.draft.text = 'Still there?';
      await c.send();

      expect(actions.starts, isEmpty);
      expect(c.draft.text, 'Still there?');
      expect(c.error, contains('isn’t reachable'));
      expect(c.canRetry, isTrue);
    });

    test('a failed send can be retried without retyping', () async {
      actions.failStart = CoreError('No AI is connected yet.');
      await c.openAsk();
      c.draft.text = 'Summarize the page';
      await c.send();
      expect(c.error, 'No AI is connected yet.');
      expect(c.draft.text, 'Summarize the page');
      expect(c.stage, IslandStage.ask);

      actions.failStart = null;
      c.retry();
      await pumpEventQueue();
      expect(actions.starts.single.text, 'Summarize the page');
      expect(c.error, isNull);
      expect(c.taskId, 't1');
    });

    test('a reply goes to the open thread and keeps the draft on failure', () async {
      core.put(_task(events: [
        {'type': 'task_started'},
        {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.'},
      ]));
      core.tasks['t1']!.status = 'done';
      await c.openTask('t1');

      actions.failReply = CoreError('That conversation isn’t here any more.');
      c.draft.text = 'Now the travel ones';
      await c.reply();
      expect(actions.replies, isEmpty);
      expect(c.draft.text, 'Now the travel ones');
      expect(c.error, 'That conversation isn’t here any more.');

      actions.failReply = null;
      await c.reply();
      expect(actions.replies.single.id, 't1');
      expect(actions.replies.single.text, 'Now the travel ones');
      expect(c.draft.text, isEmpty);
    });

    test('empty sends do nothing at all', () async {
      await c.openAsk();
      await c.send();
      expect(actions.starts, isEmpty);
      expect(c.sending, isFalse);
    });
  });

  group('working and recovery', () {
    test('stop reaches Core once and never double-fires', () async {
      core.put(_task(events: [
        {'type': 'task_started'},
      ]));
      await c.openTask('t1');
      await c.stop();
      expect(actions.stops, ['t1']);
      expect(c.stopping, isFalse);
    });

    test('try again asks Core to run the thread again and shows work meanwhile', () async {
      core.put(_task(status: 'failed', events: [
        {'type': 'task_finished', 'status': 'failed', 'text': 'Core stopped.'},
      ]));
      await c.openTask('t1');
      await c.retryTask();
      expect(actions.retries, ['t1']);
      expect(c.stage, IslandStage.working);
      expect(c.canRetry, isFalse);
    });

    test('open in Compii hands the thread over and gets out of the way', () async {
      core.put(_task(events: [
        {'type': 'task_started'},
      ]));
      await c.openTask('t1');
      await c.rememberForeground();
      await c.openInMain();
      expect(actions.opened, ['t1']);
      expect(c.isOpen, isFalse);
      expect(platform.restores, isEmpty, reason: 'the workspace is taking over focus');
    });

    test('dismissing an error clears its retry with it', () async {
      actions.failStart = CoreError('No AI is connected yet.');
      await c.openAsk();
      c.draft.text = 'Try something';
      await c.send();
      expect(c.error, isNotNull);
      c.dismissError();
      expect(c.error, isNull);
      expect(c.canRetry, isFalse);
    });

    test('reconnect asks the client to start again', () async {
      core.status = CoreStatus.offline;
      core.ping();
      c.reconnect();
      expect(core.starts, 1);
    });

    test('a shared widget failure stays on the card', () async {
      await c.run(() async => throw CoreError('That did not work.'));
      expect(c.error, 'That did not work.');
      await c.run(() async {});
      expect(c.error, isNull);
    });
  });

  group('context suggestions', () {
    test('the app in front decides which suggestions are offered, and screen ones turn sight on', () async {
      await c.rememberForeground();
      expect(c.foregroundTitle, 'Visual Studio Code');
      expect(c.suggestions.first.label, 'Explain this code');

      c.chooseSuggestion(c.suggestions.first);
      expect(c.draft.text, 'Look at the code on my screen and explain what it does.');
      expect(c.screenContext, isTrue);

      platform.title = 'Notepad';
      await c.rememberForeground();
      expect(c.suggestions.first.label, 'Catch me up');
      expect(c.suggestions.any((s) => s.label == 'Summarize my screen'), isTrue);
    });

    test('picked attachments are listed with their real size and can be removed', () async {
      actions.picked.add({'path': 'C:/Compii/uploads/a.pdf', 'name': 'a.pdf', 'size': 2048});
      await c.addFiles();
      expect(c.attachmentCount, 1);
      expect(c.attachments.single['name'], 'a.pdf');

      c.removeAttachment(0);
      expect(c.attachmentCount, 0);
      c.removeAttachment(4);
      expect(c.attachmentCount, 0);
    });
  });

  group('saying more while Compii works', () {
    void working() => core.put(_task(id: 't9', events: [
      {'type': 'task_started'},
      {'type': 'action_started', 'tool': 'read_file'},
    ]));

    void ended() => core.put(_task(id: 't9', status: 'done', events: [
      {'type': 'task_started'},
      {'type': 'task_finished', 'status': 'done', 'text': 'Sorted.'},
    ]));

    test('a follow-up waits its turn instead of being refused', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      expect(actions.replies, isEmpty, reason: 'nothing is sent into a running step');
      expect(c.queuedText, 'It is the March one');
      expect(c.draft.text, isEmpty, reason: 'the composer is free for the next thought');
    });

    test('it goes out on its own the moment the turn ends', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      ended();
      core.ping();
      await pumpEventQueue();
      expect(actions.replies.single.id, 't9');
      expect(actions.replies.single.text, 'It is the March one');
      expect(c.queuedText, isNull);
    });

    test('taking it back puts the words where they can be edited', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      c.cancelQueued();
      expect(c.queuedText, isNull);
      expect(c.draft.text, 'It is the March one');
      expect(actions.replies, isEmpty);
    });

    test('one message waits at a time, and the second says so', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      c.draft.text = 'And the receipts too';
      await c.reply();
      expect(c.queuedText, 'It is the March one');
      expect(c.draft.text, 'And the receipts too', reason: 'the refused words are not thrown away');
      expect(c.error, contains('already waiting'));
    });

    test('a queue waits for Core to come back rather than failing', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      core.status = CoreStatus.offline;
      ended();
      core.ping();
      await pumpEventQueue();
      expect(actions.replies, isEmpty);
      expect(c.queuedText, 'It is the March one');

      core.status = CoreStatus.online;
      core.ping();
      await pumpEventQueue();
      expect(actions.replies, hasLength(1));
      expect(c.queuedText, isNull);
    });

    test('a thread deleted elsewhere hands the waiting words back', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      core.remove('t9');
      expect(c.queuedText, isNull);
      expect(c.draft.text, 'It is the March one');
    });

    test('a waiting message never overwrites words being typed', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      c.draft.text = 'And the travel ones';
      ended();
      core.ping();
      await pumpEventQueue();
      expect(actions.replies, isEmpty, reason: 'the thread is free, the field is not');
      expect(c.queuedText, 'It is the March one');

      c.draft.clear();
      await pumpEventQueue();
      expect(actions.replies.single.text, 'It is the March one');
      expect(c.queuedText, isNull);
    });

    test('a waiting message that fails to send returns to the composer', () async {
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      actions.failReply = CoreError('Core refused it');
      ended();
      core.ping();
      await pumpEventQueue();
      expect(c.queuedText, isNull, reason: 'it is not kept in two places at once');
      expect(c.draft.text, 'It is the March one');
      expect(c.error, contains('Core refused it'));
    });

    test('the pill restarting keeps the waiting message and sends nothing itself', () async {
      final prefs = MemoryIslandPrefs();
      c.dispose();
      c = IslandController(core: core, actions: actions, platform: platform, prefs: prefs);
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      expect(prefs.heldReply?.text, 'It is the March one');

      final reopened = IslandController(core: core, actions: _Actions(), platform: _Platform(), prefs: prefs);
      addTearDown(reopened.dispose);
      await reopened.restoreHeld();
      expect(reopened.draft.text, 'It is the March one');
      expect(reopened.queuedText, isNull, reason: 'a restart never presses send for you');
      expect(prefs.heldReply, isNull, reason: 'one copy, and it is the one you can see');
    });

    test('what the pill no longer holds is not left saved', () async {
      final prefs = MemoryIslandPrefs();
      c.dispose();
      c = IslandController(core: core, actions: actions, platform: platform, prefs: prefs);
      working();
      await c.openTask('t9');
      c.draft.text = 'It is the March one';
      await c.reply();
      ended();
      core.ping();
      await pumpEventQueue();
      expect(prefs.heldReply, isNull, reason: 'it went out; the saved copy must not come back');

      c.draft.text = 'And the receipts too';
      await c.reply();
      c.cancelQueued();
      expect(prefs.heldReply, isNull, reason: 'you took it back; nothing is waiting');
    });

    test('a restored message does not talk over words you are typing now', () async {
      final prefs = MemoryIslandPrefs(heldReply: HeldReply(text: 'It is the March one'));
      final reopened = IslandController(core: core, actions: _Actions(), platform: _Platform(), prefs: prefs);
      addTearDown(reopened.dispose);
      reopened.draft.text = 'Never mind, forget it';
      await reopened.restoreHeld();
      expect(reopened.draft.text, 'Never mind, forget it');
      expect(prefs.heldReply?.text, 'It is the March one', reason: 'kept, not quietly dropped');
    });
  });

  group('voice', () {
    late _Voice voice;
    setUp(() {
      voice = _Voice(core);
      c.dispose();
      c = IslandController(core: core, actions: actions, platform: platform, voice: voice);
      addTearDown(voice.dispose);
    });

    test('starting to talk opens the ask card and shows the mic is really on', () async {
      await c.startListening();
      expect(voice.calls, ['start']);
      expect(c.stage, IslandStage.ask);
      expect(c.listeningHere, isTrue);
    });

    test('heard words are inserted at the caret, with a space where one is needed', () async {
      c.draft.value = const TextEditingValue(text: 'Email Sam', selection: TextSelection.collapsed(offset: 9));
      voice.onHeard?.call('about the invoice');
      expect(c.draft.text, 'Email Sam about the invoice');

      c.draft.value = const TextEditingValue(text: 'Email Sam ', selection: TextSelection.collapsed(offset: 10));
      voice.onHeard?.call('today');
      expect(c.draft.text, 'Email Sam today');

      c.draft.value = const TextEditingValue(text: 'Send  now', selection: TextSelection.collapsed(offset: 5));
      voice.onHeard?.call('it');
      expect(c.draft.text, 'Send it now');
    });

    test('closing while listening cancels the mic instead of leaving it recording', () async {
      await c.startListening();
      await c.collapse();
      await pumpEventQueue();
      expect(voice.calls, ['start', 'cancel']);
      expect(voice.listening, isFalse);
    });

    test('cancelling listening on its own also stops owning the mic', () async {
      await c.startListening();
      await c.cancelListening();
      expect(voice.calls, ['start', 'cancel']);
      expect(c.listeningHere, isFalse);
    });

    test('a mic started by the buddy is the capsule, never a card over someone talking', () {
      voice.listening = true;
      voice.ping();
      expect(c.phase, IslandPhase.listening);
      expect(c.stage, IslandStage.listening);
      expect(c.isOpen, isFalse);

      voice.listening = false;
      voice.ping();
      expect(c.phase, IslandPhase.idle);
      expect(c.isOpen, isFalse);
    });

    test('a thread waiting on the user outranks the mic', () async {
      core.put(_task(events: [_approval()]));
      await c.openTask('t1');
      voice.listening = true;
      voice.ping();
      expect(c.phase, IslandPhase.approval);
      expect(c.isOpen, isTrue);
    });
  });

  group('what Compii left in the inbox', () {
    Map<String, dynamic> brief({String id = 'u1', String task = ''}) => {
      'type': 'update',
      'id': id,
      'kind': 'brief',
      'title': 'Your brief for Friday',
      'body': 'Three things worth reading.\nNone of them urgent.',
      'task_id': task,
    };

    test('a brief with no conversation of its own marks the pill and is said once', () async {
      c.setAttention(IslandAttention.toast);
      core.updates.add(brief());
      await pumpEventQueue();

      expect(c.newsCount, 1);
      expect(c.signal, IslandSignal.news);
      expect(c.capsuleLabel, 'New from Compii');
      expect(c.isOpen, isFalse, reason: 'a notification does not take over the screen');
      expect(platform.toasts, [('Your brief for Friday', 'Three things worth reading. None of them urgent.')]);

      core.updates.add(brief());
      await pumpEventQueue();
      expect(platform.toasts, hasLength(1), reason: 'the same brief is not twice the news');
      expect(c.newsCount, 1);
    });

    test('a routine that ran as a thread is not told to you twice', () async {
      c.setAttention(IslandAttention.toast);
      core.put(_task(id: 't9', status: 'running', events: [
        {'type': 'task_started'},
      ]));
      await pumpEventQueue();
      core.updates.add(brief(task: 't9'));
      await pumpEventQueue();

      expect(c.newsCount, 0, reason: 'the thread itself is the news, and the pill already has it');
      expect(platform.toasts, isEmpty);
    });

    test('quiet and mark-only both leave the screen alone, and say nothing', () async {
      for (final policy in [IslandAttention.silent, IslandAttention.indicator]) {
        final quiet = _Core();
        final p = _Platform();
        final controller = IslandController(core: quiet, actions: _Actions(), platform: p);
        controller.setAttention(policy);
        quiet.updates.add(brief());
        await pumpEventQueue();

        expect(controller.newsCount, 1, reason: '$policy still keeps the mark');
        expect(controller.signal, IslandSignal.news);
        expect(p.toasts, isEmpty, reason: '$policy sends no notification');
        expect(controller.isOpen, isFalse);
        controller.dispose();
        quiet.dispose();
      }
    });

    test('even "show me" does not open a card for news that has no card', () async {
      c.setAttention(IslandAttention.expanded);
      core.updates.add(brief());
      await pumpEventQueue();

      expect(c.isOpen, isFalse, reason: 'there is no conversation to expand');
      expect(platform.toasts, hasLength(1));
      expect(platform.reveals, 0, reason: 'news never pushes another app’s window over yours');
    });

    test('a full-screen app gets the mark, not the noise', () async {
      c.setAttention(IslandAttention.toast);
      platform.fullscreen = true;
      await c.rememberForeground();
      core.updates.add(brief());
      await pumpEventQueue();

      expect(c.newsCount, 1);
      expect(platform.toasts, isEmpty);
    });

    test('a tap on the mark goes to the news, and the mark comes off', () async {
      c.setAttention(IslandAttention.silent);
      core.updates.add(brief());
      await pumpEventQueue();
      expect(c.newsCount, 1, reason: 'the brief is marked before the tap');

      await c.tapCapsule();
      expect(actions.inboxOpens, 1);
      expect(c.newsCount, 0);
      expect(c.signal, IslandSignal.none);
      expect(c.asking, isFalse, reason: 'the news is what you were asked to look at');
    });

    test('news that turned into a thread opens that thread instead', () async {
      c.setAttention(IslandAttention.silent);
      core.updates.add(brief(task: 't9'));
      await pumpEventQueue();
      core.put(_task(id: 't9', status: 'done', events: [
        {'type': 'task_started'},
        {'type': 'task_finished', 'status': 'done', 'text': 'Your brief is ready.'},
      ]));

      await c.tapCapsule();
      expect(c.taskId, 't9');
      expect(c.stage, IslandStage.completed);
      expect(actions.inboxOpens, 0);
      expect(c.newsCount, 0);
    });

    test('a thread that needs you outranks anything in the inbox', () async {
      c.setAttention(IslandAttention.toast);
      core.put(_task(id: 't9', status: 'running', events: [
        {'type': 'task_started'},
        _approval(id: 'ap1'),
      ]));
      await pumpEventQueue();
      core.updates.add(brief());

      expect(c.signal, IslandSignal.needsYou);
      expect(c.capsuleLabel, 'Needs your okay');
      await c.tapCapsule();
      expect(c.taskId, 't9');
      expect(actions.inboxOpens, 0);
    });

    test('a pile nobody looked at stops counting at twelve', () async {
      c.setAttention(IslandAttention.silent);
      for (var i = 1; i <= 15; i++) {
        core.updates.add(brief(id: 'u$i', task: 't$i'));
      }
      await pumpEventQueue();

      expect(c.newsCount, 12);
      expect(c.capsuleLabel, 'New from Compii · 12');
    });
  });
}
