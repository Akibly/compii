import 'dart:async';

import 'package:compii/src/mobile/phone_automation.dart';
import 'package:compii/src/ui/automation.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeControls implements PhoneControls {
  FakeControls({this.access = const PhoneAccess()});

  PhoneAccess access;
  Map<String, dynamic>? snap;
  List<Map<String, dynamic>> notes = [];
  final List<String> calls = [];
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void post(Map<String, dynamic> note) => _events.add(note);

  void dispose() => _events.close();

  @override
  Future<PhoneAccess> status() async => access;

  @override
  Future<Map<String, dynamic>?> screen() async => snap;

  @override
  Future<bool> tap(String text) async {
    calls.add('tap $text');
    return true;
  }

  @override
  Future<bool> type(String text) async {
    calls.add('type $text');
    return true;
  }

  @override
  Future<bool> scroll(String direction) async {
    calls.add('scroll $direction');
    return true;
  }

  @override
  Future<bool> global(String action) async {
    calls.add('global $action');
    return true;
  }

  @override
  Future<String?> openApp(String query) async {
    calls.add('open $query');
    return query;
  }

  @override
  Future<List<Map<String, dynamic>>> notifications() async => notes;

  @override
  Future<void> openAccessibilitySettings() async => calls.add('screen settings');

  @override
  Future<void> openListenerSettings() async => calls.add('notification settings');
}

/// Wait for the stream listener to get through its async work, without
/// assuming the machine is quiet.
Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 2)}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a rule sends a matching notification to the PC', () async {
    final controls = FakeControls();
    final sent = <String>[];
    final rules = AutomationRules(
      controls,
      cooldown: Duration.zero,
      onFire: (rule, note) async => sent.add('${note['title']} :: ${rule.prompt}'),
    );
    await rules.start();
    await rules.add(const WatchRule(id: 'r1', app: 'WhatsApp', contains: 'urgent', prompt: 'Check it.'));

    final note = {
      'type': 'notification',
      'key': 'k1',
      'app': 'WhatsApp',
      'title': 'Mum',
      'text': 'This is urgent',
      'at': 1,
    };
    controls.post(note);
    await _until(() => sent.isNotEmpty);
    expect(sent, ['Mum :: Check it.']);

    controls.post({...note, 'key': 'k2'});
    await _until(() => sent.length > 1);
    expect(sent, hasLength(2));

    rules.dispose();
    controls.dispose();
  });

  test('a busy chat cannot flood the PC', () async {
    final controls = FakeControls();
    final sent = <String>[];
    final rules = AutomationRules(
      controls,
      onFire: (rule, note) async => sent.add('${note['title']}'),
    );
    await rules.start();
    await rules.add(const WatchRule(id: 'r1', app: 'WhatsApp', prompt: 'Check it.'));

    final note = {
      'type': 'notification',
      'key': 'k1',
      'app': 'WhatsApp',
      'title': 'Mum',
      'text': 'Hello',
      'at': 1,
    };
    controls.post(note);
    await _until(() => sent.isNotEmpty);
    controls.post({...note, 'key': 'k2'});
    controls.post({...note, 'key': 'k3'});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(sent, hasLength(1), reason: 'a rule fires at most once a minute');

    rules.dispose();
    controls.dispose();
  });

  test('a rule with no app and no phrase never matches everything', () async {
    const rule = WatchRule(id: 'r2', prompt: 'Tell me.');
    expect(
      rule.matches(const {'app': 'WhatsApp', 'title': 'Mum', 'text': 'Hello'}),
      isFalse,
    );
  });

  test('rules survive a restart and keep their pause switch', () async {
    final controls = FakeControls();
    final first = AutomationRules(controls, onFire: (_, _) async {});
    await first.start();
    await first.add(const WatchRule(id: 'r3', app: 'Teams', contains: '', prompt: 'Summarise it.'));
    await first.setPaused(true);
    first.dispose();

    final second = AutomationRules(controls, onFire: (_, _) async {});
    await second.start();
    expect(second.rules.single.app, 'Teams');
    expect(second.rules.single.prompt, 'Summarise it.');
    expect(second.paused, isTrue);
    second.dispose();
    controls.dispose();
  });

  test('a look keeps the labels it saw for the next visit', () async {
    final controls = FakeControls(access: const PhoneAccess(screen: true, screenReady: true));
    final said = <String>[];
    final automation = PhoneAutomation(controls, send: (_) async {}, say: said.add, switchTime: Duration.zero);
    await automation.start();
    controls.snap = {
      'app': 'Mail',
      'title': 'Inbox',
      'elements': [
        {'text': 'Inbox'},
        {'text': 'Send'},
        {'text': 'Inbox'},
        {'text': ''},
      ],
    };
    await automation.look();
    expect(automation.seenLabels, ['Inbox', 'Send']);
    expect(said.single, contains('Mail'));
    automation.dispose();
    controls.dispose();
  });

  testWidgets('the automation sheet shows access, actions, and rules', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 860));
    final controls = FakeControls(
      access: const PhoneAccess(
        screen: true,
        screenReady: true,
        notifications: true,
        notificationsReady: true,
      ),
    );
    final automation = PhoneAutomation(controls, send: (_) async {}, say: (_) {}, switchTime: Duration.zero);

    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: Scaffold(body: AutomationSheet(automation: automation)),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('On this phone'), findsOneWidget);
    expect(find.text('Read and touch this screen'), findsOneWidget);
    expect(find.text('See notifications'), findsOneWidget);

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Look now'), 200, scrollable: list);
    expect(find.text('Look now'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Add a rule'), 200, scrollable: list);
    expect(find.text('Add a rule'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Nothing caught yet.'), 200, scrollable: list);
    expect(find.text('Nothing caught yet.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    automation.dispose();
    controls.dispose();
  });
}
