import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/desktop_toasts.dart';
import 'package:compii/src/island/island_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work that finishes while you are elsewhere becomes a toast — not while you are looking', () async {
    final core = CoreClient();
    var background = true;
    final shown = <(String, String)>[];
    final toasts = DesktopToasts(
      core,
      inBackground: () => background,
      alive: () async => false,
      policy: () async => IslandAttention.toast,
      send: (title, body) async => shown.add((title, body)),
    );
    addTearDown(toasts.dispose);
    addTearDown(core.dispose);

    core.taskEvents.add({'type': 'task_finished', 'task_id': 't1', 'status': 'done', 'text': 'Wrote the deck.'});
    await Future<void>.delayed(Duration.zero);
    expect(shown, [('Compii finished', 'Wrote the deck.')]);

    background = false;
    core.taskEvents.add({'type': 'task_finished', 'task_id': 't1', 'status': 'done', 'text': 'Again.'});
    await Future<void>.delayed(Duration.zero);
    expect(shown, hasLength(1), reason: 'you can see the window; no need for a toast');
  });

  test('a bot that needs you says so by name, and stopped work stays quiet', () async {
    final core = CoreClient();
    final shown = <(String, String)>[];
    final toasts = DesktopToasts(
      core,
      inBackground: () => true,
      alive: () async => false,
      policy: () async => IslandAttention.toast,
      send: (title, body) async => shown.add((title, body)),
    );
    addTearDown(toasts.dispose);
    addTearDown(core.dispose);
    core.bots = [BotView(id: 'b1', name: 'Mira')];
    core.tasks['t1'] = TaskView(id: 't1', request: 'find a scholarship', status: 'waiting', botId: 'b1');

    core.taskEvents.add({'type': 'question', 'task_id': 't1', 'question': 'Which scholarship?'});
    core.taskEvents.add({'type': 'takeover', 'task_id': 't1', 'what': 'Type your password in Edge.'});
    core.taskEvents.add({'type': 'task_finished', 'task_id': 't1', 'status': 'stopped', 'text': 'Stopped.'});
    await Future<void>.delayed(Duration.zero);
    expect(shown, [
      ('Mira has a question', 'Which scholarship?'),
      ('Your turn — Mira', 'Type your password in Edge.'),
    ]);
  });

  test('an island running means the island tells you, in the way you chose', () async {
    final core = CoreClient();
    final shown = <(String, String)>[];
    final toasts = DesktopToasts(
      core,
      inBackground: () => true,
      alive: () async => true,
      policy: () async => IslandAttention.toast,
      send: (title, body) async => shown.add((title, body)),
    );
    addTearDown(toasts.dispose);
    addTearDown(core.dispose);

    core.taskEvents.add({'type': 'approval_needed', 'task_id': 't1', 'label': 'Email Sam'});
    core.taskEvents.add({'type': 'task_finished', 'task_id': 't1', 'status': 'done', 'text': 'Sent.'});
    await Future<void>.delayed(Duration.zero);
    expect(shown, isEmpty, reason: 'two notifications for one event is not a policy');
  });

  test('news with no conversation of its own is told here only when no island runs', () async {
    final core = CoreClient();
    final shown = <(String, String)>[];
    final toasts = DesktopToasts(
      core,
      inBackground: () => true,
      alive: () async => false,
      policy: () async => IslandAttention.toast,
      send: (title, body) async => shown.add((title, body)),
    );
    addTearDown(toasts.dispose);
    addTearDown(core.dispose);

    core.updates.add({
      'type': 'update',
      'id': 'u1',
      'kind': 'brief',
      'title': 'Your brief for Friday',
      'body': 'Three things worth reading.',
      'task_id': '',
    });
    await Future<void>.delayed(Duration.zero);
    expect(shown, [('Your brief for Friday', 'Three things worth reading.')]);

    final quiet = CoreClient();
    final quietShown = <(String, String)>[];
    final withIsland = DesktopToasts(
      quiet,
      inBackground: () => true,
      alive: () async => true,
      policy: () async => IslandAttention.toast,
      send: (title, body) async => quietShown.add((title, body)),
    );
    addTearDown(withIsland.dispose);
    addTearDown(quiet.dispose);
    quiet.updates.add({
      'type': 'update',
      'id': 'u2',
      'kind': 'watch',
      'title': 'Invoices folder',
      'body': 'New: march.pdf',
      'task_id': '',
    });
    await Future<void>.delayed(Duration.zero);
    expect(quietShown, isEmpty, reason: 'the pill marks it; the bell stays out of it');

    // A routine ran as a thread: the task path tells you, so the inbox copy must not.
    core.tasks['t7'] = TaskView(id: 't7', request: 'check the inbox', status: 'done');
    core.updates.add({
      'type': 'update',
      'id': 'u9',
      'kind': 'routine',
      'title': 'Routine: Inbox sweep',
      'body': 'Four new mails.',
      'task_id': 't7',
    });
    await Future<void>.delayed(Duration.zero);
    expect(shown, hasLength(1), reason: 'one routine, one notice');
  });

  test('"stay quiet" means this PC, not just the pill', () async {
    final core = CoreClient();
    final shown = <(String, String)>[];
    final toasts = DesktopToasts(
      core,
      inBackground: () => true,
      alive: () async => false,
      policy: () async => IslandAttention.silent,
      send: (title, body) async => shown.add((title, body)),
    );
    addTearDown(toasts.dispose);
    addTearDown(core.dispose);

    core.taskEvents.add({'type': 'approval_needed', 'task_id': 't1', 'label': 'Email Sam'});
    core.updates.add({'type': 'update', 'id': 'u1', 'kind': 'brief', 'title': 'Your brief', 'body': 'Read this.'});
    await Future<void>.delayed(Duration.zero);
    expect(shown, isEmpty);
  });
}
