import 'package:compii/src/console/core_client.dart';
import 'package:compii/src/ui/shell.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:compii/src/ui/voice.dart';
import 'package:compii/src/ui/voice_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(VoiceDock dock) => MaterialApp(
  theme: compiiTheme(Brightness.light),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1200, 800), disableAnimations: true),
    child: Scaffold(body: Center(child: SizedBox(width: 700, child: dock))),
  ),
);

(CoreClient, AppState) _setup({bool canListen = true}) {
  final core = CoreClient();
  final state = AppState();
  state.voice = VoiceController(core)..status = {'listen_ready': canListen, 'settings': {'speak_replies': true}};
  return (core, state);
}

void main() {
  testWidgets('voice first: a talk button, no text box until you type', (tester) async {
    final (core, state) = _setup();
    final sent = <String>[];
    await tester.pumpWidget(_app(VoiceDock(core: core, state: state, onSend: (t) async => sent.add(t))));
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Tap to talk · or hold Ctrl + Alt in any app'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: 'typing anywhere opens the text box');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'h');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'Esc goes back to voice');
  });

  testWidgets('shows live captions and what you can say', (tester) async {
    final (core, state) = _setup();
    final task = TaskView(id: 't', request: 'email it', status: 'waiting')
      ..events.addAll([
        {'type': 'task_started', 'at': 0},
        {'type': 'approval_needed', 'approval_id': 'a', 'kind': 'send', 'label': 'Email it', 'input': {}, 'at': 1},
      ]);
    await tester.pumpWidget(_app(VoiceDock(core: core, state: state, task: task, onSend: (_) async {})));
    expect(find.textContaining('Say “yes” or “no”'), findsOneWidget);

    state.voice!
      ..speaking = true
      ..caption = 'I need your okay. Email it.';
    state.voice!.notifyListeners();
    await tester.pump();
    expect(find.text('I need your okay. Email it.'), findsOneWidget);
    expect(find.byTooltip('Stop talking'), findsOneWidget);
  });

  testWidgets('without voice set up, the text box is shown with a hint', (tester) async {
    final (core, state) = _setup(canListen: false);
    await tester.pumpWidget(_app(VoiceDock(core: core, state: state, onSend: (_) async {})));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Set up free voice'), findsOneWidget);
  });
}
