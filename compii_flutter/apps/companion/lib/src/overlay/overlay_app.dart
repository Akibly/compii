import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../console/character.dart';
import '../console/core_client.dart';

/// Size of the overlay's popup window, matching windows/runner/main.cpp.
const overlayWindow = Size(460, 360);

/// The desktop pointing overlay (HeyClicky-style). The native runner creates
/// it as a small borderless, always-on-top popup; here it becomes transparent
/// and click-through. When Core says "point at this", the window moves beside
/// the item, the Orbling's free mitten reaches out to it, a ring marks it and
/// a bubble explains. Then it fades away.
///
/// The window is never resized: resizing a transparent window after creation
/// leaves its picture stretched or blank on Windows.
Future<void> runOverlay() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final display = await screenRetriever.getPrimaryDisplay();
  final scale = (display.scaleFactor ?? 1).toDouble();
  // Topmost and hidden from the taskbar are set natively when the popup is created.
  await windowManager.setBackgroundColor(Colors.transparent);
  await windowManager.setIgnoreMouseEvents(true);
  runApp(
    OverlayApp(
      core: CoreClient()..start(),
      scale: scale,
      screen: display.size,
      onPlace: windowManager.setPosition,
    ),
  );
}

class OverlayApp extends StatelessWidget {
  const OverlayApp({
    super.key,
    required this.core,
    required this.scale,
    required this.screen,
    required this.onPlace,
  });
  final CoreClient core;
  final double scale;
  final Size screen;
  final Future<void> Function(Offset) onPlace;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    color: Colors.transparent,
    theme: ThemeData(useMaterial3: true, canvasColor: Colors.transparent),
    home: PointerLayer(
      points: core.lastPoint,
      scale: scale,
      screen: screen,
      window: overlayWindow,
      onPlace: onPlace,
    ),
  );
}

/// Draws the Orbling pointing at the latest target. With [window] and
/// [onPlace] it lives in a small window that moves beside the target;
/// without them it draws across the whole area (used in tests and previews).
class PointerLayer extends StatefulWidget {
  const PointerLayer({
    super.key,
    required this.points,
    required this.scale,
    this.screen,
    this.window,
    this.onPlace,
    this.showFor = const Duration(seconds: 9),
  });
  final ValueListenable<Map<String, dynamic>?> points;

  /// Screen pixels per logical pixel (Core reports physical pixels).
  final double scale;

  /// Logical size of the whole screen; defaults to this widget's size.
  final Size? screen;
  final Size? window;
  final Future<void> Function(Offset)? onPlace;
  final Duration showFor;

  @override
  State<PointerLayer> createState() => _PointerLayerState();
}

class _Layout {
  _Layout(this.ring, this.character, this.bubble, this.reach);
  final Rect ring;
  final Rect character;
  final Rect bubble;
  final Offset reach;

  Rect get bounds => ring.expandToInclude(character).expandToInclude(bubble);

  _Layout shift(Offset by) =>
      _Layout(ring.shift(by), character.shift(by), bubble.shift(by), reach);
}

class _PointerLayerState extends State<PointerLayer> {
  static const _size = 132.0;
  static const _bubbleWidth = 280.0;
  _Layout? _layout;
  String _message = '';
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.points.addListener(_onPoint);
  }

  @override
  void dispose() {
    widget.points.removeListener(_onPoint);
    _hide?.cancel();
    super.dispose();
  }

  /// Where everything goes, in screen coordinates.
  _Layout _place(Rect target, Size screen, bool withBubble) {
    final left = target.left - _size * .95 < 8;
    final below = target.bottom + _size + 70 < screen.height;
    final x = (left ? target.right + 6 : target.left - _size * .95)
        .clamp(8.0, screen.width - _size - 8);
    final y = (below ? target.bottom + 6 : target.top - _size - 6)
        .clamp(8.0, screen.height - _size - 8);
    final character = Rect.fromLTWH(x, y, _size, _size);
    final bubble = withBubble
        ? Rect.fromLTWH(
            (x + _size / 2 - _bubbleWidth / 2)
                .clamp(8.0, screen.width - _bubbleWidth - 8),
            below ? y + _size + 4 : y - 64,
            _bubbleWidth,
            56,
          )
        : character;
    // The mitten reaches for the nearest edge of the target.
    final aim = Offset(
      target.center.dx.clamp(target.left + 4, target.right - 4),
      below ? target.bottom : target.top,
    );
    return _Layout(
      target.inflate(6),
      character,
      bubble,
      (aim - character.topLeft) / _size,
    );
  }

  Future<void> _onPoint() async {
    final p = widget.points.value;
    if (p == null) return;
    double n(String k) => (p[k] as num).toDouble() / widget.scale;
    final target = Rect.fromLTWH(n('x'), n('y'), n('w'), n('h'));
    final message = (p['message'] as String?)?.trim() ?? '';
    final screen = widget.screen ?? MediaQuery.of(context).size;
    var layout = _place(target, screen, message.isNotEmpty);
    final window = widget.window;
    final onPlace = widget.onPlace;
    if (window != null && onPlace != null) {
      // Move the small window so the whole scene sits inside it.
      final b = layout.bounds;
      final origin = Offset(
        (b.center.dx - window.width / 2).clamp(0.0, screen.width - window.width),
        (b.center.dy - window.height / 2)
            .clamp(0.0, screen.height - window.height),
      );
      layout = layout.shift(-origin);
      setState(() => _visible = false);
      await onPlace(origin);
    }
    if (!mounted) return;
    setState(() {
      _layout = layout;
      _message = message;
      _visible = true;
    });
    _hide?.cancel();
    _hide = Timer(widget.showFor, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    if (layout == null) return const SizedBox.expand();
    const ink = Color(0xFF15122E);
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(
            rect: layout.ring,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: OrblingPalette.body, width: 3),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: layout.character,
            child: Orbling(mood: Mood.idle, reach: layout.reach),
          ),
          if (_message.isNotEmpty)
            Positioned(
              left: layout.bubble.left,
              top: layout.bubble.top,
              width: layout.bubble.width,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Color(0xFFC9C4F6), width: 1.5),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    _message,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
