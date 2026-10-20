import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
    this.onDecide,
    this.setClickThrough,
    this.origin = Offset.zero,
  });

  /// Top left of this layer on the virtual desktop, in physical pixels (negative when a
  /// monitor sits left of or above the main one). Core's screen positions are relative to it.
  final Offset origin;

  /// Answer an approval from the Yes / No card beside the cursor.
  final Future<void> Function(String approvalId, bool approved)? onDecide;

  /// Let clicks through the overlay (true) or catch them (false, only over the card).
  final Future<void> Function(bool through)? setClickThrough;

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
  Timer? _follow;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  // Compii drawing on screen like a teacher with a marker (draw_on_screen).
  late final AnimationController _marker = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
  List<_Mark> _marks = const [];
  Timer? _marksOff;
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

  double _tilt = 0; // leans with motion
  final List<Offset> _trail = []; // paint trail while you hold Ctrl+Alt
  double _trailFade = 0;
  bool _hidden = false; // Ctrl+Alt+H

  // Pointing.
  Rect? _target;
  String _targetLabel = '';
  Offset _flyFrom = Offset.zero;

  // Asking for permission: a Yes / No card that stays put where it appeared.
  String _approvalId = '';
  Offset? _askAt;
  final _card = GlobalKey();
  bool _catching = false; // the overlay is taking clicks (mouse over the card, or drawing)

  // Drawing: while you hold Ctrl+Alt, press the mouse button and drag to draw on screen.
  // The overlay takes the mouse only while the keys are held, so nothing underneath gets clicked.
  final List<List<Offset>> _ink = [];
  bool _catchAll = false;
  @visibleForTesting
  int get inkStrokes => _ink.length;
  Timer? _catchAllSafety;

  bool get asking => state == 'needs_you' && _approvalId.isNotEmpty;

  bool get talking => state != 'idle';

  @override
  void initState() {
    super.initState();
    _sub = widget.events.listen(onEvent);
    widget.points?.addListener(_onPoint);
    // Read the pointer ~60 times a second; redraw only when something moved,
    // so an idle buddy costs next to nothing.
    _follow = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  @override
  void dispose() {
    widget.points?.removeListener(_onPoint);
    _follow?.cancel();
    _catchAllSafety?.cancel();
    _marksOff?.cancel();
    _marker.dispose();
    _pulse.dispose();
    _fly.dispose();
    _sub?.cancel();
    _hide?.cancel();
    _flyBack?.cancel();
    super.dispose();
  }

  // ---- motion: follow the cursor every frame (cheap: nothing moves but pixels) ----

  int _ticks = 0;
  int _stillTicks = 0;

  void _tick() {
    _ticks++;
    // When the mouse has been still for a moment, check it 10x a second instead of 60.
    final resting = _stillTicks > 30 && _target == null && !_fly.isAnimating;
    if (!_asking && (!resting || _ticks % 6 == 0)) {
      _asking = true;
      widget.cursor().then((p) {
        _asking = false;
        _stillTicks = (_cursor != null && (p - _cursor!).distance < .5) ? _stillTicks + 1 : 0;
        _cursor = p;
      }, onError: (_) => _asking = false);
    }
    final c = _cursor;
    if (c == null) return;
    _catchClicksOverCard(c);
    if ((state == 'answer' || state == 'note') && !speaking && _answerAt != null && (c - _answerAt!).distance > 220) {
      _answerAt = null;
      _hide?.cancel();
      _goIdle();
    }
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
    final goal = c + const Offset(14, 16);
    final next = Offset.lerp(_pos, goal, _pos == Offset.zero ? 1 : .38)!;
    final tilt = ((next.dx - _pos.dx) * .035).clamp(-.45, .45);
    var changed = (next - _pos).distance > .25 || (tilt - _tilt).abs() > .01;
    if (state == 'listening') {
      if (_trail.isNotEmpty && (c - _trail.last).distance > 300) _trail.clear(); // a jump, not a gesture
      if (_trail.isEmpty || (c - _trail.last).distance > 3) {
        _trail.add(c);
        if (_trail.length > 240) _trail.removeAt(0);
        _trailFade = 1;
        changed = true;
      }
    } else if (_trailFade > 0) {
      _trailFade = math.max(0, _trailFade - (_ink.isEmpty ? .02 : .006)); // drawings linger ~3 s
      if (_trailFade == 0) {
        _trail.clear();
        _ink.clear();
      }
      changed = true;
    }
    if (changed) {
      setState(() {
        _pos = next;
        _tilt = _tilt + (tilt - _tilt) * .3;
      });
    }
  }

  /// Clicks pass through the overlay to your apps, except while the mouse is over
  /// the Yes / No card, so you can answer right where you are.
  void _catchClicksOverCard(Offset c) {
    var over = false;
    if (asking) {
      final box = _card.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        over = (box.localToGlobal(Offset.zero) & box.size).inflate(6).contains(c);
      }
    }
    final want = _catchAll || over;
    if (want != _catching) {
      _catching = want;
      widget.setClickThrough?.call(!want);
    }
  }

  void _setCatchAll(bool on) {
    _catchAll = on;
    _catchAllSafety?.cancel();
    if (on) {
      // Never hold on to the mouse for long, whatever happens to Core.
      _catchAllSafety = Timer(const Duration(seconds: 30), () => _setCatchAll(false));
    }
    if (_cursor != null) _catchClicksOverCard(_cursor!);
  }

  Future<void> _decide(bool approved) async {
    final id = _approvalId;
    setState(() {
      _approvalId = '';
      state = 'thinking';
      text = approved ? 'Okay…' : '';
    });
    _catching = false;
    await widget.setClickThrough?.call(true);
    await widget.onDecide?.call(id, approved);
    if (!approved) _goIdle();
  }

  Offset _anchor(Rect r) => Offset(r.right - math.min(10, r.width / 3), r.bottom - math.min(8, r.height / 3));

  void _onPoint() {
    final p = widget.points?.value;
    if (p == null) return;
    double n(String k) => (p[k] as num).toDouble() / widget.scale;
    setState(() {
      _target = Rect.fromLTWH(n('x') - widget.origin.dx / widget.scale, n('y') - widget.origin.dy / widget.scale,
          n('w'), n('h'));
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
          _approvalId = s == 'needs_you' ? '${e['approval_id'] ?? ''}' : '';
          _askAt = s == 'needs_you' ? _pos : null;
          switch (s) {
            case 'listening':
              text = '';
              heard = '';
              _trail.clear();
            case 'watching':
              text = e['text'] != null ? '${e['text']}' : 'Watching — show me, then hold Ctrl+Alt and say “done”';
            case 'dictating':
              text = '';
            case 'thinking':
              if (e['heard'] != null) heard = '${e['heard']}';
              text = e['step'] != null ? '${e['step']}…' : '';
            case 'answer' || 'needs_you' || 'setup' || 'error' || 'idle':
              text = '${e['text'] ?? ''}';
          }
        });
        _hide?.cancel();
        if (s == 'listening') {
          _ink.clear();
          _marks = const [];
          _setCatchAll(true);
        } else if (_catchAll) {
          _setCatchAll(false);
        }
        if (s == 'idle') {
          if (text.isNotEmpty) {
            setState(() => state = 'note');
            _hide = Timer(const Duration(milliseconds: 2500), _goIdle);
          } else {
            _goIdle();
          }
        } else if (s == 'answer' || s == 'setup' || s == 'error') {
          // Long enough to read; while Compii is talking it stays (see voice_speaking).
          _answerAt = _cursor;
          _hide = Timer(Duration(milliseconds: (2500 + text.length * 45).clamp(3000, 12000)), _closeIfQuiet);
        }
      case 'voice_draw':
        double n(Map m, String k) => (m[k] as num).toDouble() / widget.scale;
        Rect r(Map m) => Rect.fromLTWH(n(m, 'x') - widget.origin.dx / widget.scale,
            n(m, 'y') - widget.origin.dy / widget.scale, n(m, 'w'), n(m, 'h'));
        final shapes = [
          for (final m in (e['shapes'] as List? ?? const []).cast<Map>())
            _Mark('${m['kind']}', r(m), m['from'] is Map ? r(m['from'] as Map) : null),
        ];
        setState(() => _marks = shapes);
        _marker.duration = Duration(milliseconds: 700 + 500 * shapes.length);
        _marker.forward(from: 0);
        _marksOff?.cancel();
        _marksOff = Timer(const Duration(seconds: 12), () {
          if (mounted) setState(() => _marks = const []);
        });
      case 'voice_buddy_visible':
        setState(() => _hidden = e['visible'] == false);
      case 'voice_partial' when state == 'listening' || state == 'dictating':
        setState(() => text = '${e['text']}');
      case 'voice_level' when state == 'listening' || state == 'dictating':
        level = (e['level'] as num).toDouble();
      case 'voice_caption' when state == 'answer' || state == 'thinking' || state == 'needs_you':
        setState(() => text = '${e['text']}');
      case 'voice_speaking':
        setState(() => speaking = e['on'] == true);
        if (e['on'] != true && state == 'answer') {
          _hide?.cancel();
          _hide = Timer(const Duration(seconds: 2), _goIdle); // closes soon after it stops talking
        }
    }
  }

  /// Where the pointer was when the answer appeared: moving well away dismisses it.
  Offset? _answerAt;

  void _closeIfQuiet() {
    if (speaking) return; // voice_speaking(off) will close it
    _goIdle();
  }

  void _goIdle() {
    if (!mounted) return;
    setState(() {
      state = 'idle';
      text = '';
    });
  }

  Color get _tint => switch (state) {
    'listening' || 'dictating' => const Color(0xFF5CE1E6),
    'watching' => const Color(0xFFFF7D72),
    'needs_you' => const Color(0xFFFFC94D),
    'error' || 'setup' => const Color(0xFFFF7D72),
    _ => const Color(0xFF6E8BFF),
  };

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!still && talking && !_pulse.isAnimating) _pulse.repeat();
    if ((still || !talking) && _pulse.isAnimating) _pulse.stop();
    // Hidden (Ctrl+Alt+H): only appears while you're actually talking to it.
    final engaged = const {'listening', 'dictating', 'thinking', 'needs_you', 'watching'}.contains(state) || _target != null;
    if (_cursor == null || (_hidden && !engaged) || (!widget.alwaysVisible && !talking && _target == null)) {
      return const SizedBox.expand();
    }

    final screen = MediaQuery.sizeOf(context);
    final listening = state == 'listening' || state == 'dictating';
    final watching = state == 'watching';
    final thinking = state == 'thinking';
    final pointing = _target != null && _fly.value > .95;
    final (String line, bool muted) = switch (state) {
      _ when pointing && _targetLabel.isNotEmpty => (_targetLabel, false),
      'thinking' => text.isNotEmpty ? (text, true) : (heard, true),
      'idle' => ('', false),
      _ => (text, false),
    };
    final showLabel = line.isNotEmpty || listening || thinking || watching;
    final at = asking ? (_askAt ?? _pos) : _pos; // the permission card stays put so you can reach it
    final flipX = at.dx + 330 > screen.width;
    final flipY = at.dy + (asking ? 130 : 90) > screen.height;

    return MouseRegion(
      cursor: listening ? SystemMouseCursors.precise : MouseCursor.defer,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: listening ? (e) => setState(() => _ink.add([e.localPosition])) : null,
        onPointerMove: listening
            ? (e) {
                if (e.down && _ink.isNotEmpty) setState(() => _ink.last.add(e.localPosition));
              }
            : null,
        child: SizedBox.expand(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (_marks.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _marker,
                      builder: (context, _) => CustomPaint(painter: _MarkerPainter(_marks, _marker.value)),
                    ),
                  ),
                ),
              for (final stroke in _ink)
                if (stroke.length > 1)
                  Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _InkPainter(List.of(stroke), _tint,
                      listening ? 1 : _trailFade)))),
              if (_trail.length > 1 && _ink.isEmpty)
                Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _TrailPainter(List.of(_trail), _tint, _trailFade)))),
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
                left: _pos.dx - 17,
                top: _pos.dy - 17,
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) => CustomPaint(
                      size: const Size(34, 34),
                      painter: SparkPainter(t: _pulse.value, tint: _tint, listening: listening, thinking: thinking,
                          level: listening ? level : 0, active: talking || _target != null, tilt: _tilt, recording: watching),
                    ),
                  ),
                ),
              ),
              if (showLabel)
                Positioned(
                  left: flipX ? null : at.dx + 16,
                  right: flipX ? screen.width - at.dx + 16 : null,
                  top: flipY ? null : at.dy - 2,
                  bottom: flipY ? screen.height - at.dy - 2 : null,
                  child: _GlassLabel(
                    key: _card,
                    tint: _tint,
                    child: asking ? _askCard(line) : Row(
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
                              ? _Shimmer(text: state == 'dictating' ? 'Dictating' : (listening ? 'Listening' : 'Thinking'), t: _pulse)
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
          ),
        ),
      ),
    );
  }

  Widget _askCard(String line) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        line.isEmpty ? 'May I go ahead?' : line,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xF2FFFFFF), fontSize: 13, height: 1.42, fontWeight: FontWeight.w500,
            decoration: TextDecoration.none, fontFamily: 'Segoe UI Variable Text'),
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Pill(label: 'Yes', primary: true, tint: _tint, onTap: () => _decide(true)),
          const SizedBox(width: 6),
          _Pill(label: 'No', tint: _tint, onTap: () => _decide(false)),
        ],
      ),
    ],
  );
}

