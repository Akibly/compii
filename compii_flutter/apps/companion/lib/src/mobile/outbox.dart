import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../console/core_client.dart';

/// What you asked, replied, shared or copied while the PC was out of reach.
/// Kept on the phone in order and sent the moment the PC is back; a request the
/// PC refuses outright is dropped rather than retried forever.
class Outbox extends ChangeNotifier {
  Outbox(this.core, {Future<void> Function(Map<String, dynamic> action)? send, this.max = 50})
      : _sendOverride = send;

  static const _key = 'phone_outbox';

  final CoreClient core;
  final int max;
  final Future<void> Function(Map<String, dynamic> action)? _sendOverride;

  final List<Map<String, dynamic>> pending = [];
  bool _ready = false;
  bool _flushing = false;
  bool _disposed = false;

  /// The last request that was dropped because the PC refused it.
  String? problem;

  int get count => pending.length;
  bool get busy => _flushing;

  Future<void> init() async {
    if (_ready) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null) {
        for (final item in jsonDecode(raw) as List) {
          if (item is Map) pending.add(Map<String, dynamic>.from(item));
        }
      }
    } on Object {
      // unreadable queue: start clean rather than fail
    }
    _ready = true;
    core.addListener(_onCore);
    if (core.status == CoreStatus.online) unawaited(flush());
    if (!_disposed) notifyListeners();
  }

  void _onCore() {
    if (core.status == CoreStatus.online && pending.isNotEmpty) unawaited(flush());
  }

  Future<int> ask(String text) => _add({'kind': 'ask', 'text': text});

  Future<int> reply(String taskId, String text) => _add({'kind': 'reply', 'task': taskId, 'text': text});

  Future<int> clipboard(String text) => _add({'kind': 'clipboard', 'text': text});

  Future<int> open(String url) => _add({'kind': 'url', 'url': url});

  Future<int> snippet(String name, String body) => _add({'kind': 'snippet', 'name': name, 'body': body});

  Future<int> _add(Map<String, Object?> action) async {
    while (pending.length >= max) {
      pending.removeAt(0);
    }
    pending.add({...action, 'at': DateTime.now().millisecondsSinceEpoch / 1000});
    problem = null;
    await _save();
    if (!_disposed) notifyListeners();
    if (core.status == CoreStatus.online) unawaited(flush());
    return pending.length;
  }

  /// Send everything waiting, oldest first. Stops at the first sign the PC is
  /// still unreachable; refused requests are removed with [problem] set.
  Future<void> flush() async {
    if (_flushing || !_ready || core.status != CoreStatus.online) return;
    _flushing = true;
    notifyListeners();
    try {
      while (pending.isNotEmpty && core.status == CoreStatus.online) {
        final action = pending.first;
        try {
          await (_sendOverride?.call(action) ?? _send(action));
        } on Object catch (e) {
          if (e is CoreError && e.offline) break;
          problem = 'A waiting ${_name(action)} couldn’t be sent: $e';
        }
        pending.removeAt(0);
        await _save();
        if (!_disposed) notifyListeners();
      }
    } finally {
      _flushing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _send(Map<String, dynamic> a) async {
    final kind = '${a['kind']}';
    if (kind == 'ask') {
      final text = '${a['text'] ?? ''}'.trim();
      if (text.isNotEmpty) await core.startConversation(text, followOn: true);
    } else if (kind == 'reply') {
      final text = '${a['text'] ?? ''}'.trim();
      if (text.isNotEmpty) await core.reply('${a['task']}', text);
    } else if (kind == 'clipboard') {
      await core.pushClipboard('${a['text'] ?? ''}');
    } else if (kind == 'url') {
      await core.openUrl('${a['url'] ?? ''}');
    } else if (kind == 'snippet') {
      await core.saveSnippet('${a['name'] ?? ''}', '${a['body'] ?? ''}');
    }
  }

  String _name(Map<String, dynamic> a) => switch ('${a['kind']}') {
        'ask' => 'question',
        'reply' => 'reply',
        'clipboard' => 'text copy',
        'url' => 'link',
        'snippet' => 'snippet',
        _ => 'request',
      };

  Future<void> _save() async {
    if (!_ready) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(pending));
    } on Object {
      // still queued in memory; it goes out this session
    }
  }

  /// A different PC is being paired: what was meant for the old one is stale.
  Future<void> clear() async {
    pending.clear();
    problem = null;
    await _save();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    core.removeListener(_onCore);
    super.dispose();
  }
}
