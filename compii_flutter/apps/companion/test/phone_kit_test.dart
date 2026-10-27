// The phone's redesign: titles people can read, short times, quiet hours, and
// a button that has to be held before anything irreversible happens.
import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/mobile/phone_bridge.dart';
import 'package:compii/src/mobile/phone_notifier.dart';
import 'package:compii/src/ui/phone_kit.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat titles drop notes for the AI, file names and job labels', () {
    expect(chatTitle('Okay say hi.\n\n(Spoken, then transcribed: it may be misheard.)'), 'Okay say hi.');
    expect(chatTitle('What is this? Look at this photo from my phone (photo-2026-10-27-17.54.26.jpg) and tell me.'),
        'What is this? (photo)');
    expect(chatTitle('Job from Compii: Produce today’s morning briefing. Gather 10-15 items across four topics please.'),
        'Produce today’s morning briefing.');
    final long = chatTitle('Find every invoice from last month in my Downloads folder and put them all into one spreadsheet');
    expect(long.length, lessThanOrEqualTo(61));
    expect(long, endsWith('…'));
  });

  test('times are short enough for a row’s corner', () {
    final now = DateTime(2026, 10, 27, 18, 0);
    expect(shortWhen(now.subtract(const Duration(seconds: 20)), now: now), 'now');
    expect(shortWhen(now.subtract(const Duration(minutes: 4)), now: now), '4 min');
    expect(shortWhen(now.subtract(const Duration(hours: 3)), now: now), '3 h');
    expect(shortWhen(DateTime(2026, 10, 26, 22), now: now), 'Yesterday');
    expect(shortWhen(DateTime(2026, 10, 23, 9), now: now), 'Fri');
    expect(shortWhen(DateTime(2026, 9, 2, 9), now: now), '2 Sep');
  });

  test('quiet hours can cross midnight', () {
    final n = PhoneNotifier(CoreClient(), PhoneBridge.instance)
      ..quiet = true
      ..quietFrom = 22 * 60
      ..quietTo = 7 * 60;
    expect(n.isQuiet(DateTime(2026, 10, 27, 23, 30)), isTrue);
    expect(n.isQuiet(DateTime(2026, 10, 28, 6, 59)), isTrue);
    expect(n.isQuiet(DateTime(2026, 10, 28, 7, 0)), isFalse);
    expect(n.isQuiet(DateTime(2026, 10, 27, 13, 0)), isFalse);
    n.quiet = false;
    expect(n.isQuiet(DateTime(2026, 10, 27, 23, 30)), isFalse);
  });

  testWidgets('a hold button acts only when held, not on a tap', (tester) async {
    var held = 0;
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.dark),
      home: Scaffold(body: Center(child: SizedBox(width: 300, child: HoldButton(label: 'delete', onHeld: () => held++)))),
    ));
    expect(find.text('Hold to delete'), findsOneWidget);
    await tester.tap(find.byType(HoldButton));
    await tester.pumpAndSettle();
    expect(held, 0, reason: 'a brush is not a yes');

    final press = await tester.startGesture(tester.getCenter(find.byType(HoldButton)));
    await tester.pump(const Duration(milliseconds: 150)); // the press registers
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Keep holding…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    await press.up();
    await tester.pumpAndSettle();
    expect(held, 1);
  });
}