/// A small button on the permission card.
class _Pill extends StatefulWidget {
  const _Pill({required this.label, required this.tint, required this.onTap, this.primary = false});
  final String label;
  final Color tint;
  final VoidCallback onTap;
  final bool primary;
  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          color: widget.primary
              ? widget.tint.withValues(alpha: _hover ? 1 : .88)
              : Color(_hover ? 0x33FFFFFF : 0x1FFFFFFF),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: widget.primary ? const Color(0xFF1A1630) : const Color(0xF2FFFFFF),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
            fontFamily: 'Segoe UI Variable Text',
          ),
        ),
      ),
    ),
  );
}

/// Small, dark, frosted label: Compii's voice on screen.
class _GlassLabel extends StatelessWidget {
  const _GlassLabel({super.key, required this.child, required this.tint});
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

/// The buddy: a small rounded "spark" that points the way like a cursor but
/// isn't one, and isn't a character either. Its tip leans toward your
/// pointer; it glows and swells with your voice, slowly turns while thinking,
/// and tilts as it moves.
class SparkPainter extends CustomPainter {
  SparkPainter({required this.t, required this.tint, required this.listening, required this.thinking,
      required this.level, required this.active, this.tilt = 0, this.recording = false});
  final double t;
  final Color tint;
  final bool listening;
  final bool thinking;
  final double level;
  final bool active;
  final double tilt;
  final bool recording;

