import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../console/core_client.dart';
import 'phone_bridge.dart';

/// Turns what Core is doing into phone-sized signals: a notification when an
/// answer is ready, an approval is needed or Compii is asking something while
/// the app is away, and a running headline in the home-screen widget.
class PhoneNotifier extends ChangeNotifier {
  PhoneNotifier(this.core, this.alerts);

  static const _askedKey = 'phone_alerts_asked';
  static const _enabledKey = 'phone_alerts';
  // Read by the native link too (FlutterSharedPreferences, "flutter." + key).
  static const _quietKey = 'phone_quiet';
  static const _quietFromKey = 'phone_quiet_from';
  static const _quietToKey = 'phone_quiet_to';

  final CoreClient core;
  final PhoneAlerts alerts;

  /// The app is on screen: no notifications, and the in-app banner says it all.
  bool foreground = true;

  bool permission = false;
  bool enabled = true;

  /// Quiet hours: only what needs you (an approval, a question) comes through.
  /// Minutes after midnight; the window may cross midnight (22:00 to 07:00).
  bool quiet = false;
  int quietFrom = 22 * 60;
  int quietTo = 7 * 60;

  bool isQuiet([DateTime? at]) {
    if (!quiet) return false;
    final t = at ?? DateTime.now();
    final m = t.hour * 60 + t.minute;
    return quietFrom <= quietTo ? m >= quietFrom && m < quietTo : m >= quietFrom || m < quietTo;
  }

  /// The phone's own link to the PC is running: it posts approvals, answers
  /// and briefs even with the app closed, so this notifier stops posting copies
  /// of them and keeps only the widget.
  bool linked = false;

