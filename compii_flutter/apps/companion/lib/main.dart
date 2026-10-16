import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'src/console/character.dart';
import 'src/console/console_screen.dart';
import 'src/console/core_client.dart';
import 'src/overlay/overlay_app.dart';
import 'src/ui/quick_bar.dart';
import 'src/ui/shell.dart';
import 'src/ui/tokens.dart';
import 'src/ui/voice.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--overlay')) return runOverlay();
  WidgetsFlutterBinding.ensureInitialized();
  final core = CoreClient()..start();
  final state = AppState();
  final voice = VoiceController(core);
  state.voice = voice;
  QuickMode? quick;
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(380, 120));
    quick = QuickMode(state);
    try {
      await quick.registerHotkey();
      // Talk from anywhere: press to start, press again to send.
      await hotKeyManager.register(
        HotKey(key: PhysicalKeyboardKey.space, modifiers: [HotKeyModifier.control, HotKeyModifier.alt], scope: HotKeyScope.system),
        keyDownHandler: (_) => voice.speaking ? voice.quiet() : voice.toggle(),
      );
    } on Object catch (e) {
      debugPrint('Hotkeys not available: $e');
    }
    await _startOverlay();
  }
  voice.onHeard = (text) => _deliver(text, core, state, quick);
  runApp(CompiiApp(core: core, state: state, quick: quick));
}

/// Where a spoken request goes: the quick bar's conversation, the open
/// conversation as a follow-up, or a new conversation.
Future<void> _deliver(String text, CoreClient core, AppState state, QuickMode? quick) async {
  try {
    if (quick != null && quick.active) {
      if (quick.task == null) {
        quick.task = await core.startConversation(text);
        await quick.expand();
      } else {
        await core.reply(quick.task!, text);
      }
      return;
    }
    final open = state.section == Section.chat && state.selected != null ? core.tasks[state.selected] : null;
    if (open != null && !open.active) {
      await core.reply(open.id, text);
    } else {
      state.open(await core.startConversation(text));
    }
  } catch (e) {
    state.fail(e);
  }
}

class CompiiApp extends StatelessWidget {
  const CompiiApp({super.key, required this.core, required this.state, this.quick});
  final CoreClient core;
  final AppState state;
  final QuickMode? quick;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([state, ?quick]),
    builder: (context, _) => MaterialApp(
      title: 'Compii',
      debugShowCheckedModeBanner: false,
      theme: compiiTheme(Brightness.light),
      darkTheme: compiiTheme(Brightness.dark),
      themeMode: state.themeMode,
      // The character's eyes follow the mouse anywhere in the window.
      builder: (context, child) => Listener(
        onPointerHover: (e) => pointer.value = e.position,
        onPointerMove: (e) => pointer.value = e.position,
        child: child,
      ),
      home: quick?.active == true
          ? QuickBar(core: core, quick: quick!)
          : ConsoleScreen(core: core, state: state),
    ),
  );
}

/// The pointing overlay runs as a second copy of this app in its own
/// transparent window; it closes when the main window closes.
Future<void> _startOverlay() async {
  try {
    final overlay = await Process.start(Platform.resolvedExecutable, ['--overlay']);
    await windowManager.setPreventClose(true);
    windowManager.addListener(_CloseOverlay(overlay));
  } on Object catch (e) {
    debugPrint('Compii overlay did not start: $e');
  }
}

class _CloseOverlay with WindowListener {
  _CloseOverlay(this.overlay);
  final Process overlay;

  @override
  Future<void> onWindowClose() async {
    overlay.kill();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}
