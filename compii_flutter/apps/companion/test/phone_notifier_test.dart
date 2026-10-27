import 'dart:async';

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/mobile/phone_bridge.dart';
import 'package:compii/src/mobile/phone_notifier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAlerts implements PhoneAlerts {
  FakeAlerts({this.allowed = true});
  bool allowed;
  final List<Map<String, dynamic>> notes = [];
  final List<String> cancelled = [];
  final List<Map<String, dynamic>> widgets = [];
  final StreamController<Map<String, dynamic>> incoming = StreamController.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => incoming.stream;

  @override
  Future<bool> notificationsAllowed() async => allowed;

  @override
  Future<bool> requestNotifications() async {
    allowed = true;
    return true;
  }

  @override
  Future<void> notify({
    required String tag,
    required String title,
    required String body,
    String destination = 'chats',
  }) async =>
      notes.add({'tag': tag, 'title': title, 'body': body, 'destination': destination});

  @override
  Future<void> cancel(String tag) async => cancelled.add(tag);

  @override
  Future<void> cancelAll() async => notes.clear();

  @override
  Future<void> widget({required String headline, required String detail, String meta = ''}) async =>
      widgets.add({'headline': headline, 'detail': detail, 'meta': meta});

  @override
  Future<void> openNotificationSettings() async {}

  final List<String> link = [];
  bool linkWorks = false;

  @override
  Future<bool> startLink(RemoteLink remote) async {
    link.add('start ${remote.pc}');
    return linkWorks;
  }

  @override
  Future<void> stopLink() async => link.add('stop');
}

class FakeCore extends CoreClient {
  FakeCore() {
    status = CoreStatus.online;
  }

  void ping() => notifyListeners();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an approval is told once, and cleared when it is answered', () async {
    final core = FakeCore();
    final alerts = FakeAlerts();
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    notifier.setForeground(false);

    final task = TaskView(id: 't1', request: 'Send the invoice', status: 'waiting');
    task.events.add({'type': 'approval_needed', 'approval_id': 'a1', 'label': 'Email Sam'});
    core.tasks['t1'] = task;
    core.ping();
    expect(alerts.notes, hasLength(1));
    expect(alerts.notes.single['title'], 'Compii needs your OK');
    expect(alerts.notes.single['body'], 'Email Sam');
    expect(alerts.notes.single['destination'], 'task:t1');

    core.ping();
    expect(alerts.notes, hasLength(1), reason: 'the same approval is not told twice');

    task.events.add({'type': 'approval_resolved', 'approval_id': 'a1'});
    core.ping();
    expect(alerts.cancelled, contains('ok:t1:a1'));

