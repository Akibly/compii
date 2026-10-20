import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// App-wide controls that pages need without importing main.dart.
class AppControl {
  /// The pointing / cursor-buddy overlay process.
  Process? overlay;

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// Whether Compii starts quietly when you sign in to Windows (per-user, no admin needed).
  Future<bool> startsWithWindows() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run('reg', ['query', _runKey, '/v', 'Compii']);
    return r.exitCode == 0;
  }

  Future<void> setStartWithWindows(bool on) async {
    if (!Platform.isWindows) return;
    final args = on
        ? ['add', _runKey, '/v', 'Compii', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --background', '/f']
        : ['delete', _runKey, '/v', 'Compii', '/f'];
    final r = await Process.run('reg', args);
    if (r.exitCode != 0 && on) throw Exception('Windows didn\'t accept the start-up setting: ${r.stderr}');
  }

  /// Really quit: the window and the cursor buddy (Compii Core keeps running).
  Future<void> quit() async {
    overlay?.kill();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}

final appControl = AppControl();
