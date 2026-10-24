import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'island_geometry.dart';

/// The island's own small settings: where it sits, which shortcut wakes it and
/// how loudly it reports what it found.
abstract class IslandPrefs {
  Future<IslandLayout> layout();
  Future<void> saveLayout(IslandLayout layout);
  Future<String> shortcut();
  Future<void> saveShortcut(String id);
  Future<IslandAttention> attention();
  Future<void> saveAttention(IslandAttention policy);

  /// The one message the user asked to have sent later. On disk, so a restart
  /// of the pill does not throw their words away.
  Future<HeldReply?> held();
  Future<void> saveHeld(HeldReply? held);
}

/// What the pill is holding for the end of a turn: the words, the files that
/// came with them, and whether it was meant to look at the screen.
class HeldReply {
  const HeldReply({required this.text, this.files = const [], this.screen = false});

  final String text;
  final List<Map<String, dynamic>> files;
  final bool screen;

  Map<String, dynamic> toJson() => {'text': text, 'files': files, 'screen': screen};

  /// Nothing to send, or a record this build can't make sense of, is no message:
  /// a damaged store is skipped, not guessed at.
  static HeldReply? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'] is String ? raw['text'] as String : '';
    final screen = raw['screen'] == true;
    final files = (raw['files'] as List?)?.whereType<Map>().map((f) => f.cast<String, dynamic>()).toList() ?? [];
    if (text.trim().isEmpty && files.isEmpty && !screen) return null;
    return HeldReply(text: text, files: files, screen: screen);
  }
}

/// How much a background event is allowed to interrupt. The island never picks
/// one of these for you: it is the one thing in §1 of the brief that has to be
/// the user's call, because "tell me" and "don't touch my screen" are both
/// reasonable answers to the same event.
enum IslandAttention {
  /// Nothing moves. The state is still there when you open the island.
  silent,

  /// The capsule's mark and word change. Nothing is added to the screen.
  indicator,

  /// The mark, plus one Windows notification per event.
  toast,

  /// The mark, plus the card for that thread opens by itself.
  expanded;

  static const defaultPolicy = IslandAttention.toast;

  /// The menu offers one row that walks the list: four words to read is a lot
  /// to put on a pill.
  IslandAttention get next =>
      IslandAttention.values[(index + 1) % IslandAttention.values.length];

  static IslandAttention fromId(Object? raw) {
    for (final p in IslandAttention.values) {
      if (p.name == raw) return p;
    }
    return defaultPolicy;
  }

  String get label => switch (this) {
        IslandAttention.silent => 'Stay quiet',
        IslandAttention.indicator => 'Just the mark',
        IslandAttention.toast => 'Mark and a notification',
        IslandAttention.expanded => 'Show me the card',
      };

  String get hint => switch (this) {
        IslandAttention.silent => 'Nothing moves on its own. Open the island to see it.',
        IslandAttention.indicator => 'The pill changes colour and word, that is all.',
        IslandAttention.toast => 'One Windows notification when Compii needs you or finishes.',
        IslandAttention.expanded => 'The card opens by itself, except while you are typing or a full-screen app has the screen.',
      };
}

class SharedIslandPrefs implements IslandPrefs {
  static const _layoutKey = 'island_layout';
  static const _shortcutKey = 'island_shortcut';

  /// The one place this key is spelled: the pill writes it, and the main window
  /// reads it to keep its notifications out of a desktop the user asked to be left
  /// alone — even though the pill, not the window, is where the choice was made.
  static const attentionKey = 'island_attention';

  /// The message waiting to go. Only the pill writes it, and only while the
  /// user has something they asked to have sent after the running turn.
  static const _heldKey = 'island_held';

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } on Object {
      return null;
    }
  }

  @override
  Future<IslandLayout> layout() async {
    final prefs = await _prefs();
    final raw = prefs?.getString(_layoutKey);
    if (raw == null) return IslandLayout.topCenter;
    try {
      return IslandLayout.fromJson(jsonDecode(raw));
    } on FormatException {
      return IslandLayout.topCenter;
    }
  }

  @override
  Future<void> saveLayout(IslandLayout layout) async {
    final prefs = await _prefs();
    await prefs?.setString(_layoutKey, jsonEncode(layout.toJson()));
  }

  @override
  Future<String> shortcut() async => (await _prefs())?.getString(_shortcutKey) ?? IslandShortcuts.defaultId;

  @override
  Future<void> saveShortcut(String id) async {
    final prefs = await _prefs();
    await prefs?.setString(_shortcutKey, id);
  }

  @override
  Future<IslandAttention> attention() async =>
      IslandAttention.fromId((await _prefs())?.getString(attentionKey));

  @override
  Future<void> saveAttention(IslandAttention policy) async {
    final prefs = await _prefs();
    await prefs?.setString(attentionKey, policy.name);
  }

  @override
  Future<HeldReply?> held() async {
    final raw = (await _prefs())?.getString(_heldKey);
    if (raw == null) return null;
    try {
      return HeldReply.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveHeld(HeldReply? held) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    if (held == null) {
      await prefs.remove(_heldKey);
      return;
    }
    await prefs.setString(_heldKey, jsonEncode(held.toJson()));
  }
}

/// For tests and for previews where no storage is available.
class MemoryIslandPrefs implements IslandPrefs {
  MemoryIslandPrefs({
    this.initialLayout = IslandLayout.topCenter,
    this.initialShortcut = IslandShortcuts.defaultId,
    this.initialAttention = IslandAttention.defaultPolicy,
    this.heldReply,
  });

  IslandLayout initialLayout;
  String initialShortcut;
  IslandAttention initialAttention;
  HeldReply? heldReply;

  @override
  Future<IslandLayout> layout() async => initialLayout;

  @override
  Future<void> saveLayout(IslandLayout layout) async => initialLayout = layout;

  @override
  Future<String> shortcut() async => initialShortcut;

  @override
  Future<void> saveShortcut(String id) async => initialShortcut = id;

  @override
  Future<IslandAttention> attention() async => initialAttention;

  @override
  Future<void> saveAttention(IslandAttention policy) async => initialAttention = policy;

  @override
  Future<HeldReply?> held() async => heldReply;

  @override
  Future<void> saveHeld(HeldReply? held) async => heldReply = held;
}

/// How loudly a background event may interrupt, as chosen on this desktop. Read
/// from disk, not from this process's cache: the pill is a separate process and is
/// usually the one that wrote it.
Future<IslandAttention> desktopAttention() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return IslandAttention.fromId(prefs.getString(SharedIslandPrefs.attentionKey));
  } on Object {
    return IslandAttention.defaultPolicy;
  }
}

/// The shortcuts the island can be woken with. Kept separate from
/// hotkey_manager so this file stays usable without a platform plugin.
class IslandShortcuts {
  static const defaultId = 'ctrl_alt_space';
  static const ids = ['ctrl_alt_space', 'ctrl_alt_i', 'f8'];

  static String label(String id) => switch (id) {
        'ctrl_alt_i' => 'Ctrl + Alt + I',
        'f8' => 'F8',
        _ => 'Ctrl + Alt + Space',
      };

  static String normalize(String id) => ids.contains(id) ? id : defaultId;
}
