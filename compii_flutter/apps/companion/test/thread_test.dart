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

  test('an event with missing fields shrinks the thread instead of breaking it', () {
    final events = <Map<String, dynamic>>[
      {'type': 'task_started', 'at': 0},
      {'type': 'plan', 'at': 1},
      {'type': 'note', 'at': 2},
      {'type': 'sources', 'at': 2},
      {'type': 'approval_resolved', 'at': 3},
      {'type': 'question_answered', 'at': 3},
      {'type': 'takeover_done', 'at': 3},
      {'type': 'task_finished', 'at': 4},
    ];
    final turns = turnsOf(_task(events, status: 'running'));
    expect(turns, hasLength(1));
    expect(turns.single.plan, isEmpty, reason: 'a plan with no steps is no steps');
    expect(turns.single.notes, isEmpty);
    expect(turns.single.sources, isEmpty);
    expect(turns.single.reply, isNull, reason: 'an end that carried no words is not an empty answer');
    // Nothing is invented for a field that never arrived, so the turn falls back to
    // whatever the conversation says it is — running, or done, or stopped.
    expect(turns.single.status, 'running');
    expect(turnsOf(_task(events)).single.status, 'done');
  });

  test('attachments stay with the turn they were sent in', () {
    final turns = turnsOf(_task([
      {'type': 'task_started', 'at': 0, 'attachments': [
        {'name': 'report.pdf', 'path': 'C:\\Compii\\uploads\\report.pdf', 'size': 1200, 'kind': 'pdf'},
      ]},
      {'type': 'task_finished', 'status': 'done', 'text': 'Read it.', 'at': 4},
      {'type': 'user_message', 'text': 'and this', 'at': 10, 'attachments': [
        {'name': 'sheet.xlsx', 'path': 'C:\\Compii\\uploads\\sheet.xlsx', 'size': 2048, 'kind': 'xlsx'},
      ]},
      {'type': 'task_finished', 'status': 'done', 'text': 'Done.', 'at': 12},
    ]));
    expect(turns.first.attachments.single['name'], 'report.pdf');
    expect(turns.last.attachments.single['name'], 'sheet.xlsx');
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

  test('a secret step stays on screen until the user hands it back', () {
    final events = [
      {'type': 'task_started', 'at': 0},
      {'type': 'takeover', 'takeover_id': 'k1', 'what': 'Type your password.', 'fields': [
        {'label': 'Password', 'kind': 'secret'},
      ], 'at': 1},
    ];
    expect(turnsOf(_task(events, status: 'waiting')).single.pendingTakeover?['takeover_id'], 'k1');
    final done = turnsOf(_task([
      ...events,
      {'type': 'takeover_done', 'takeover_id': 'k1', 'outcome': 'done', 'at': 2},
    ], status: 'running')).single;
    expect(done.pendingTakeover, isNull);
    expect(turnsOf(_task(events, status: 'stopped')).single.pendingTakeover, isNull);
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

  test('words appear while the answer is still being written, then give way to the final reply', () {
    final live = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'answer_delta', 'text': 'Ghana ', 'at': 1},
      {'type': 'answer_delta', 'text': 'Ghana uses GMT.', 'at': 2},
    ], status: 'running')).single;
    expect(live.reply, isNull);
    expect(live.draft, 'Ghana uses GMT.');

    final finished = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'answer_delta', 'text': 'Ghana uses', 'at': 1},
      {'type': 'task_finished', 'status': 'done', 'text': 'Ghana uses GMT.', 'at': 2},
    ])).single;
    expect(finished.draft, isNull);
    expect(finished.reply, 'Ghana uses GMT.');
  });

  test('a half-written preamble is dropped when Compii moves on to an action', () {
    final turn = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'answer_delta', 'text': 'Let me open that', 'at': 1},
      {'type': 'action_started', 'tool': 'open_item', 'label': 'Open the report', 'at': 2},
    ], status: 'running')).single;
    expect(turn.draft, isNull);
    expect(turn.current?['label'], 'Open the report');
  });

  test('what Compii looked at stays with the turn that looked, not the next one', () {
    final turns = turnsOf(_task([
      {'type': 'task_started', 'at': 0},
      {'type': 'screen_seen', 'title': 'Budget.xlsx - Excel', 'items': 42, 'ocr': 30, 'at': 1},
      {'type': 'task_finished', 'status': 'done', 'text': 'C4 has a #REF! error.', 'at': 3},
      {'type': 'user_message', 'text': 'and this one?', 'at': 10},
      {'type': 'screen_seen', 'title': '', 'items': 0, 'ocr': 0, 'at': 11},
    ]));
    expect(turns, hasLength(2));
    expect(turns.first.screens.single['title'], 'Budget.xlsx - Excel');
    expect(turns.first.screens.single['ocr'], 30);
    expect(turns.last.screens.single['title'], '');
    expect(turns.last.screens, hasLength(1));
  });
}
