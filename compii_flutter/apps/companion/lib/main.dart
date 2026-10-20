import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app_control.dart';
import 'src/diagnostics.dart';
import 'src/console/character.dart';
import 'src/console/console_screen.dart';
import 'src/console/core_client.dart';
import 'src/overlay/overlay_app.dart';
import 'src/ui/first_run.dart';
import 'src/ui/proactive.dart';
import 'src/ui/quick_bar.dart';
import 'src/ui/shell.dart';
import 'src/ui/tokens.dart';
import 'src/ui/trust.dart';
import 'src/ui/voice.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--overlay')) return runOverlay();
  WidgetsFlutterBinding.ensureInitialized();
  CrashLog.install();
  await ensureCore();
  keepCoreAlive();
  final core = CoreClient()..start();
  final state = AppState();
  await state.load();
  final voice = VoiceController(core);
  state.voice = voice;
  QuickMode? quick;
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(380, 120));
    // Compii draws its own title bar (drag area and window buttons).
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    quick = QuickMode(state);
    try {
      // Kept simple on purpose: hold Ctrl+Alt (talk) and Ctrl+Win (dictate) live in
      // Core; the app only adds Alt+Space (show/hide) and the kill switch.
      // Talking from any app is Core's hold-Ctrl+Alt (see compii_core/hotkey.py).
      // Alt+Space shows or hides this window.
      await hotKeyManager.register(
        HotKey(key: PhysicalKeyboardKey.space, modifiers: [HotKeyModifier.alt], scope: HotKeyScope.system),
        keyDownHandler: (_) async {
          if (quick?.active == true) return;
          if (await windowManager.isVisible() && await windowManager.isFocused()) {
            await windowManager.hide();
          } else {
            await windowManager.show();
            await windowManager.focus();
          }
        },
      );
      // Kill switch from anywhere: stop everything; every action asks until lifted.
      await hotKeyManager.register(
        HotKey(
          key: PhysicalKeyboardKey.keyS,
          modifiers: [HotKeyModifier.control, HotKeyModifier.alt, HotKeyModifier.shift],
          scope: HotKeyScope.system,
        ),
        keyDownHandler: (_) async {
          voice.quiet();
          try {
            await TrustApi.kill();
          } on Object catch (e) {
            debugPrint('Kill switch: $e');
          }
        },
      );
    } on Object catch (e) {
      debugPrint('Hotkeys not available: $e');
    }
    await _startOverlay();
    _watchWindowShown();
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
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: windowShown,
        // Hidden, minimised or in the background: pause every animation (it was up to a CPU core).
        builder: (context, shown, _) => TickerMode(
          enabled: shown,
          child: Listener(
            onPointerHover: (e) => pointer.value = e.position,
            onPointerMove: (e) => pointer.value = e.position,
            child: UpdateNotices(core: core, onView: () => state.go(Section.updates), child: child!),
          ),
        ),
      ),
      home: quick?.active == true
          ? QuickBar(core: core, quick: quick!)
          : FirstRunGate(core: core, voice: state.voice, child: ConsoleScreen(core: core, state: state)),
    ),
  );
}

/// The pointing overlay runs as a second copy of this app in its own
/// transparent window. Closing the main window only hides it: Compii keeps
/// running for the cursor buddy (hold Ctrl+Alt). Quit from Settings.
Future<void> _startOverlay() async {
  try {
    appControl.overlay = await Process.start(Platform.resolvedExecutable, ['--overlay']);
    await windowManager.setPreventClose(true);
    windowManager.addListener(_HideOnClose());
  } on Object catch (e) {
    debugPrint('Compii overlay did not start: $e');
  }
}

/// Whether you're using the main window (shown, not minimised, in front). Otherwise its
/// animations pause: the cursor buddy is how Compii shows up while you work elsewhere.
final windowShown = ValueNotifier<bool>(true);

void _watchWindowShown() {
  Timer.periodic(const Duration(milliseconds: 700), (_) async {
    try {
      windowShown.value = await windowManager.isVisible() && !await windowManager.isMinimized() &&
          await windowManager.isFocused();
    } on Object {
      windowShown.value = true;
    }
  });
}

class _HideOnClose with WindowListener {
  @override
  Future<void> onWindowClose() async => windowManager.hide();
}

/// If Core ever stops (a crash, the PC waking from sleep…), start it again
/// instead of leaving Compii stuck. Checks every 10 s; waits 30 s after a start.
void keepCoreAlive() {
  var restartedAt = DateTime.now();
  Timer.periodic(const Duration(seconds: 10), (_) async {
    if (DateTime.now().difference(restartedAt) < const Duration(seconds: 30)) return;
    if (await ensureCore()) restartedAt = DateTime.now();
  });
}

/// Start Compii Core if it isn't running, so the app just works when opened.
/// Returns true when it had to start it.
Future<bool> ensureCore() async {
  final http = HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
  try {
    final req = await http.getUrl(Uri.parse('http://127.0.0.1:8765/health'));
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
    if (res.statusCode == 200) return false;
  } on Object {
    // not running: start it below
  } finally {
    http.close(force: true);
  }
  final dir = _findCore();
  if (dir == null) return false;
  try {
    // pythonw: Core runs quietly in the background, with no black console window.
    final quiet = '$dir${Platform.pathSeparator}.venv${Platform.pathSeparator}Scripts${Platform.pathSeparator}pythonw.exe';
    if (Platform.isWindows && File(quiet).existsSync()) {
      await Process.start(quiet, ['-m', 'compii_core.server'], workingDirectory: dir, mode: ProcessStartMode.detached);
    } else {
      await Process.start('uv', ['run', 'compii-core'], workingDirectory: dir, mode: ProcessStartMode.detached, runInShell: true);
    }
    return true;
  } on Object catch (e) {
    debugPrint('Could not start Compii Core: $e');
    return false;
  }
}

String? _findCore() {
  final env = Platform.environment['COMPII_CORE_DIR'];
  if (env != null && File('$env/pyproject.toml').existsSync()) return env;
  for (final start in [File(Platform.resolvedExecutable).parent, Directory.current]) {
    Directory? d = start;
    for (var i = 0; i < 10 && d != null; i++) {
      final candidate = '${d.path}${Platform.pathSeparator}compii_core';
      if (File('$candidate${Platform.pathSeparator}pyproject.toml').existsSync()) return candidate;
      final parent = d.parent;
      d = parent.path == d.path ? null : parent;
    }
  }
  return null;
}
