import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/console/console_screen.dart';
import 'src/console/core_client.dart';
import 'src/overlay/overlay_app.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--overlay')) return runOverlay();
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) await _startOverlay();
  final core = CoreClient()..start();
  runApp(
    MaterialApp(
      title: 'Compii',
      debugShowCheckedModeBanner: false,
      theme: consoleTheme(),
      home: ConsoleScreen(core: core),
    ),
  );
}

/// The pointing overlay runs as a second copy of this app in its own
/// transparent window; it closes when the main window closes.
Future<void> _startOverlay() async {
  try {
    final overlay = await Process.start(Platform.resolvedExecutable, ['--overlay']);
    await windowManager.ensureInitialized();
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