  @override
  void paint(Canvas canvas, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final wave = math.sin(t * math.pi * 2);
    final glow = active ? .5 + .18 * wave + level * .3 : .34;
    canvas.drawCircle(c, 15 + level * 7,
        Paint()..shader = RadialGradient(colors: [tint.withValues(alpha: glow.clamp(0.0, .85)), tint.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: c, radius: 16 + level * 7)));
    if (listening || recording) {
      for (final k in [0.0, .5]) {
        final p = (t * 1.6 + k) % 1;
        canvas.drawCircle(c, 8 + p * 11, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = tint.withValues(alpha: (1 - p) * .55));
      }
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    // Points up-left toward the real pointer; tilts with motion; turns while thinking.
    canvas.rotate(-math.pi / 4 + tilt + (thinking ? t * math.pi * 2 : 0));
    final size = 9.5 * (1 + (listening ? level * .22 : (active ? wave * .04 : 0)));
    // A compact arrowhead with a gently notched base and softly rounded corners:
    // it points like a cursor without being one.
    final tip = Offset(0, -size * 1.2);
    final right = Offset(size * .9, size * .78);
    final notch = Offset(0, size * .38);
    final left = Offset(-size * .9, size * .78);
    final path = _rounded([tip, right, notch, left], [1.4, 3.0, 2.2, 3.0]);
    canvas.drawPath(path.shift(const Offset(0, 1.4)), Paint()
      ..color = const Color(0x40000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    final bounds = path.getBounds();
    canvas.drawPath(path, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color.lerp(tint, Colors.white, .45)!, tint, Color.lerp(tint, const Color(0xFF2A1F9E), .55)!],
              stops: const [0, .45, 1])
          .createShader(bounds));
    // A glassy highlight along the leading edge.
    canvas.drawLine(Offset.lerp(tip, left, .18)!, Offset.lerp(tip, left, .62)!, Paint()
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x8CFFFFFF));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .9
      ..color = const Color(0x66FFFFFF));
    canvas.restore();
    if (recording) {
      canvas.drawCircle(c + const Offset(9, -9), 3, Paint()..color = const Color(0xFFFF5A5F));
    }
  }

