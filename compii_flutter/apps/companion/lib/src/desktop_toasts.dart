import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'console/core_client.dart';

const _channel = MethodChannel('compii/overlay');

/// A real Windows toast in the notification centre. Other platforms and tests
/// have no native side, so this quietly does nothing there.
Future<void> showToast(String title, String body) async {
  try {
    await _channel.invokeMethod<void>('toast', {'title': title, 'body': body});
  } on Object catch (e) {
    debugPrint('Toast not shown: $e');
  }
}

/// Tells you quietly in Windows when work finishes or Compii needs you while
/// you are in another app. The cursor buddy already speaks up when you are
/// right there, so this only fires in the background.
class DesktopToasts {
  DesktopToasts(
    this.core, {
    required this.inBackground,
    Future<void> Function(String title, String body) send = showToast,
  }) : _send = send {
    _sub = core.taskEvents.stream.listen(_onEvent);
  }

  final CoreClient core;

  /// True when Compii is not the window you are using (hidden, minimised,
  /// behind another app) and the quick bar isn't open.
  final bool Function() inBackground;

  final Future<void> Function(String title, String body) _send;
  StreamSubscription<Map<String, dynamic>>? _sub;

  void dispose() => _sub?.cancel();

  void _onEvent(Map<String, dynamic> e) {
    if (!inBackground()) return;
    final task = core.tasks[e['task_id']];
    final bot = core.botFor(task?.botId)?.name ?? 'Compii';
    switch (e['type']) {
      case 'task_finished':
        final status = '${e['status'] ?? ''}';
        if (status != 'done' && status != 'failed') return; // stopped by you: no toast
        final said = _short('${e['text'] ?? ''}');
        _send(
          status == 'failed' ? '$bot ran into a problem' : '$bot finished',
          said.isEmpty ? _short(task?.request ?? '') : said,
        );
      case 'approval_needed':
        _send('$bot needs your OK', _short('${e['label'] ?? ''}'));
      case 'question':
        _send('$bot has a question', _short('${e['question'] ?? ''}'));
      case 'takeover':
        _send('Your turn — $bot', _short('${e['what'] ?? ''}'));
    }
  }

  static String _short(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 140 ? one : '${one.substring(0, 139)}…';
  }
}
