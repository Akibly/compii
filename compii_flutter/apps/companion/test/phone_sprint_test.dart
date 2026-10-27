// The phone's first sprint: today's brief and recap at the top of the chats, and
// the Halo face as the Talk tab. With --dart-define=CAPTURE=true it saves both.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/phone_digest.dart';
import 'package:compii/src/ui/phone_home.dart';
import 'package:compii/src/ui/phone_voice.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _today = DateTime(2026, 10, 27, 19, 30);
double _at(int hour) => DateTime(2026, 10, 27, hour).millisecondsSinceEpoch / 1000;

class _Core extends CoreClient {
  _Core({super.remote}) {
    status = CoreStatus.online;
  }
  int briefs = 0;
  List<Map<String, dynamic>> inbox = [
    {
      'kind': 'brief', 'title': 'Your day, wrapped up', 'body': '4 tasks finished, 1 still waits on you.', 'at': _at(18),
      'sections': [
        {'title': 'Finished today', 'items': ['Q3 summary for Tom', 'Tidied Downloads']},
        {'title': 'Still waiting on you', 'items': ['Send the summary to Tom?']},
      ],
    },
    {
      'kind': 'brief', 'title': 'Good morning — your brief', 'body': 'Three things today: Tom’s summary, two invoices due, a 3 pm call.',
      'at': _at(8), 'sections': const [],
    },
    {'kind': 'brief', 'title': 'Good morning — your brief', 'body': 'Yesterday’s brief.', 'at': _at(8) - 86400},
  ];

  @override
  Future<Map<String, dynamic>> proactive() async {
    final v = {'inbox': inbox, 'unread': 0};
    plansCache = v;
    return v;
  }

  @override
  Future<void> briefNow() async => briefs++;
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('CAPTURE')) return;
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
  final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  final out = Directory('../../../docs/compii/build-previews/halo')..createSync(recursive: true);
  await tester.runAsync(() => File('${out.path}/phone-$name.png').writeAsBytes(bytes!.buffer.asUint8List()));
}

void main() {
  testWidgets('today shows the brief and the recap, and only today’s', (tester) async {
    final core = _Core();
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.dark),
      home: Scaffold(body: DigestCard(core: core, now: () => _today)),
    ));
    await tester.pump();
    expect(find.text('Morning brief'), findsOneWidget);
    expect(find.text('Evening recap'), findsOneWidget);
    expect(find.textContaining('Three things today'), findsOneWidget);
    expect(find.text('Yesterday’s brief.'), findsNothing);

    await tester.tap(find.text('Evening recap'));
    await tester.pumpAndSettle();
    expect(find.text('Q3 summary for Tom', findRichText: true), findsNothing);
    expect(find.text('•  Q3 summary for Tom'), findsOneWidget, reason: 'the sections open on a tap');
    Navigator.of(tester.element(find.text('•  Q3 summary for Tom'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Brief me now'));
    await tester.pump();
    expect(core.briefs, 1);
  });

  testWidgets('the phone: the Halo face as Talk, the day at the top of Chats', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const fp = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';
    final core = _Core(remote: const RemoteLink(host: '192.168.1.20', port: 8766, fingerprint: fp, token: 't', pc: 'Desk'));
    core.tasks['t1'] = TaskView(id: 't1', request: 'Summarise the Q3 invoices for Tom', status: 'done')
      ..events.add({'type': 'task_finished', 'text': 'Saved the summary.', 'at': _at(9)});
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: compiiTheme(Brightness.dark),
        home: PhoneHome(core: core, state: AppState(), voice: PhoneVoice(core), onForget: () async {}),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await _shot(tester, key, 'talk');

    tester.widget<NavigationBar>(find.byType(NavigationBar)).onDestinationSelected!(1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Your day'), findsOneWidget);
    expect(find.text('Brief me now'), findsOneWidget);
    await _shot(tester, key, 'chats');
    await tester.pumpWidget(const SizedBox());
  });
}