  @override
  bool shouldRepaint(SparkPainter o) =>
      o.t != t || o.tint != tint || o.listening != listening || o.thinking != thinking || o.level != level ||
      o.active != active || o.tilt != tilt || o.recording != recording;
}

/// A closed polygon with each corner rounded by its own radius.
Path _rounded(List<Offset> pts, List<double> radii) {
  final path = Path();
  for (var i = 0; i < pts.length; i++) {
    final prev = pts[(i - 1 + pts.length) % pts.length], cur = pts[i], next = pts[(i + 1) % pts.length];
    final r = radii[i];
    Offset towards(Offset from, Offset to) {
      final d = to - from;
      final len = d.distance;
      return from + d / len * math.min(r, len / 2);
    }

    final a = towards(cur, prev), b = towards(cur, next);
    if (i == 0) {
      path.moveTo(a.dx, a.dy);
    } else {
      path.lineTo(a.dx, a.dy);
    }
    path.quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
  }
  return path..close();
}

/// The paint trail left while you hold Ctrl+Alt and move the mouse: circle or
/// wave at something to show Compii what you mean.
/// Something Compii drew: a circle, underline, box or arrow around an item.
class _Mark {
  const _Mark(this.kind, this.rect, this.from);
  final String kind;
  final Rect rect;
  final Rect? from;
}

