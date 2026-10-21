import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/thread.dart';
import 'package:flutter_test/flutter_test.dart';

TaskView _task(List<Map<String, dynamic>> events, {String status = 'done'}) =>
    TaskView(id: 't', request: 'first ask', status: status)..events.addAll(events);

void main() {
  test('follow-ups become separate turns with their own steps, files and replies', () {
    final turns = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'plan', 'steps': [{'title': 'A', 'status': 'active'}], 'at': 1},
      {'type': 'action_done', 'tool': 'update_plan', 'label': 'Update plan', 'ok': true, 'at': 1},
      {'type': 'action_started', 'tool': 'write_text_file', 'label': 'Write a', 'at': 2},
      {'type': 'action_done', 'tool': 'write_text_file', 'label': 'Write a', 'ok': true, 'at': 3},
      {'type': 'file', 'path': r'C:\x\a.txt', 'action': 'created', 'at': 3},
      {'type': 'task_finished', 'status': 'done', 'text': 'Wrote a.', 'at': 4},
      {'type': 'user_message', 'text': 'now b', 'at': 10},
      {'type': 'task_finished', 'status': 'done', 'text': 'Done b.', 'at': 12},
    ]));
    expect(turns.map((t) => t.ask), ['first ask', 'now b']);
    expect(turns.first.plan!.single['title'], 'A');
    expect(turns.first.finished.map((s) => s['label']), ['Write a'], reason: 'plan updates are not shown as steps');
    expect(turns.first.files.single['path'], r'C:\x\a.txt');
    expect(turns.first.reply, 'Wrote a.');
    expect(turns.last.reply, 'Done b.');
    expect(turns.last.files, isEmpty);
  });

  test('a pending approval is only offered while the turn is active', () {
    final events = [
      {'type': 'task_started', 'at': 0},
      {'type': 'approval_needed', 'approval_id': 'a1', 'kind': 'send', 'label': 'Email', 'input': {}, 'at': 1},
    ];
    expect(turnsOf(_task(events, status: 'waiting')).single.pending?['approval_id'], 'a1');
    final resolved = [...events, {'type': 'approval_resolved', 'approval_id': 'a1', 'approved': true, 'at': 2}];
    expect(turnsOf(_task(resolved, status: 'running')).single.pending, isNull);
    expect(turnsOf(_task(events, status: 'stopped')).single.pending, isNull);
  });

  test('a question stays on screen until it is answered', () {
    final events = [
      {'type': 'task_started', 'at': 0},
      {'type': 'question', 'question_id': 'q1', 'question': 'Which one?', 'choices': ['Nexus', 'Horizon'], 'at': 1},
    ];
    final open = turnsOf(_task(events, status: 'waiting')).single;
    expect(open.pendingQuestion?['question_id'], 'q1');
    expect(open.pendingQuestion?['choices'], ['Nexus', 'Horizon']);
    final answered = turnsOf(_task([
      ...events,
      {'type': 'question_answered', 'question_id': 'q1', 'text': 'Horizon', 'at': 2},
    ], status: 'running')).single;
    expect(answered.pendingQuestion, isNull);
    expect(turnsOf(_task(events, status: 'stopped')).single.pendingQuestion, isNull);
  });

  test('web pages Compii actually read become sources on the turn that used them', () {
    final turns = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'action_started', 'tool': 'read_web_page', 'label': 'Read x', 'at': 1},
      {'type': 'sources', 'tool': 'read_web_page', 'items': [
        {'title': 'Laptops', 'url': 'https://example.com/laptops'},
      ], 'at': 2},
      {'type': 'user_message', 'text': 'and now y', 'at': 10},
      {'type': 'sources', 'tool': 'read_web_page', 'items': [
        {'title': 'Desktops', 'url': 'https://example.com/desktops'},
        {'title': 'Again', 'url': 'https://example.com/desktops'},
      ], 'at': 11},
    ]));
    expect(turns.first.sources.single['url'], 'https://example.com/laptops');
    expect(turns.last.sources.map((s) => s['url']), ['https://example.com/desktops', 'https://example.com/desktops']);
  });

  test('a sources event with nothing usable in it is ignored', () {
    final turn = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'sources', 'tool': 'read_web_page', 'at': 1},
    ])).single;
    expect(turn.sources, isEmpty);
  });

  test('the running step shows until it finishes', () {
    final turn = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'action_started', 'tool': 'read_file', 'label': 'Read x', 'at': 1},
    ], status: 'running')).single;
    expect(turn.current?['label'], 'Read x');
    expect(turn.finished, isEmpty);
  });
}
