import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/reader.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:compii/src/ui/voice.dart';
import 'package:compii/src/ui/voice_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1200, 800), disableAnimations: true),
    child: Scaffold(body: Center(child: SizedBox(width: 700, child: child))),
  ),
);

void main() {
  testWidgets('a long caption offers the full answer in a reader', (tester) async {
    final core = CoreClient();
    final state = AppState();
    state.voice = VoiceController(core)
      ..status = {'listen_ready': true, 'settings': {'output_mode': 'voice'}};
    await tester.pumpWidget(_app(VoiceDock(core: core, state: state, onSend: (_) async {})));

    final long = '# Findings\n\n${'This is a **sourced** sentence with detail. ' * 30}';
    state.voice!
      ..speaking = true
      ..caption = long
      ..captionAt = DateTime.now();
    state.voice!.notifyListeners();
    await tester.pump();

    expect(find.text('Read all'), findsOneWidget, reason: 'a cut caption never hides that more exists');
    await tester.tap(find.text('Read all'));
    await tester.pumpAndSettle();

    expect(find.byType(AnswerReader), findsOneWidget);
    expect(find.text('Findings'), findsOneWidget);
    expect(find.textContaining('words ·'), findsOneWidget);
  });

  testWidgets('the last answer stays readable after speech ends', (tester) async {
    final core = CoreClient();
    final state = AppState();
    state.voice = VoiceController(core)
      ..status = {'listen_ready': true, 'settings': {'output_mode': 'voice'}};
    await tester.pumpWidget(_app(VoiceDock(core: core, state: state, onSend: (_) async {})));

    state.voice!
      ..lastAnswer = 'The full answer is kept even after the caption fades.'
      ..lastAnswerAt = DateTime.now();
    state.voice!.notifyListeners();
    await tester.pump();

    expect(find.byTooltip('Read the last answer in full'), findsOneWidget);
    await tester.tap(find.byTooltip('Read the last answer in full'));
    await tester.pumpAndSettle();
    expect(find.byType(AnswerReader), findsOneWidget);
    expect(find.textContaining('kept even after'), findsOneWidget);
  });
}
