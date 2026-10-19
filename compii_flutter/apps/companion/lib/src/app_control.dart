import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// App-wide controls that pages need without importing main.dart.
class AppControl {
  /// The pointing / cursor-buddy overlay process.
  Process? overlay;

  /// Really quit: the window and the cursor buddy (Compii Core keeps running).
  Future<void> quit() async {
    overlay?.kill();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}

final appControl = AppControl();
