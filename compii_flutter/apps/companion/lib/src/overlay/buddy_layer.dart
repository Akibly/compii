import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Clicky-style cursor buddy, drawn inside one full-screen, click-through
/// overlay (no window ever moves, so it keeps up with the mouse).
///
/// A small glowing blue pointer trails your real cursor. Hold Ctrl+Alt and it
/// listens (cyan ripples and a tiny sound-wave), thinks, then answers in a
/// small dark-glass label beside it while Compii speaks. When Compii points
/// at something, the buddy flies there along an arc, rings the item, says
/// what it is, then flies back to your cursor.
class BuddyLayer extends StatefulWidget {
  const BuddyLayer({
    super.key,
    required this.events,
    required this.cursor,
    this.points,
    this.scale = 1,
    this.alwaysVisible = true,
  });

  /// Core's voice_* events (voice_buddy, voice_partial, voice_level, voice_caption, voice_speaking).
  final Stream<Map<String, dynamic>> events;

  /// "Point at this" events from Core (physical pixels).
  final ValueListenable<Map<String, dynamic>?>? points;

  /// Where the mouse pointer is now (logical pixels, relative to this layer).
  final Future<Offset> Function() cursor;

  /// Physical pixels per logical pixel.
  final double scale;

  /// Show the little pointer even when Compii is idle (like Clicky).
  final bool alwaysVisible;

  @override
  State<BuddyLayer> createState() => BuddyLayerState();
}

class BuddyLayerState extends State<BuddyLayer> with TickerProviderStateMixin {
  StreamSubscription<Map<String, dynamic>>? _sub;
  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  Timer? _hide;
  Timer? _flyBack;

  String state = 'idle';
  String text = '';
  String heard = '';
  double level = 0;
  bool speaking = false;

  Offset? _cursor; // latest real pointer position
  Offset _pos = Offset.zero; // where the buddy is drawn (trails the cursor)
  bool _asking = false;

  // Pointing.
  Rect? _target;
  String _targetLabel = '';
  Offset _flyFrom = Offset.zero;

  bool get talking => state != 'idle';

  @override
  void initState() {
    super.initState();
    _sub = widget.events.listen(onEvent);
    widget.points?.addListener(_onPoint);
    _ticker.start();
  }

  @override
  void dispose() {
    widget.points?.removeListener(_onPoint);
    _ticker.dispose();
    _pulse.dispose();
    _fly.dispose();
    _sub?.cancel();
    _hide?.cancel();
    _flyBack?.cancel();
    super.dispose();
  }

  // ---- motion: follow the cursor every frame (cheap: nothing moves but pixels) ----

  void _tick(Duration _) {
    if (!_asking) {
      _asking = true;
      widget.cursor().then((p) {
        _asking = false;
        _cursor = p;
      }, onError: (_) => _asking = false);
    }
    final c = _cursor;
    if (c == null) return;
    if (_target != null) {
      final t = Curves.easeInOutCubic.transform(_fly.value);
      final end = _anchor(_target!);
      final mid = Offset((_flyFrom.dx + end.dx) / 2, math.min(_flyFrom.dy, end.dy) - 80);
      // A quadratic arc from where it was to the item.
      final goal = Offset(
        (1 - t) * (1 - t) * _flyFrom.dx + 2 * (1 - t) * t * mid.dx + t * t * end.dx,
        (1 - t) * (1 - t) * _flyFrom.dy + 2 * (1 - t) * t * mid.dy + t * t * end.dy,
      );
      if ((goal - _pos).distance > .3 || _fly.isAnimating) setState(() => _pos = goal);
      return;
    }
    final goal = c + const Offset(12, 14);
    final next = Offset.lerp(_pos, goal, _pos == Offset.zero ? 1 : .38)!;
    if ((next - _pos).distance > .25) setState(() => _pos = next);
  }

  Offset _anchor(Rect r) => Offset(r.right - math.min(10, r.width / 3), r.bottom - math.min(8, r.height / 3));