/// Compii's marker: shapes appear stroke by stroke, slightly hand-drawn, one after another.
class _MarkerPainter extends CustomPainter {
  _MarkerPainter(this.marks, this.t);
  final List<_Mark> marks;
  final double t;
  static const ink = Color(0xFFFF5C93);

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < marks.length; i++) {
      final local = (t * marks.length - i).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final m = marks[i];
      final path = _path(m, size);
      final metrics = path.computeMetrics().toList();
      final total = metrics.fold<double>(0, (a, x) => a + x.length);
      var left = total * Curves.easeOutCubic.transform(local);
      final drawn = Path();
      for (final metric in metrics) {
        if (left <= 0) break;
        drawn.addPath(metric.extractPath(0, math.min(left, metric.length)), Offset.zero);
        left -= metric.length;
      }
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(drawn, pen..strokeWidth = 11..color = ink.withValues(alpha: .22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawPath(drawn, Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 4
        ..color = ink);
    }
  }

  Path _path(_Mark m, Size size) {
    final r = m.rect;
    switch (m.kind) {
      case 'underline':
        return Path()
          ..moveTo(r.left - 4, r.bottom + 5)
          ..quadraticBezierTo(r.center.dx, r.bottom + 9, r.right + 6, r.bottom + 3);
      case 'box':
        return Path()..addRRect(RRect.fromRectAndRadius(r.inflate(7), const Radius.circular(8)));
      case 'arrow':
        // Edge to edge: from the side of the first item that faces the second.
        final f = m.from;
        final vertical = f != null && (r.center.dy - f.center.dy).abs() > (r.center.dx - f.center.dx).abs();
        final down = f != null && r.center.dy > f.center.dy;
        final right = f != null && r.center.dx > f.center.dx;
        final end = !vertical
            ? Offset(f == null || right ? r.left - 6 : r.right + 6, r.center.dy)
            : Offset(r.center.dx, down ? r.top - 6 : r.bottom + 6);
        final start = f == null
            ? Offset(math.max(8, end.dx - 110), math.max(8, end.dy - 80))
            : vertical
                ? Offset(f.center.dx, down ? f.bottom + 14 : f.top - 14)
                : Offset(right ? f.right + 16 : f.left - 16, f.center.dy);
        final mid = Offset((start.dx + end.dx) / 2, math.min(start.dy, end.dy) - 30);
        final dir = end - mid;
        final a = math.atan2(dir.dy, dir.dx);
        Offset head(double turn) => end - Offset(math.cos(a + turn), math.sin(a + turn)) * 16;
        return Path()
          ..moveTo(start.dx, start.dy)
          ..quadraticBezierTo(mid.dx, mid.dy, end.dx, end.dy)
          ..moveTo(head(.5).dx, head(.5).dy)
          ..lineTo(end.dx, end.dy)
          ..lineTo(head(-.5).dx, head(-.5).dy);
      default: // circle: a loose, hand-drawn loop that overshoots a little
        final c = r.center;
        final rx = r.width / 2 + 14, ry = r.height / 2 + 12;
        final p = Path();
        const start = -2.3;
        for (var k = 0; k <= 60; k++) {
          final th = start + k / 60 * math.pi * 2.12;
          final wobble = 1 + .045 * math.sin(th * 3 + 1);
          final pt = Offset(c.dx + math.cos(th) * rx * wobble, c.dy + math.sin(th) * ry * wobble);
          k == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
        }
        return p;
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter o) => o.t != t || o.marks != marks;
}

/// What you drew while holding Ctrl+Alt: a bright marker line.
class _InkPainter extends CustomPainter {
  _InkPainter(this.points, this.color, this.fade);
  final List<Offset> points;
  final Color color;
  final double fade;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || fade <= 0) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    }
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, pen..strokeWidth = 12..color = color.withValues(alpha: .25 * fade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.5
      ..color = color.withValues(alpha: .95 * fade));
  }

  @override
  bool shouldRepaint(_InkPainter o) => true;
}

class _TrailPainter extends CustomPainter {
  _TrailPainter(this.points, this.color, this.fade);
  final List<Offset> points;
  final Color color;
  final double fade;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || fade <= 0) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color.withValues(alpha: .18 * fade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color.withValues(alpha: .75 * fade));
  }

  @override
  bool shouldRepaint(_TrailPainter o) => true;
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
