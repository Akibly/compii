import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What Android lets Compii do on this phone, and whether the user has turned
/// it on in Android settings.
@immutable
class PhoneAccess {
  const PhoneAccess({
    this.screen = false,
    this.screenReady = false,
    this.notifications = false,
    this.notificationsReady = false,
  });

  final bool screen;
  final bool screenReady;
  final bool notifications;
  final bool notificationsReady;

  bool get any => screen || notifications;

  factory PhoneAccess.from(Map<String, dynamic> raw) => PhoneAccess(
        screen: raw['screen'] == true,
        screenReady: raw['screenReady'] == true,
        notifications: raw['notifications'] == true,
        notificationsReady: raw['notificationsReady'] == true,
      );
}

/// The phone's own hands: its screen, apps and notifications. Every call is a
/// single request from the user; nothing watches or acts on its own.
abstract interface class PhoneControls {
  /// Live notifications as they arrive (and anything the automation sheet shows).
  Stream<Map<String, dynamic>> get events;
  Future<PhoneAccess> status();
  Future<Map<String, dynamic>?> screen();
  Future<bool> tap(String text);
  Future<bool> type(String text);
  Future<bool> scroll(String direction);
  Future<bool> global(String action);
  Future<String?> openApp(String query);
  Future<List<Map<String, dynamic>>> notifications();
  Future<void> openAccessibilitySettings();
  Future<void> openListenerSettings();
}

/// The real Android side. Everywhere else every call is a quiet no-op, so the
/// same UI runs on Windows for testing.
class AutomationBridge implements PhoneControls {
  AutomationBridge._();
  static final AutomationBridge instance = AutomationBridge._();

  static const _methods = MethodChannel('compii/automation');
  static const _events = EventChannel('compii/automation_events');

  bool get _here => Platform.isAndroid;

  Stream<Map<String, dynamic>>? _stream;

  @override
  Stream<Map<String, dynamic>> get events => _stream ??= _here
      ? _events.receiveBroadcastStream().map((e) {
          try {
            return e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{};
          } on Object {
            return <String, dynamic>{};
          }
        }).where((e) => e.isNotEmpty)
      : const Stream.empty();

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    if (!_here) return null;
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<PhoneAccess> status() async {
    final raw = await _call<Map<dynamic, dynamic>>('status');
    return raw == null ? const PhoneAccess() : PhoneAccess.from(Map<String, dynamic>.from(raw));
  }

  @override
  Future<Map<String, dynamic>?> screen() async {
    final raw = await _call<Map<dynamic, dynamic>>('screen');
    return raw == null ? null : Map<String, dynamic>.from(raw);
  }

  @override
  Future<bool> tap(String text) async => await _call<bool>('tap', {'text': text}) ?? false;

  @override
  Future<bool> type(String text) async => await _call<bool>('type', {'text': text}) ?? false;

  @override
  Future<bool> scroll(String direction) async => await _call<bool>('scroll', {'direction': direction}) ?? false;

  @override
  Future<bool> global(String action) async => await _call<bool>('global', {'action': action}) ?? false;

  @override
  Future<String?> openApp(String query) => _call<String>('openApp', {'query': query});

