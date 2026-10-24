import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'console/core_client.dart';
import 'island/island_prefs.dart';

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

/// True when an island process is running. The island owns telling you about
/// background events - the policy is on the pill, not in this window - so the
/// main window keeps quiet rather than sending the same news twice.
Future<bool> islandIsAlive() async {
  try {
    return await _channel.invokeMethod<bool>('islandAlive') ?? false;
  } on Object {
    return false; // no native side, or a runner that predates the island
  }
}

/// Tells you quietly in Windows when work finishes, Compii needs you, or it left
/// something in the inbox while you are in another app. The cursor buddy already
/// speaks up when you are right there, and the island owns the choice of how loud
/// to be — so this path fires only in the background, only when no island is
/// running to say it its own way, and never at all once you asked for quiet.
class DesktopToasts {
  DesktopToasts(
    this.core, {
    required this.inBackground,
    Future<void> Function(String title, String body) send = showToast,
    Future<bool> Function() alive = islandIsAlive,
    Future<IslandAttention> Function() policy = desktopAttention,
  }) : _send = send,
       _alive = alive,
       _policy = policy {
    _sub = core.taskEvents.stream.listen(_onEvent);
    _inbox = core.updates.stream.listen(_onInbox);
  }

  final CoreClient core;

  /// True when Compii is not the window you are using (hidden, minimised,
  /// behind another app) and the quick bar isn't open.
  final bool Function() inBackground;

  final Future<void> Function(String title, String body) _send;
  final Future<bool> Function() _alive;
  final Future<IslandAttention> Function() _policy;
  StreamSubscription<Map<String, dynamic>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _inbox;

  void dispose() {
    _sub?.cancel();
    _inbox?.cancel();
  }

  /// The two questions every notice has to pass on this PC, in the order that
  /// matters: the user's own "stay quiet" outranks everything, and a pill that is
  /// running already applies that choice better than a bell can.
  Future<bool> _mayTell() async {
    if (await _policy() == IslandAttention.silent) return false;
    return !await _alive();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!inBackground()) return;
    unawaited(_tell(e));
  }

  /// The daily brief, a folder watch, a journal day: news with no conversation of
  /// its own. The island marks these on the pill; when there is no island, this is
  /// the only way this PC says them at all.
  void _onInbox(Map<String, dynamic> e) {
    if (!inBackground()) return;
    unawaited(_tellInbox(e));
  }

  Future<void> _tellInbox(Map<String, dynamic> e) async {
    // A routine or a watch that ran as a conversation has already been told by the
    // thread itself; the inbox copy is the same news in a second voice.
    if (core.hasThreadFor(e)) return;
    if (!await _mayTell()) return;
    final title = _short('${e['title'] ?? ''}');
    final body = _short('${e['body'] ?? ''}');
    if (title.isEmpty && body.isEmpty) return;
    await _send(title.isEmpty ? 'From Compii' : title, body);
  }

  Future<void> _tell(Map<String, dynamic> e) async {
    if (!await _mayTell()) return;
    final task = core.tasks[e['task_id']];
    final bot = core.botFor(task?.botId)?.name ?? 'Compii';
    switch (e['type']) {
      case 'task_finished':
        final status = '${e['status'] ?? ''}';
        if (status != 'done' && status != 'failed') return; // stopped by you: no toast
        final said = _short('${e['text'] ?? ''}');
        await _send(
          status == 'failed' ? '$bot ran into a problem' : '$bot finished',
          said.isEmpty ? _short(task?.request ?? '') : said,
        );
      case 'approval_needed':
        await _send('$bot needs your OK', _short('${e['label'] ?? ''}'));
      case 'question':
        await _send('$bot has a question', _short('${e['question'] ?? ''}'));
      case 'takeover':
        await _send('Your turn — $bot', _short('${e['what'] ?? ''}'));
    }
  }

  static String _short(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 140 ? one : '${one.substring(0, 139)}…';
  }
}
