import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../console/character.dart' show followCompiiLook;
import '../console/core_client.dart';
import '../diagnostics.dart';
import '../ui/tokens.dart';
import '../ui/voice.dart';
import 'island_actions.dart';
import 'island_controller.dart';
import 'island_geometry.dart';
import 'island_platform.dart';
import 'island_prefs.dart';
import 'island_ui.dart';

/// The island runs as its own copy of Compii with a transparent, always-on-top
/// window (windows/runner/main.cpp creates it). It never resizes: the card is
/// drawn inside a much larger surface and only the card catches the mouse.
Future<void> runIsland() async {
  WidgetsFlutterBinding.ensureInitialized();
  CrashLog.install(role: 'island');
  const platform = NativeIslandPlatform();
  if (!await platform.claim()) exit(0); // one island per desktop
  await windowManager.ensureInitialized();
  // The native window itself is transparent; this only tells the engine what
  // to clear to, so the desktop shows through around the card.
  await windowManager.setBackgroundColor(Colors.transparent);
  final prefs = SharedIslandPrefs();
  final layout = await prefs.layout();
  final shortcut = await prefs.shortcut();
  final core = CoreClient()..start();
  final voice = VoiceController(core);
  final themeMode = await _themeMode();
  followCompiiLook();
  runApp(
    IslandApp(
      core: core,
      voice: voice,
      platform: platform,
      prefs: prefs,
      layout: layout,
      shortcut: shortcut,
      themeMode: themeMode,
    ),
  );
}

Future<ThemeMode> _themeMode() async {
  try {
    final p = await SharedPreferences.getInstance();
    return ThemeMode.values.byName(p.getString('theme') ?? 'system');
  } on Object {
    return ThemeMode.system;
  }
}

class IslandApp extends StatelessWidget {
  const IslandApp({
    super.key,
    required this.core,
    required this.voice,
    required this.platform,
    required this.prefs,
    required this.layout,
    required this.shortcut,
    required this.themeMode,
  });

  final CoreClient core;
  final VoiceController voice;
  final IslandPlatform platform;
  final IslandPrefs prefs;
  final IslandLayout layout;
  final String shortcut;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Compii island',
    color: Colors.transparent,
    theme: compiiTheme(Brightness.light),
    darkTheme: compiiTheme(Brightness.dark),
    themeMode: themeMode,
    home: IslandHost(
      core: core,
      voice: voice,
      platform: platform,
      prefs: prefs,
      layout: layout,
      shortcut: shortcut,
    ),
  );
}

/// Owns what the widgets cannot: where the window is, whether the mouse is
/// over the card, and the wake shortcut.
class IslandHost extends StatefulWidget {
  const IslandHost({
    super.key,
    required this.core,
    required this.voice,
    required this.platform,
    required this.prefs,
    required this.layout,
    required this.shortcut,
  });

  final CoreClient core;
  final VoiceController voice;
  final IslandPlatform platform;
  final IslandPrefs prefs;
  final IslandLayout layout;
  final String shortcut;

  @override
  State<IslandHost> createState() => _IslandHostState();
}

class _IslandHostState extends State<IslandHost> {
  static const _metrics = IslandMetrics();
  final _geometry = const IslandGeometry(_metrics);
  final _cardKey = GlobalKey(debugLabel: 'island-card');

  late IslandController _controller;
  late IslandLayout _layout;
  late String _shortcut;
  String? _hotkeyError;
  HotKey? _hotkey;

  /// Last window rect we placed ourselves (physical virtual-desktop pixels).
  Rect? _window;
  IslandDisplay? _display;
  double _dpr = 1;

  Timer? _hover;
  Timer? _displays;
  Timer? _foreground;
  bool _clickThrough = true;
  DateTime _appliedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dragging = false;
  bool _moving = false;
  Offset? _dragFromCursor;
  Offset? _dragFromWindow;
  double _cardWidth = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _layout = widget.layout;
    _shortcut = IslandShortcuts.normalize(widget.shortcut);
    _controller = IslandController(
      core: widget.core,
      actions: CoreIslandActions(widget.core, widget.platform),
      platform: widget.platform,
      voice: widget.voice,
      prefs: widget.prefs,
    )..addListener(_stateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dpr = MediaQuery.devicePixelRatioOf(context);
  }

