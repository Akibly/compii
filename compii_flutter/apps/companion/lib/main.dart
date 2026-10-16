import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/console/console_screen.dart';
import 'src/console/core_client.dart';
import 'src/overlay/overlay_app.dart';
import 'src/ui/quick_bar.dart';
import 'src/ui/shell.dart';
import 'src/ui/tokens.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--overlay')) return runOverlay();
  WidgetsFlutterBinding.ensureInitialized();
  final core = CoreClient()..start();
  final state = AppState();
  QuickMode? quick;
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(380, 120));
    quick = QuickMode(state);
    try {
      await quick.registerHotkey();
    } on Object catch (e) {
      debugPrint('Quick bar hotkey not available: $e');
    }
    await _startOverlay();
  }
  runApp(CompiiApp(core: core, state: state, quick: quick));
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
