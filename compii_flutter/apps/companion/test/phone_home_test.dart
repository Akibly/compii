import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/mobile/outbox.dart';
import 'package:compii/src/ui/phone_home.dart';
import 'package:compii/src/ui/phone_voice.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the phone shows what needs an OK, the conversations, and the PC controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 860));
    const fp = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';
    final core = CoreClient(
      remote: const RemoteLink(host: '192.168.1.20', port: 8766, fingerprint: fp, token: 't', pc: 'Desk', hosts: ['192.168.1.20']),
    )..status = CoreStatus.online;
    core.tasks['t1'] = TaskView(id: 't1', request: 'Send the invoice to Sam', status: 'waiting')
      ..events.add({'type': 'approval_needed', 'approval_id': 'a1', 'task_id': 't1', 'tool': 'send_email', 'label': 'Email Sam', 'kind': 'send', 'input': {'to': 'sam@example.com'}});
    final state = AppState();
    final voice = PhoneVoice(core);

    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: PhoneHome(core: core, state: state, voice: voice, onForget: () async {}),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Compii needs your OK: Email Sam'), findsOneWidget);

    // The callback directly: a tap would load Flutter's ink-sparkle shader, which
    // this SDK can't verify in tests.
    void selectTab(int i) => tester.widget<NavigationBar>(find.byType(NavigationBar)).onDestinationSelected!(i);

    selectTab(1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Send the invoice to Sam'), findsOneWidget);
    expect(find.textContaining('Needs your OK'), findsOneWidget);

    selectTab(2);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Desk'), findsWidgets);
    expect(find.text('Connected on your Wi-Fi'), findsOneWidget);
    expect(find.text('What’s on screen?'), findsOneWidget);
    expect(find.text('Copy to PC'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Install the free Tailscale app'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Install the free Tailscale app'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a request made while the PC is away waits on the phone instead of failing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 860));
    const fp = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';
    final core = CoreClient(
      remote: const RemoteLink(host: '192.168.1.20', port: 8766, fingerprint: fp, token: 't', pc: 'Desk', hosts: ['192.168.1.20']),
    )..status = CoreStatus.offline;
    final state = AppState();
    final voice = PhoneVoice(core);
    final outbox = Outbox(core, send: (_) async {});
    await outbox.init();

    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.light),
      home: PhoneHome(core: core, state: state, voice: voice, onForget: () async {}, outbox: outbox),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(core.status, CoreStatus.offline);

    await tester.widget<Composer>(find.byType(Composer)).onSend('Book a table for two');
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.error, isNull);
    expect(outbox.count, 1);
    expect(outbox.pending.single['text'], 'Book a table for two');
    expect(find.textContaining('1 waiting to send'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    outbox.dispose();
  });
}
