import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/desktop_toasts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work that finishes while you are elsewhere becomes a toast — not while you are looking', () async {
    final core = CoreClient();
    var background = true;
    final shown = <(String, String)>[];
    final toasts = DesktopToasts(
      core,
      inBackground: () => background,
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
}