  void _stateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_started || !mounted) return;
    _started = true;
    _controller.setAttention(await widget.prefs.attention());
    // A message you had asked to send after the running turn is still yours to send.
    await _controller.restoreHeld();
    _window = await widget.platform.windowBounds();
    await _place();
    await _controller.rememberForeground();
    await _registerHotkey();
    _pollHover();
    _displays = Timer.periodic(const Duration(seconds: 3), (_) => _syncDisplays());
    _foreground = Timer.periodic(const Duration(seconds: 2), (_) => _controller.rememberForeground());
  }

  @override
  void dispose() {
    _hover?.cancel();
    _displays?.cancel();
    _foreground?.cancel();
    _controller.removeListener(_stateChanged);
    _controller.dispose();
    if (_hotkey != null) {
      unawaited(hotKeyManager.unregister(_hotkey!).catchError((_) {}));
    }
    super.dispose();
  }

  // ---- the window ----

  Future<void> _place() async {
    var window = _window;
    if (window == null) {
      window = await widget.platform.windowBounds();
      if (window == null) return;
      _window = window;
    }
    final displays = await widget.platform.displays();
    if (displays.isEmpty) return;
    final display = _geometry.displayFor(displays, _layout);
    _display = display;
    if (_layout.display != display.name) {
      _layout = _layout.copyWith(display: display.name);
      await widget.prefs.saveLayout(_layout);
    }
    final at = _geometry.windowFor(display: display, layout: _layout, windowPhysical: window.size);
    _window = Rect.fromLTWH(at.dx, at.dy, window.width, window.height);
    await widget.platform.moveTo(at);
  }

  /// A monitor was unplugged, the dock moved, the resolution changed or the
  /// scale changed: put the same card back inside the new work area.
  Future<void> _syncDisplays() async {
    if (_dragging || _window == null) return;
    final displays = await widget.platform.displays();
    if (displays.isEmpty || !mounted) return;
    final current = _display;
    IslandDisplay? match;
    if (current != null) {
      for (final d in displays) {
        if (d.name == current.name) {
          match = d;
          break;
        }
      }
    }
    if (current == null || match == null || match.work != current.work || match.scale != current.scale) {
      await _place();
    }
  }

  Future<void> _dragStart() async {
    _dragging = true;
    _dragFromCursor = await widget.platform.cursor();
    _dragFromWindow = _window?.topLeft;
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    _cardWidth = box != null && box.hasSize ? box.size.width * _dpr : 0;
  }

  Future<void> _dragUpdate() async {
    if (!_dragging || _moving) return;
    final from = _dragFromCursor;
    final window = _window;
    if (from == null || window == null) return;
    _moving = true;
    try {
      final cursor = await widget.platform.cursor();
      if (cursor == null) return;
      final at = _dragFromWindow! + (cursor - from);
      _window = Rect.fromLTWH(at.dx, at.dy, window.width, window.height);
      await widget.platform.moveTo(at);
    } finally {
      _moving = false;
    }
  }

  Future<void> _dragEnd() async {
    if (!_dragging) return;
    _dragging = false;
    _dragFromCursor = null;
    _dragFromWindow = null;
    final window = _window;
    if (window == null) return;
    final displays = await widget.platform.displays();
    if (displays.isEmpty) return;
    final cursor = await widget.platform.cursor();
    final display = _geometry.nearest(displays, cursor ?? window.center) ?? _geometry.displayFor(displays, _layout);
    _display = display;
    final cardWidth = _cardWidth > 0 ? _cardWidth : _metrics.maxCardWidth * display.scale;
    _layout = _geometry.layoutFor(
      display: display,
      windowTopLeft: window.topLeft,
      windowPhysical: window.size,
      cardWidthPhysical: cardWidth,
    );
    await widget.prefs.saveLayout(_layout);
    // layoutFor keeps the card inside the work area; place again so a drag
    // that ended half off-screen lands where the saved fraction says.
    await _place();
  }

  Future<void> _dock(IslandDock dock) async {
    final display = _display;
    if (display != null) _layout = _geometry.dock(dock, display.name);
    await widget.prefs.saveLayout(_layout);
    await _place();
  }

  Future<void> _resetLayout() async {
    final displays = await widget.platform.displays();
    IslandDisplay? primary;
    for (final d in displays) {
      if (d.primary) {
        primary = d;
        break;
      }
    }
    _layout = IslandLayout(
      display: primary?.name ?? _layout.display,
      x: .5,
      y: 0,
    );
    await widget.prefs.saveLayout(_layout);
    await _place();
  }

  // ---- mouse pass-through ----

  /// Polls the cursor while the island is small; while it is open the pointer
  /// stops inside it more often, so it answers sooner. Only the card catches
  /// the mouse — the transparent margin always belongs to the app behind.
  void _pollHover() {
    if (!mounted) return;
    _hover = Timer(Duration(milliseconds: _controller.isOpen ? 16 : 40), () {
      unawaited(_trackHover().catchError((Object _) {}).whenComplete(_pollHover));
    });
  }

  Future<void> _trackHover() async {
    if (!mounted || _dragging || _window == null) return;
    final cursor = await widget.platform.cursor();
    if (cursor == null) return;
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = (cursor - _window!.topLeft) / _dpr;
    final over = (box.localToGlobal(Offset.zero) & box.size).contains(local);
    final through = !over;
    final stale = DateTime.now().difference(_appliedAt) > const Duration(seconds: 2);
    if (through != _clickThrough || stale) {
      _clickThrough = through;
      _appliedAt = DateTime.now();
      await widget.platform.clickThrough(through);
    }
  }

  // ---- shortcut ----

  Future<void> _setShortcut(String id) async {
    _shortcut = IslandShortcuts.normalize(id);
    await widget.prefs.saveShortcut(_shortcut);
    await _registerHotkey();
    if (mounted) setState(() {});
  }

  /// How loudly a background event may interrupt, kept in the same store as
  /// where the island sits.
  Future<void> _setAttention(IslandAttention policy) async {
    _controller.setAttention(policy);
    await widget.prefs.saveAttention(policy);
  }

  Future<void> _registerHotkey() async {
    if (!Platform.isWindows) return;
    final old = _hotkey;
    _hotkey = null;
    if (old != null) {
      try {
        await hotKeyManager.unregister(old);
      } on Object {
        // Windows may already have dropped it (session change); registering
        // the new one is what matters.
      }
    }
    final hotKey = HotKey(
      key: switch (_shortcut) {
        'ctrl_alt_i' => PhysicalKeyboardKey.keyI,
        'f8' => PhysicalKeyboardKey.f8,
        _ => PhysicalKeyboardKey.space,
      },
      modifiers: switch (_shortcut) {
        'ctrl_alt_i' => [HotKeyModifier.control, HotKeyModifier.alt],
        'f8' => const [],
        _ => [HotKeyModifier.control, HotKeyModifier.alt],
      },
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(hotKey, keyDownHandler: (_) => _controller.toggle());
      _hotkey = hotKey;
      _hotkeyError = null;
    } on Object catch (e) {
      _hotkeyError = '$e';
      debugPrint('Island shortcut not registered: $e');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: IslandView(
        controller: _controller,
        cardKey: _cardKey,
        shortcut: _shortcut,
        hotkeyError: _hotkeyError,
        metrics: _metrics,
        onDock: _dock,
        onResetLayout: _resetLayout,
        onShortcut: _setShortcut,
        onAttention: _setAttention,
        onRevealMain: () => widget.platform.revealMain(),
        onDragStart: _dragStart,
        onDragUpdate: _dragUpdate,
        onDragEnd: _dragEnd,
      ),
    );
  }
}