  @override
  Future<List<Map<String, dynamic>>> notifications() async {
    final raw = await _call<List<dynamic>>('notifications');
    return [
      for (final item in raw ?? const <dynamic>[])
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  @override
  Future<void> openAccessibilitySettings() => _call('openAccessibilitySettings');

  @override
  Future<void> openListenerSettings() => _call('openListenerSettings');
}

/// A standing instruction: when a notification like this arrives, ask Compii
/// on the PC about it. Rules only run while the app is alive on this phone.
@immutable
class WatchRule {
  const WatchRule({
    required this.id,
    this.app = '',
    this.contains = '',
    required this.prompt,
    this.enabled = true,
  });

  final String id;
  final String app;
  final String contains;
  final String prompt;
  final bool enabled;

  String get title => app.trim().isEmpty ? 'Any app' : 'From ${app.trim()}';

  String get detail => contains.trim().isEmpty
      ? 'Every notification'
      : 'Containing “${contains.trim()}”';

  bool matches(Map<String, dynamic> note) {
    if (!enabled) return false;
    final appNeedle = app.trim().toLowerCase();
    final containsNeedle = contains.trim().toLowerCase();
    if (appNeedle.isEmpty && containsNeedle.isEmpty) return false;
    final from = '${note['app'] ?? ''} ${note['package'] ?? ''}'.toLowerCase();
    final words = '${note['title'] ?? ''} ${note['text'] ?? ''}'.toLowerCase();
    if (appNeedle.isNotEmpty && !from.contains(appNeedle)) return false;
    if (containsNeedle.isNotEmpty && !'$from $words'.contains(containsNeedle)) return false;
    return true;
  }

  WatchRule copyWith({String? app, String? contains, String? prompt, bool? enabled}) => WatchRule(
        id: id,
        app: app ?? this.app,
        contains: contains ?? this.contains,
        prompt: prompt ?? this.prompt,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'app': app,
        'contains': contains,
        'prompt': prompt,
        'enabled': enabled,
      };

  factory WatchRule.fromJson(Map<String, dynamic> json) => WatchRule(
        id: '${json['id'] ?? ''}',
        app: '${json['app'] ?? ''}',
        contains: '${json['contains'] ?? ''}',
        prompt: '${json['prompt'] ?? ''}',
        enabled: json['enabled'] != false,
      );
}

/// Watches the phone's notification stream and turns matching ones into PC
/// requests. One rule fires at most once a minute, so a busy chat can't flood
/// the PC; rules with neither an app nor a phrase never match.
class AutomationRules extends ChangeNotifier {
  AutomationRules(this.controls, {required this.onFire, this.cooldown = const Duration(minutes: 1)});

  static const _key = 'phone_watch_rules';
  static const _pausedKey = 'phone_watch_paused';

  final PhoneControls controls;
  final Future<void> Function(WatchRule rule, Map<String, dynamic> note) onFire;
  final Duration cooldown;

  final List<WatchRule> _rules = [];
  final Map<String, DateTime> _last = {};
  StreamSubscription<Map<String, dynamic>>? _events;
  bool paused = false;
  bool _ready = false;
  bool _disposed = false;

  List<WatchRule> get rules => List.unmodifiable(_rules);

  Future<void> start() async {
    if (_ready) return;
    try {
      final p = await SharedPreferences.getInstance();
      paused = p.getBool(_pausedKey) ?? false;
      final raw = p.getString(_key);
      if (raw != null) {
        for (final item in jsonDecode(raw) as List) {
          if (item is Map) _rules.add(WatchRule.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    } on Object {
      // unreadable rules: start with none rather than fail
    }
    _ready = true;
    if (_disposed) return;
    _events = controls.events.where((e) => e['type'] == 'notification').listen(_note);
    notifyListeners();
  }

  Future<void> _note(Map<String, dynamic> note) async {
    if (paused || _rules.isEmpty) return;
    final now = DateTime.now();
    for (final rule in _rules) {
      if (!rule.matches(note)) continue;
      final last = _last[rule.id];
      if (last != null && now.difference(last) < cooldown) continue;
      _last[rule.id] = now;
      try {
        await onFire(rule, note);
      } on Object {
        // one broken rule never stops the next
      }
    }
  }

  Future<void> add(WatchRule rule) async {
    _rules.add(rule);
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> update(WatchRule rule) async {
    final i = _rules.indexWhere((r) => r.id == rule.id);
    if (i < 0) return;
    _rules[i] = rule;
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> remove(String id) async {
    _rules.removeWhere((r) => r.id == id);
    _last.remove(id);
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> setPaused(bool value) async {
    paused = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(_pausedKey, value);
    } on Object {
      // applies this session
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _save() async {
    if (!_ready) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode([for (final r in _rules) r.toJson()]));
    } on Object {
      // still applies this session
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    super.dispose();
  }
}

/// Everything the "On this phone" sheet shows and does: access state, screen
/// actions, and the rules. Actions that happen on a screen other than Compii
/// wait a few seconds so the user can switch to the app they mean.
class PhoneAutomation extends ChangeNotifier {
  PhoneAutomation(
    this.controls, {
    required this.send,
    required this.say,
    this.switchTime = const Duration(seconds: 6),
  }) {
    rules = AutomationRules(controls, onFire: _fire);
  }

  final PhoneControls controls;
  final Future<void> Function(String text) send;
  final void Function(String message) say;
  final Duration switchTime;

  late final AutomationRules rules;
  PhoneAccess access = const PhoneAccess();
  Map<String, dynamic>? lastScreen;
  List<Map<String, dynamic>> recent = const [];
  String? lastResult;
  bool busy = false;
  bool _disposed = false;

  Future<void> start() async {
    await rules.start();
    await refresh();
  }

  Future<void> refresh() async {
    access = await controls.status();
    if (!_disposed) notifyListeners();
  }

  /// The labels from the last look, without duplicates and tiny fragments.
  List<String> get seenLabels {
    final seen = <String>{};
    final labels = <String>[];
    final elements = lastScreen?['elements'];
    if (elements is! List) return labels;
    for (final e in elements) {
      if (e is! Map) continue;
      final text = '${e['text'] ?? ''}'.trim();
      if (text.isEmpty || text.length > 80) continue;
      if (seen.add(text.toLowerCase())) labels.add(text);
      if (labels.length >= 40) break;
    }
    return labels;
  }

  Future<void> look() => _run(() async {
        final snap = await controls.screen();
        if (snap == null) {
          return 'I can’t see the screen right now. Turn on screen access, then try again.';
        }
        if ('${snap['package']}' == 'app.compii.compii') {
          return 'That was Compii itself. Open the app you want me to read, then look again.';
        }
        lastScreen = snap;
        final app = '${snap['app'] ?? ''}'.trim();
        final name = app.isEmpty ? 'this app' : app;
        final title = '${snap['title'] ?? ''}'.trim();
        final count = (snap['elements'] as List?)?.length ?? 0;
        if (count == 0) {
          return 'I looked at $name, but found no readable text. Apps that draw their own screen hide it.';
        }
        return 'I saw $name${title.isEmpty ? '' : ' ($title)'} — $count things on screen.';
      }, wait: true);

  Future<void> tap(String text) => _run(() async {
        final ok = await controls.tap(text);
        return ok ? 'Tapped “$text”.' : 'I couldn’t find “$text” on that screen.';
      }, wait: true);

  Future<void> type(String text) => _run(() async {
        final ok = await controls.type(text);
        return ok ? 'Typed it.' : 'There was no text field I could safely type into.';
      }, wait: true);

  Future<void> scroll(String direction) => _run(() async {
        final ok = await controls.scroll(direction);
        return ok ? 'Scrolled $direction.' : 'Nothing on that screen scrolls.';
      }, wait: true);

  /// Home, back, recents and the notification shade act on the phone itself,
  /// so they happen at once rather than after a switch.
  Future<void> global(String action) => _run(() async {
        final ok = await controls.global(action);
        if (!ok) return 'That didn’t work on this screen.';
        return switch (action) {
          'home' => 'Went home.',
          'back' => 'Went back.',
          'recents' => 'Opened recently used apps.',
          'notifications' => 'Opened your notifications.',
          _ => 'Done.',
        };
      });

  Future<void> openApp(String query) async {
    busy = true;
    if (!_disposed) notifyListeners();
    try {
      final label = await controls.openApp(query);
      _finish(label == null ? 'I couldn’t find an app called “$query”.' : 'Opened $label.');
    } finally {
      busy = false;
    }
  }

  Future<void> loadNotifications() async {
    recent = await controls.notifications();
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<String> Function() act, {bool wait = false}) async {
    busy = true;
    if (!_disposed) notifyListeners();
    try {
      if (wait) await Future<void>.delayed(switchTime);
      final said = await act();
      _finish(said);
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _finish(String message) {
    lastResult = message;
    if (!_disposed) notifyListeners();
    say(message);
  }

  Future<void> _fire(WatchRule rule, Map<String, dynamic> note) async {
    final app = '${note['app'] ?? 'an app'}'.trim();
    final title = '${note['title'] ?? ''}'.trim();
    final text = '${note['text'] ?? ''}'.trim();
    final said = [title, text].where((e) => e.isNotEmpty).join(' — ');
    final ask = rule.prompt.trim().isEmpty ? 'Look at this and tell me what I should do.' : rule.prompt.trim();
    await send('$ask\n\nA notification just arrived on my phone from $app: “$said”. '
        'This is about my phone, not my PC.');
  }

  Future<void> addRule(WatchRule rule) => rules.add(rule);

  Future<void> removeRule(String id) => rules.remove(id);

  Future<void> updateRule(WatchRule rule) => rules.update(rule);

  Future<void> setPaused(bool value) => rules.setPaused(value);

  @override
  void dispose() {
    _disposed = true;
    rules.dispose();
    super.dispose();
  }
}