  void _onPoint() {
    final p = widget.points?.value;
    if (p == null) return;
    double n(String k) => (p[k] as num).toDouble() / widget.scale;
    setState(() {
      _target = Rect.fromLTWH(n('x'), n('y'), n('w'), n('h'));
      final message = (p['message'] as String?)?.trim() ?? '';
      _targetLabel = message.isNotEmpty ? message : '${p['name'] ?? ''}';
      _flyFrom = _pos;
    });
    _fly.forward(from: 0);
    _flyBack?.cancel();
    _flyBack = Timer(const Duration(seconds: 7), _returnToCursor);
  }

  void _returnToCursor() {
    if (!mounted) return;
    setState(() => _target = null);
  }

  // ---- what Compii is doing ----

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
            case 'answer' || 'needs_you' || 'setup' || 'error' || 'idle':
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
          _hide = Timer(Duration(seconds: (7 + text.length ~/ 18).clamp(7, 28)), _goIdle);
        }
      case 'voice_partial' when state == 'listening':
        setState(() => text = '${e['text']}');
      case 'voice_level' when state == 'listening':
        level = (e['level'] as num).toDouble();
      case 'voice_caption' when state == 'answer' || state == 'thinking' || state == 'needs_you':
        setState(() => text = '${e['text']}');
      case 'voice_speaking':
        setState(() => speaking = e['on'] == true);
        if (e['on'] != true && state == 'answer') {
          _hide?.cancel();
          _hide = Timer(const Duration(seconds: 4), _goIdle);
        }
    }
  }

  void _goIdle() {
    if (!mounted) return;
    setState(() {
      state = 'idle';
      text = '';
    });
  }

  Color get _tint => switch (state) {
    'listening' => const Color(0xFF5CE1E6),
    'needs_you' => const Color(0xFFFFC94D),
    'error' || 'setup' => const Color(0xFFFF7D72),
    _ => const Color(0xFF6E8BFF),
  };

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!still && talking && !_pulse.isAnimating) _pulse.repeat();
    if ((still || !talking) && _pulse.isAnimating) _pulse.stop();
    if (_cursor == null || (!widget.alwaysVisible && !talking && _target == null)) return const SizedBox.expand();

    final screen = MediaQuery.sizeOf(context);
    final listening = state == 'listening';
    final thinking = state == 'thinking';
    final pointing = _target != null && _fly.value > .95;
    final (String line, bool muted) = switch (state) {
      _ when pointing && _targetLabel.isNotEmpty => (_targetLabel, false),
      'thinking' => text.isNotEmpty ? (text, true) : (heard, true),
      'idle' => ('', false),
      _ => (text, false),
    };
    final showLabel = line.isNotEmpty || listening || thinking;
    final flipX = _pos.dx + 330 > screen.width;
    final flipY = _pos.dy + 90 > screen.height;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (_target != null)
          Positioned.fromRect(
            rect: _target!.inflate(5),
            child: IgnorePointer(
              child: Opacity(
                opacity: _fly.value > .8 ? 1 : 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFF6E8BFF), width: 2),
                    boxShadow: const [BoxShadow(color: Color(0x666E8BFF), blurRadius: 14)],
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: _pos.dx - 6,
          top: _pos.dy - 6,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => CustomPaint(
                size: const Size(34, 34),
                painter: PointerPainter(t: _pulse.value, tint: _tint, listening: listening, thinking: thinking,
                    level: listening ? level : 0, active: talking || _target != null),
              ),
            ),
          ),
        ),
        if (showLabel)
          Positioned(
            left: flipX ? null : _pos.dx + 24,
            right: flipX ? screen.width - _pos.dx + 4 : null,
            top: flipY ? null : _pos.dy + 6,
            bottom: flipY ? screen.height - _pos.dy + 4 : null,
            child: _GlassLabel(
              tint: _tint,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (listening) ...[
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, _) => CustomPaint(size: const Size(14, 12), painter: _WavePainter(_pulse.value, level, _tint)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: line.isEmpty
                        ? _Shimmer(text: listening ? 'Listening' : 'Thinking', t: _pulse)
                        : Text(
                            line,
                            maxLines: state == 'answer' ? 6 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: muted ? const Color(0xB3FFFFFF) : const Color(0xF2FFFFFF),
                              fontSize: 13,
                              height: 1.42,
                              letterSpacing: .1,
                              fontWeight: FontWeight.w500,
                              decoration: TextDecoration.none,
                              fontFamily: 'Segoe UI Variable Text',
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Small, dark, frosted label: Compii's voice on screen.
class _GlassLabel extends StatelessWidget {
  const _GlassLabel({required this.child, required this.tint});
  final Widget child;
  final Color tint;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 290),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        boxShadow: [
          const BoxShadow(color: Color(0x52000000), blurRadius: 14, offset: Offset(0, 6)),
          BoxShadow(color: tint.withValues(alpha: .18), blurRadius: 16, spreadRadius: -6),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: const Color(0xD9161427),
              border: Border.all(color: const Color(0x24FFFFFF)),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.text, required this.t});
  final String text;
  final Animation<double> t;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: t,
    builder: (context, _) => ShaderMask(
      shaderCallback: (r) => LinearGradient(
        colors: const [Color(0x73FFFFFF), Color(0xFFFFFFFF), Color(0x73FFFFFF)],
        stops: [(t.value - .3).clamp(0.0, 1.0), t.value, (t.value + .3).clamp(0.0, 1.0)],
      ).createShader(r),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600,
          letterSpacing: .3, decoration: TextDecoration.none, fontFamily: 'Segoe UI Variable Text')),
    ),
  );
}

