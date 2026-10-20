import 'dart:io';

import 'package:flutter/foundation.dart';

/// The app's own crash log: ~/Compii/app.log (kept small). Compii Core adds it to the
/// diagnostic report you can save from Settings; nothing is sent anywhere.
class CrashLog {
  static File? _file;

  static File get file {
    final home = Platform.environment['COMPII_HOME'] ??
        '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.'}${Platform.pathSeparator}Compii';
    return _file ??= File('$home${Platform.pathSeparator}app.log');
  }

  /// Catch every error the app doesn't handle, keep the app running, and write it down.
  static void install({String role = 'app'}) {
    try {
      final f = file;
      f.parent.createSync(recursive: true);
      if (f.existsSync() && f.lengthSync() > 1500000) f.writeAsStringSync(''); // start fresh past ~1.5 MB
      write('--- Compii $role started ${DateTime.now().toIso8601String()} on ${Platform.operatingSystemVersion}');
    } on Object {
      return; // logging must never stop Compii
    }
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      write('Flutter error: ${details.exceptionAsString()}\n${details.stack ?? ''}');
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      write('Uncaught: $error\n$stack');
      return true; // handled: keep running
    };
  }

  static void write(String text) {
    try {
      file.writeAsStringSync('${DateTime.now().toIso8601String()} $text\n', mode: FileMode.append, flush: true);
    } on Object {
      // ignore
    }
  }
}