    notifier.dispose();
    core.dispose();
  });

  test('a finished answer is announced with its words', () async {
    final core = FakeCore();
    final alerts = FakeAlerts();
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    notifier.setForeground(false);

    final task = TaskView(id: 't2', request: 'Find the invoice', status: 'running');
    core.tasks['t2'] = task;
    core.ping();
    expect(alerts.notes, isEmpty);

    task.status = 'done';
    task.events.add({'type': 'task_finished', 'text': 'It’s the March invoice, **number 42**.'});
    core.ping();
    expect(alerts.notes, hasLength(1));
    expect(alerts.notes.single['title'], 'Compii finished');
    expect(alerts.notes.single['body'], 'It’s the March invoice, number 42.');
    expect(alerts.notes.single['destination'], 'task:t2');

    notifier.dispose();
    core.dispose();
  });

  test('what you watched happen in the app is not announced when you leave it', () async {
    final core = FakeCore();
    final alerts = FakeAlerts();
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();

    final task = TaskView(id: 't3', request: 'Sort the photos', status: 'done');
    task.events.add({'type': 'task_finished', 'text': 'Done — three folders.'});
    core.tasks['t3'] = task;
    core.ping();
    expect(alerts.notes, isEmpty);

    notifier.setForeground(false);
    core.ping();
    expect(alerts.notes, isEmpty);

    notifier.dispose();
    core.dispose();
  });

  test('with the switch off or no permission, nothing is posted', () async {
    final core = FakeCore();
    final alerts = FakeAlerts(allowed: false);
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    notifier.setForeground(false);

    final task = TaskView(id: 't4', request: 'Book a table', status: 'done');
    task.events.add({'type': 'task_finished', 'text': 'Booked.'});
    core.tasks['t4'] = task;
    core.ping();
    expect(alerts.notes, isEmpty);

    alerts.allowed = true;
    await notifier.setEnabled(false);
    alerts.allowed = true;
    core.ping();
    expect(alerts.notes, isEmpty);

    notifier.dispose();
    core.dispose();
  });

  test('the widget follows what Compii is doing', () async {
    final core = FakeCore();
    final alerts = FakeAlerts();
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    expect(alerts.widgets.last['headline'], 'Compii is ready');
    expect(alerts.widgets.last['detail'], 'Ask anything from your phone.');

    core.tasks['t5'] = TaskView(id: 't5', request: 'Send the invoice', status: 'waiting')
      ..events.add({'type': 'approval_needed', 'approval_id': 'a9', 'label': 'Email Sam'});
    core.ping();
    expect(alerts.widgets.last['headline'], '1 thing needs your OK');
    expect(alerts.widgets.last['meta'], 'Tap to review');

    core.status = CoreStatus.offline;
    core.ping();
    expect(alerts.widgets.last['headline'], 'Compii is out of reach');

    notifier.dispose();
    core.dispose();
  });

  test('a brief from Compii arrives as a notification too', () async {
    final core = FakeCore();
    final alerts = FakeAlerts();
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    notifier.setForeground(false);

    core.updates.add({'id': 'u1', 'title': 'Morning brief', 'body': 'Two things need you today.', 'task_id': 't6'});
    await Future<void>.delayed(Duration.zero);
    expect(alerts.notes, hasLength(1));
    expect(alerts.notes.single['title'], 'Morning brief');
    expect(alerts.notes.single['body'], 'Two things need you today.');
    expect(alerts.notes.single['destination'], 'task:t6');

    notifier.dispose();
    core.dispose();
  });

  test('paired with alerts on, the background link takes over and the app stops posting copies', () async {
    final core = FakeCore()
      ..remote = const RemoteLink(host: '100.64.0.2', port: 8766, fingerprint: 'ab', token: 'dev', pc: 'Desk');
    final alerts = FakeAlerts()..linkWorks = true;
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    expect(alerts.link, ['start Desk']);
    expect(notifier.linked, isTrue);
    notifier.setForeground(false);

    final task = TaskView(id: 't1', request: 'Send the invoice', status: 'waiting');
    task.events.add({'type': 'approval_needed', 'approval_id': 'a1', 'label': 'Email Sam'});
    core.tasks['t1'] = task;
    core.ping();
    expect(alerts.notes, isEmpty, reason: 'the link posts it, with Approve and Deny, so no duplicate');

    await notifier.setEnabled(false);
    expect(alerts.link.last, 'stop', reason: 'alerts off: the link stops too');
    await notifier.setEnabled(true);
    expect(alerts.link.last, 'start Desk');
    await notifier.unlink();
    expect(alerts.link.last, 'stop', reason: 'forgetting the PC ends the link');
    expect(notifier.linked, isFalse);

    notifier.dispose();
    core.dispose();
  });

  test('without a working link the app keeps posting its own alerts', () async {
    final core = FakeCore()
      ..remote = const RemoteLink(host: '100.64.0.2', port: 8766, fingerprint: 'ab', token: 'dev', pc: 'Desk');
    final alerts = FakeAlerts(); // linkWorks false: e.g. not Android
    final notifier = PhoneNotifier(core, alerts);
    await notifier.start();
    notifier.setForeground(false);
    final task = TaskView(id: 't1', request: 'Send the invoice', status: 'waiting');
    task.events.add({'type': 'approval_needed', 'approval_id': 'a1', 'label': 'Email Sam'});
    core.tasks['t1'] = task;
    core.ping();
    expect(alerts.notes, hasLength(1));
    notifier.dispose();
    core.dispose();
  });
}
