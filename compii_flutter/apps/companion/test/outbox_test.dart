import 'dart:convert';

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/mobile/outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCore extends CoreClient {
  FakeCore() {
    status = CoreStatus.offline;
  }

  void ping() => notifyListeners();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('keeps requests while the PC is away and sends them in order later', () async {
    final core = FakeCore();
    final sent = <Map<String, dynamic>>[];
    final outbox = Outbox(core, send: (a) async => sent.add(a));
    await outbox.init();

    await outbox.ask('Summarise the invoice');
    await outbox.reply('t1', 'Use the second one');
    await outbox.clipboard('12 Market Street');
    await outbox.open('https://example.com');
    await outbox.snippet('Address', '12 Market Street');
    expect(outbox.count, 5);

    await outbox.flush();
    expect(sent, isEmpty, reason: 'nothing goes out while the PC is unreachable');

    core.status = CoreStatus.online;
    await outbox.flush();
    expect(sent.map((a) => a['kind']), ['ask', 'reply', 'clipboard', 'url', 'snippet']);
    expect(outbox.count, 0);
    expect(core.status, CoreStatus.online);
    outbox.dispose();
    core.dispose();
  });

  test('the queue lives on the phone across launches', () async {
    final core = FakeCore();
    final first = Outbox(core);
    await first.init();
    await first.ask('Keep this for later');
    first.dispose();

    final reopened = Outbox(core);
    await reopened.init();
    expect(reopened.count, 1);
    expect(reopened.pending.single['text'], 'Keep this for later');
    expect(
      jsonDecode((await SharedPreferences.getInstance()).getString('phone_outbox')!) as List,
      hasLength(1),
    );
    reopened.dispose();
    core.dispose();
  });

  test('a request the PC refuses is dropped with a problem, not retried', () async {
    final core = FakeCore()..status = CoreStatus.online;
    final outbox = Outbox(core, send: (_) async => throw CoreError('A snippet called “Home” already exists.'));
    await outbox.init();
    await outbox.snippet('Home', '12 Market Street');
    await outbox.flush();
    expect(outbox.count, 0);
    expect(outbox.problem, contains('already exists'));
    outbox.dispose();
    core.dispose();
  });

  test('the oldest waiting requests make room at the cap', () async {
    final core = FakeCore();
    final outbox = Outbox(core, max: 3);
    await outbox.init();
    for (final text in ['one', 'two', 'three', 'four']) {
      await outbox.ask(text);
    }
    expect(outbox.count, 3);
    expect(outbox.pending.map((a) => a['text']), ['two', 'three', 'four']);
    outbox.dispose();
    core.dispose();
  });

  test('reconnecting sends the queue without being asked', () async {
    final core = FakeCore();
    final sent = <String>[];
    final outbox = Outbox(core, send: (a) async => sent.add('${a['text']}'));
    await outbox.init();
    await outbox.ask('Are you back?');

    core.status = CoreStatus.online;
    core.ping();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent, ['Are you back?']);
    expect(outbox.count, 0);
    outbox.dispose();
    core.dispose();
  });
}