  bool _started = false;
  bool _disposed = false;
  final Set<String> _postedWaiting = {};
  final Set<String> _doneTold = {};
  final Set<String> _updatesTold = {};
  StreamSubscription<Map<String, dynamic>>? _updates;
  String _lastWidget = '';

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_enabledKey) ?? true;
      quiet = p.getBool(_quietKey) ?? false;
      quietFrom = p.getInt(_quietFromKey) ?? quietFrom;
      quietTo = p.getInt(_quietToKey) ?? quietTo;
    } on Object {
      // defaults
    }
    permission = await alerts.notificationsAllowed();
    await _link();
    for (final t in core.ordered) {
      if (!t.active && t.finalText != null) _doneTold.add(_doneKey(t));
    }
    core.addListener(_check);
    _updates = core.updates.stream.listen(_onUpdate);
    _check();
    if (!_disposed) notifyListeners();
  }

  /// Ask for Android's notification permission once, after pairing.
  Future<void> askPermissionOnce() async {
    if (permission) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_askedKey) == true) return;
      await p.setBool(_askedKey, true);
    } on Object {
      // ask anyway
    }
    permission = await alerts.requestNotifications();
    await _link();
    if (!_disposed) notifyListeners();
  }

  /// Start (or stop) the background link to match: paired, alerts on, allowed.
  Future<void> _link() async {
    final remote = core.remote;
    if (enabled && permission && remote != null) {
      linked = await alerts.startLink(remote);
    } else if (linked) {
      await alerts.stopLink();
      linked = false;
    }
  }

  /// The phone was unpaired: nothing may keep talking to that PC.
  Future<void> unlink() async {
    await alerts.stopLink();
    linked = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    if (!on) {
      await alerts.cancelAll();
      _postedWaiting.clear();
    } else if (!permission) {
      permission = await alerts.requestNotifications();
      if (!permission) await alerts.openNotificationSettings();
    }
    await _link();
    try {
      await (await SharedPreferences.getInstance()).setBool(_enabledKey, on);
    } on Object {
      // applies this session
    }
    if (!_disposed) notifyListeners();
    _check();
  }

  Future<void> openSettings() => alerts.openNotificationSettings();

  Future<void> setQuiet({bool? on, int? from, int? to}) async {
    quiet = on ?? quiet;
    quietFrom = from ?? quietFrom;
    quietTo = to ?? quietTo;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_quietKey, quiet);
      await p.setInt(_quietFromKey, quietFrom);
      await p.setInt(_quietToKey, quietTo);
    } on Object {
      // applies this session
    }
    if (!_disposed) notifyListeners();
  }

  /// Called by the phone shell as the app moves in and out of view.
  void setForeground(bool value) {
    if (foreground == value) return;
    foreground = value;
    if (value) {
      unawaited(_clearWaiting());
    } else {
      _check();
    }
    notifyListeners();
  }

  Future<void> _clearWaiting() async {
    final tags = _postedWaiting.toList();
    _postedWaiting.clear();
    for (final tag in tags) {
      await alerts.cancel(tag);
    }
  }

  void _check() {
    if (!_disposed) _widget();
    if (!enabled || !permission) {
      unawaited(_clearWaiting());
      return;
    }
    final waiting = <String>{};
    for (final t in core.ordered) {
      final approval = t.pendingApproval;
      if (approval != null) {
        final key = 'ok:${t.id}:${approval['approval_id']}';
        waiting.add(key);
        if (!foreground && _postedWaiting.add(key)) {
          _post(
            key,
            'Compii needs your OK',
            '${approval['label'] ?? approval['tool'] ?? 'A step needs your approval'}',
            'task:${t.id}',
          );
        }
      }
      final question = t.pendingQuestion;
      if (question != null) {
        final key = 'ask:${t.id}:${question['question_id']}';
        waiting.add(key);
        if (!foreground && _postedWaiting.add(key)) {
          _post(key, 'Compii is asking you something', '${question['question'] ?? 'A question is waiting.'}', 'task:${t.id}');
        }
      }
      if (!t.active && t.finalText != null) {
        final key = _doneKey(t);
        if (_doneTold.add(key) && !foreground) {
          final failed = t.status == 'failed';
          _post(
            key,
            failed ? 'Compii couldn’t finish' : 'Compii finished',
            _tidy(t.finalText!),
            'task:${t.id}',
            needsYou: false,
          );
        }
      }
    }
    // An approval answered from the phone, or a task stopped: the alert is stale.
    for (final tag in _postedWaiting.where((x) => !waiting.contains(x)).toList()) {
      _postedWaiting.remove(tag);
      alerts.cancel(tag);
    }
  }

  void _onUpdate(Map<String, dynamic> e) {
    if (!enabled || !permission || foreground) return;
    final id = '${e['id'] ?? e['task_id'] ?? e['at'] ?? ''}';
    if (id.isEmpty || !_updatesTold.add(id)) return;
    final title = '${e['title'] ?? 'From Compii'}'.trim();
    final body = _tidy('${e['body'] ?? ''}');
    if (title.isEmpty && body.isEmpty) return;
    final task = '${e['task_id'] ?? ''}';
    _post(
      'update:$id',
      title.isEmpty ? 'From Compii' : title,
      body.isEmpty ? 'There’s something new on your PC.' : body,
      task.isEmpty ? 'chats' : 'task:$task',
      needsYou: false,
    );
  }

  void _post(String tag, String title, String body, String destination, {bool needsYou = true}) {
    if (linked) return; // the link posts these, with buttons, even when the app is gone
    if (!needsYou && isQuiet()) return; // it's in Chats in the morning
    unawaited(alerts.notify(tag: tag, title: title, body: body, destination: destination));
  }

  void _widget() {
    final tasks = core.ordered;
    final approvals = tasks.where((t) => t.pendingApproval != null).length;
    final questions = tasks.where((t) => t.pendingQuestion != null).length;
    final active = tasks.where((t) => t.active).length;
    final String headline;
    final String detail;
    final String meta;
    if (core.status != CoreStatus.online) {
      headline = 'Compii is out of reach';
      detail = core.remote == null ? 'Looking for your PC…' : 'Trying to reach ${core.remote!.pc}.';
      meta = 'Offline';
    } else if (approvals > 0) {
      final first = tasks.firstWhere((t) => t.pendingApproval != null).pendingApproval!;
      headline = '$approvals ${approvals == 1 ? 'thing needs' : 'things need'} your OK';
      detail = '${first['label'] ?? first['tool'] ?? 'A step needs approval'}';
      meta = 'Tap to review';
    } else if (questions > 0) {
      final first = tasks.firstWhere((t) => t.pendingQuestion != null).pendingQuestion!;
      headline = 'Compii is asking you something';
      detail = '${first['question'] ?? ''}';
      meta = 'Tap to answer';
    } else if (active > 0) {
      final first = tasks.firstWhere((t) => t.active);
      headline = 'Compii is working';
      detail = first.request;
      meta = active == 1 ? 'One conversation in progress' : '$active in progress';
    } else if (tasks.isEmpty) {
      headline = 'Compii is ready';
      detail = 'Ask anything from your phone.';
      meta = 'Tap to talk';
    } else {
      headline = 'Compii is ready';
      detail = tasks.first.request;
      meta = core.unread > 0 ? '${core.unread} new from Compii' : 'Tap to talk';
    }
    final signature = '$headline|$detail|$meta';
    if (signature == _lastWidget) return;
    _lastWidget = signature;
    alerts.widget(headline: headline, detail: detail, meta: meta);
  }

  String _doneKey(TaskView t) => 'done:${t.id}:${t.events.length}';

  @override
  void dispose() {
    _disposed = true;
    core.removeListener(_check);
    _updates?.cancel();
    super.dispose();
  }
}

String _tidy(String text) {
  var s = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ').replaceAll(RegExp(r'[*_`#>|]'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length <= 200) return s;
  final cut = s.lastIndexOf(' ', 180);
  return '${s.substring(0, cut < 80 ? 180 : cut).trimRight()}…';
}
