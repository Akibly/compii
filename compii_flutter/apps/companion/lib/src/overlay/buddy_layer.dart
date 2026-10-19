import 'dart:async';

import 'package:flutter/material.dart';

import '../console/character.dart';

/// Clicky-style cursor buddy. While you hold Ctrl+Alt (or after a tap), a
/// small Orbling appears right beside your mouse pointer and follows it:
/// it shows your words as you speak, thinks, then answers in a speech bubble
/// while Compii says it out loud. It fades away a few seconds later.
///
/// Fed by Core's `voice_buddy`, `voice_partial`, `voice_level`,
/// `voice_caption` and `voice_speaking` events.
class BuddyLayer extends StatefulWidget {
  const BuddyLayer({
    super.key,
    required this.events,
    required this.cursor,
    required this.window,
    required this.screen,
    required this.onPlace,
    this.paused,
  });

  final Stream<Map<String, dynamic>> events;

  /// Where the mouse pointer is now (logical pixels).
  final Future<Offset> Function() cursor;
  final Size window;
  final Size screen;
  final Future<void> Function(Offset) onPlace;

  /// True while the pointing layer owns the window (Compii is pointing at something).
  final ValueNotifier<bool>? paused;

  @override
  State<BuddyLayer> createState() => BuddyLayerState();
}

class BuddyLayerState extends State<BuddyLayer> {
  static const _size = 64.0;
  static const _bubbleWidth = 340.0;

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _follow;
  Timer? _hide;
  String state = 'idle';
  String text = '';
  String heard = '';
  double level = 0;
  bool speaking = false;
  bool _flipX = false;
  bool _flipY = false;
  Offset? _last;

  bool get visible => state != 'idle';

  @override
  void initState() {
    super.initState();
    _sub = widget.events.listen(onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _follow?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  void onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'voice_buddy':
        final s = '${e['state']}';
        setState(() {
          state = s;
          switch (s) {
            case 'listening':
              text = '';
              heard = '';
            case 'thinking':
              if (e['heard'] != null) heard = '${e['heard']}';
              text = e['step'] != null ? '${e['step']}…' : '';
            case 'answer' || 'needs_you' || 'setup' || 'error':
              text = '${e['text'] ?? ''}';
            case 'idle':
              text = '${e['text'] ?? ''}';
          }
        });
        _hide?.cancel();
        if (s == 'idle') {
          if (text.isNotEmpty) {
            setState(() => state = 'note');
            _hide = Timer(const Duration(seconds: 3), _goIdle);
          } else {
            _goIdle();
          }
        } else if (s == 'answer' || s == 'setup' || s == 'error') {
          _hide = Timer(Duration(seconds: (8 + text.length ~/ 18).clamp(8, 30)), _goIdle);
        }
        if (visible) _startFollowing();
      case 'voice_partial' when state == 'listening':
        setState(() => text = '${e['text']}');
      case 'voice_level' when state == 'listening':
        setState(() => level = (e['level'] as num).toDouble());
      case 'voice_caption' when state == 'answer' || state == 'thinking' || state == 'needs_you':
        setState(() => text = '${e['text']}');
      case 'voice_speaking':
        setState(() => speaking = e['on'] == true);
        if (e['on'] != true && state == 'answer') {
          _hide?.cancel();
          _hide = Timer(const Duration(seconds: 5), _goIdle);
        }
    }
  }

  void _goIdle() {
    if (!mounted) return;
    setState(() => state = 'idle');
    _follow?.cancel();
    _follow = null;
  }

  void _startFollowing() {
    _follow ??= Timer.periodic(const Duration(milliseconds: 40), (_) => _move());
    _move();
  }

  Future<void> _move() async {
    if (widget.paused?.value == true) return;
    final p = await widget.cursor();
    if (_last != null && (p - _last!).distance < 2) return;
    _last = p;
    final w = widget.window, s = widget.screen;
    // Sit just below-right of the pointer; flip near the screen edges.
    final flipX = p.dx + w.width > s.width - 4;
    final flipY = p.dy + w.height > s.height - 4;
    final origin = Offset(
      flipX ? p.dx - w.width - 6 : p.dx + 14,
      flipY ? p.dy - w.height - 6 : p.dy + 16,
    );
    if (flipX != _flipX || flipY != _flipY) {
      setState(() {
        _flipX = flipX;
        _flipY = flipY;
      });
    }
    await widget.onPlace(origin);
  }

  Mood get _mood => switch (state) {
    'listening' => Mood.listening,
    'thinking' => Mood.thinking,
    'needs_you' => Mood.waiting,
    'error' => Mood.problem,
    _ => speaking ? Mood.speaking : Mood.happy,
  };

  @override
  Widget build(BuildContext context) {
    if (!visible || widget.paused?.value == true) return const SizedBox.expand();
    const ink = Color(0xFF15122E);
    final (String line, Color tint) = switch (state) {
      'listening' => (text.isEmpty ? 'Listening…' : text, const Color(0xFF0E9FAA)),
      'thinking' => (text.isNotEmpty ? text : (heard.isEmpty ? 'Thinking…' : '“$heard”'), const Color(0xFF7468F0)),
      'needs_you' => (text, const Color(0xFFB87300)),
      'error' || 'setup' => (text, const Color(0xFFD13F35)),
      _ => (text, OrblingPalette.body),
    };
    final character = SizedBox.square(
      dimension: _size,
      child: Orbling(mood: _mood, level: state == 'listening' ? level : 0, followPointer: false),
    );
    final bubble = line.isEmpty
        ? const SizedBox.shrink()
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _bubbleWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tint.withValues(alpha: .45), width: 1.4),
                boxShadow: const [BoxShadow(color: Color(0x332A2140), blurRadius: 16, offset: Offset(0, 6))],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state == 'thinking')
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: tint)),
                    ),
                  Flexible(
                    child: Text(
                      line,
                      maxLines: state == 'answer' ? 7 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: state == 'thinking' && text.isEmpty ? const Color(0xFF5E5A70) : ink,
                        fontSize: 14.5,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                        fontFamily: 'Segoe UI Variable Text',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
    return AnimatedOpacity(
      opacity: 1,
      duration: const Duration(milliseconds: 200),
      child: Align(
        alignment: Alignment(_flipX ? 1 : -1, _flipY ? 1 : -1),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: _flipY ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            textDirection: _flipX ? TextDirection.rtl : TextDirection.ltr,
            children: [character, const SizedBox(width: 6), Flexible(child: bubble)],
          ),
        ),
      ),
    );
  }
}