/// The buddy itself: a small glowing blue pointer (like a second cursor).
class PointerPainter extends CustomPainter {
  PointerPainter({required this.t, required this.tint, required this.listening, required this.thinking, required this.level, required this.active});
  final double t;
  final Color tint;
  final bool listening;
  final bool thinking;
  final double level;
  final bool active;

  @override
  void paint(Canvas canvas, Size s) {
    const tip = Offset(6, 6);
    // Classic pointer arrow, about 17 px tall.
    final arrow = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx, tip.dy + 15.5)
      ..lineTo(tip.dx + 4.2, tip.dy + 11.6)
      ..lineTo(tip.dx + 7.2, tip.dy + 17.4)
      ..lineTo(tip.dx + 9.6, tip.dy + 16.2)
      ..lineTo(tip.dx + 6.7, tip.dy + 10.6)
      ..lineTo(tip.dx + 12.2, tip.dy + 10.6)
      ..close();
    final centre = tip + const Offset(5, 8);
    final glow = active ? .45 + .2 * math.sin(t * math.pi * 2) + level * .3 : .32;
    canvas.drawCircle(centre, 13 + level * 6,
        Paint()..shader = RadialGradient(colors: [tint.withValues(alpha: glow.clamp(0.0, .8)), tint.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: centre, radius: 15 + level * 6)));
    if (listening) {
      for (final k in [0.0, .5]) {
        final p = (t * 1.6 + k) % 1;
        canvas.drawCircle(centre, 8 + p * 10, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = tint.withValues(alpha: (1 - p) * .6));
      }
    }
    canvas.drawPath(arrow.shift(const Offset(0, 1.2)), Paint()
      ..color = const Color(0x55000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6));
    canvas.drawPath(arrow, Paint()
      ..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color.lerp(tint, Colors.white, .25)!, const Color(0xFF3B5BFF)])
          .createShader(arrow.getBounds()));
    canvas.drawPath(arrow, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white);
    if (thinking) {
      final a = t * math.pi * 2;
      canvas.drawCircle(centre + Offset(math.cos(a), math.sin(a)) * 13, 1.7, Paint()..color = tint);
    }
  }

  @override
  bool shouldRepaint(PointerPainter o) =>
      o.t != t || o.tint != tint || o.listening != listening || o.thinking != thinking || o.level != level || o.active != active;
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.t, this.level, this.tint);
  final double t;
  final double level;
  final Color tint;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = tint
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 4; i++) {
      final x = 1.5 + i * (s.width - 3) / 3;
      final h = (s.height * (.3 + .7 * level.clamp(0.1, 1.0) * (.5 + .5 * math.sin(t * math.pi * 8 + i * 1.7).abs()))).clamp(3.0, s.height);
      canvas.drawLine(Offset(x, s.height / 2 - h / 2), Offset(x, s.height / 2 + h / 2), p);
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) => true;
}
