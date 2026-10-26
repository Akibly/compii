import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/character.dart' show compiiColor;
import 'halo_cursor.dart';

/// Compii at your cursor, drawn inside one full-screen, click-through overlay (no
/// window ever moves, so it keeps up with the mouse).
///
/// What rides with the pointer is Compii's face in miniature: a small black-glass
/// capsule with its two eyes of light, parked at a fixed stand-off to the
/// bottom-right so it never covers the pixel you are pointing at, and looking back
/// at your pointer. Nothing orbits, trails or spins. Hold Ctrl+Alt and a halo of
/// light blooms around the pointer itself and swells with your voice, while your
/// words appear beside it as you say them. Answers open beside the cursor, the
/// outcome first. To show you something, the screen dims, the one thing that
/// matters stays lit and ringed, and a caption sits beside it.
class BuddyLayer extends StatefulWidget {
  const BuddyLayer({
    super.key,
    required this.events,
    required this.cursor,
    this.points,
    this.scale = 1,
    this.alwaysVisible = true,
    this.onDecide,
    this.onAnswer,
    this.onTakeover,
    this.onSelect,
    this.setClickThrough,
    this.origin = Offset.zero,
  });

  /// Top left of this layer on the virtual desktop, in physical pixels (negative when a
  /// monitor sits left of or above the main one). Core's screen positions are relative to it.
  final Offset origin;

  /// Answer an approval from the Yes / No card beside the cursor.
  final Future<void> Function(String approvalId, bool approved)? onDecide;

  /// Answer one of Compii's questions from the card beside the cursor.
  final Future<void> Function(String questionId, String text)? onAnswer;

  /// Say a password / card / code step is finished (outcome "done") or skipped
  /// ("skip"), so Compii carries on.
  final Future<void> Function(String takeoverId, String outcome)? onTakeover;

  /// Do that to the words highlighted when the user tapped Ctrl+Alt (from the card beside the cursor).
  final Future<void> Function(String instruction)? onSelect;

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
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  // Compii drawing on screen like a teacher with a marker (draw_on_screen).
  late final AnimationController _marker = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  List<_Mark> _marks = const [];
  Timer? _marksOff;
  Timer? _hide;
  Timer? _flyBack;

  String state = 'idle';
  String text = '';
  String heard = '';
  double level = 0;
  bool speaking = false;

  // Compii's eyes, straight from Core: the user's switch, and whether it is reading right now.
  // The chip below is only ever lit by Core's own report, so it can't claim a look that didn't happen.
  bool _seeing = false;

  Offset? _cursor; // latest real pointer position
  Offset _pos = Offset.zero; // where the moon's body is drawn
  Offset _center =
      Offset.zero; // the pointer it rides beside (settles with a soft spring)
  bool _haveCenter = false;
  bool _flipX = false; // parked to the pointer's left, because the screen edge is close
  bool _flipY = false; // parked above the pointer, for the same reason
  double _clock = 0; // fixed-step seconds, for breathing and hover
  bool _still =
      false; // reduced motion: a steady moon beside the pointer, no circling

  bool _asking = false;

  final List<Offset> _gesture = []; // paint trail while you hold Ctrl+Alt
  double _gestureFade = 0;
  bool _hidden = false; // Ctrl+Alt+H
  // Motion goes through its own notifier so a moving moon repaints only the few
  // widgets that actually move, instead of rebuilding the whole overlay.
  final ValueNotifier<int> _frame = ValueNotifier(0);

  // Pointing.
  Rect? _target;
  String _targetLabel = '';
  Offset _flyFrom = Offset.zero;
  Offset? _vantage; // where the moon parks to point
  double _aim = 0; // radians, from the moon to the exact target center
  bool _leaving = false; // gliding back into orbit after pointing
  double _returnT = 1;
  Offset _returnFrom = Offset.zero;

  @visibleForTesting
  Offset get buddyPosition => _pos;
  @visibleForTesting
  double get aimAngle => _aim;
  @visibleForTesting
  Rect? get pointingAt => _target;
  @visibleForTesting
  bool get isPointing => _target != null && !_leaving && _fly.value > .92;

  // Asking for permission: a Yes / No card in Compii's corner.
  // Asking a question: the same card with a button per choice.
  String _approvalId = '';
  String _questionId = '';
  String _takeoverId = '';
  List<String> _choices = const [];
  // Words the user had highlighted when they tapped Ctrl+Alt, offered back as taps.
  String _pickedWords = '';
  String _pickedFrom = '';
  int _pickedCount = 0;
  final _card = GlobalKey();
  bool _catching =
      false; // the overlay is taking clicks (mouse over the card, or drawing)

  // Drawing: while you hold Ctrl+Alt, press the mouse button and drag to draw on screen.
  // The overlay takes the mouse only while the keys are held, so nothing underneath gets clicked.
  final List<List<Offset>> _ink = [];
  bool _catchAll = false;
  @visibleForTesting
  int get inkStrokes => _ink.length;
  Timer? _catchAllSafety;

  bool get asking =>
      (state == 'needs_you' &&
          (_approvalId.isNotEmpty || _questionId.isNotEmpty || _takeoverId.isNotEmpty)) ||
      (state == 'selected' && _pickedWords.isNotEmpty);

  bool get talking => state != 'idle';

  @override
  void initState() {
    super.initState();
    _sub = widget.events.listen(onEvent);
    widget.points?.addListener(_onPoint);
    compiiColor.addListener(_recolor);
    // Read the pointer ~60 times a second; redraw only when something moved,
    // so an idle buddy costs next to nothing.
    _follow = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
    // The pointing label shows the item's name once the swoop lands.
    _fly.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.points?.removeListener(_onPoint);
    compiiColor.removeListener(_recolor);
    _frame.dispose();
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

  void _recolor() {
    if (mounted) setState(() {});
  }

  // ---- motion: the moon circles the pointer every frame (cheap: nothing moves but pixels) ----

  int _ticks = 0;
  int _stillTicks = 0;

  static const _engagedStates = {
    'listening',
    'dictating',
    'thinking',
    'needs_you',
    'watching',
    'selected',
  };

  /// The badge's drawn size: a mark you have already read should not grow over your work,
  /// so only a question or a listening turn makes it properly big.
  double get _box => switch (state) {
    'needs_you' || 'listening' || 'dictating' => 34.0,
    'thinking' || 'watching' || 'selected' => 30.0,
    _ => 24.0,
  };

  /// How lit it is: full while Compii is doing something, half when idle, and faint once
  /// your hand has left the mouse for a few seconds.
  double get _dim {
    if (talking || _seeing || _target != null) return 1;
    return _stillTicks > 25 ? .3 : .55;
  }

  /// Where the badge parks: a fixed stand-off to the lower-right of the pointer, which is
  /// the one place that never covers what the pointer itself is on. It circles nothing.
  /// It changes shoulder only when the usual side runs out of room, and returns there as
  /// soon as it clearly can, so it never hops about while you work.
  Offset _anchor(Size screen) {
    final lead = _box * .5 + 13;
    final drop = _box * .5 + 15;
    const margin = 8.0, back = 60.0; // "well clear" before it moves back
    final roomRight = screen.width - _center.dx - lead - margin;
    final roomLeft = _center.dx - lead - margin;
    if (_flipX) {
      if (roomLeft < 0 || roomRight > back) _flipX = false;
    } else if (roomRight < 0) {
      _flipX = true;
    }
    final roomBelow = screen.height - _center.dy - drop - margin;
    final roomAbove = _center.dy - drop - margin;
    if (_flipY) {
      if (roomAbove < 0 || roomBelow > back) _flipY = false;
    } else if (roomBelow < 0) {
      _flipY = true;
    }
    return _center + Offset(_flipX ? -lead : lead, _flipY ? -drop : drop);
  }

  /// The badge never leaves the pointer. What leaves the pointer is Compii's *words*:
  /// the busy state and every answer open as a card in a top corner (_cardLeft), so a
  /// long reply cannot trail across the text you are reading, and the small mark that
  /// says "Compii is here" stays exactly where your attention already is.

  /// Which top corner Compii's card takes: the one furthest from the pointer, so the
  /// answer lands beside empty desktop rather than over the sentence you are looking
  /// at. Top because the taskbar owns the bottom.
  ///
  /// Latched while a card is on screen: one that hops to the other side because you
  /// moved the mouse is worse than one that started on the wrong side.
  bool _cardOnLeft = false;
  bool _cardShown = false;

  /// Where the pointer was when the card opened: the card stays there, beside it,
  /// rather than following the mouse while you read.
  Offset _cardAt = Offset.zero;

  /// The docked card that needs room to be read: Compii's answer, the text lifted from
  /// another app, a question with buttons. These open as a panel in the corner instead
  /// of a bubble beside the badge.
  bool get _roomy => switch (state) {
    'answer' ||
    'note' ||
    'selected' ||
    'setup' ||
    'error' => true,
    'needs_you' => asking,
    _ => false,
  };

  void _tick() {
    _ticks++;
    // Hidden and idle: nothing on screen, so don't animate or poll at all.
    if (_hidden && !_engagedStates.contains(state) && _target == null) return;
    _clock += 1 / 60;
    // When the mouse has been still for a moment, check it 10x a second instead of 60.
    final resting =
        _stillTicks > 30 && _target == null && !_fly.isAnimating && !_leaving;
    if (!_asking && (!resting || _ticks % 6 == 0)) {
      _asking = true;
      widget.cursor().then(
        (p) {
          _asking = false;
          _stillTicks = (_cursor != null && (p - _cursor!).distance < .5)
              ? _stillTicks + 1
              : 0;
          _cursor = p;
        },
        onError: (_) {
          _asking = false;
        },
      );
    }
    final c = _cursor;
    if (c == null) return;
    if (!_haveCenter) {
      _center = c;
      _pos = _anchor(MediaQuery.sizeOf(context));
      _haveCenter = true;
      // The first pointer fix turns the overlay from empty into the moon.
      setState(() {});
    }
    if (_still) {
      _center = c; // reduced motion: the badge keeps its place, nothing glides
    } else {
      // A stiff spring: the ride stays glued to the pointer's shoulder, so it never
      // sweeps across the screen after a jump the way an orbiting mark did.
      final k = 1 - math.exp(-(1 / 60) / .035);
      _center += (c - _center) * k;
    }
    _catchClicksOverCard(c);

    final rest = _anchor(MediaQuery.sizeOf(context));
    final target = _target;
    Offset next;
    var aim = 0.0;
    var clearTarget = false;
    if (target != null && _vantage != null) {
      final end = _vantage!;
      if (_leaving) {
        _returnT = math.min(1, _returnT + (1 / 60) / .5);
        next = Offset.lerp(
          _returnFrom,
          rest,
          Curves.easeInOutCubic.transform(_returnT),
        )!;
        if (_returnT >= 1) clearTarget = true;
      } else if (_fly.value < 1) {
        // A bowed swoop from the orbit to the spot beside the item.
        final t = Curves.easeInOutCubic.transform(_fly.value);
        final v = end - _flyFrom;
        final span = v.distance;
        var normal = span < 1
            ? const Offset(0, -1)
            : Offset(-v.dy, v.dx) / span;
        if (normal.dy > 0) normal = -normal; // always bow upward
        final control = _flyFrom + v * .5 + normal * math.min(90, span * .3);
        final u = 1 - t;
        next = _flyFrom * (u * u) + control * (2 * u * t) + end * (t * t);
      } else {
        // Parked: a tiny hover keeps it alive without drifting off the aim.
        next =
            end +
            Offset(math.sin(_clock * 1.9) * 1.4, math.cos(_clock * 1.5) * 1.1);
      }
      // The eyes look at the exact middle of the item.
      aim = math.atan2(target.center.dy - next.dy, target.center.dx - next.dx);
    } else {
      next = rest;
    }

    var changed = false;
    if (state == 'listening' && !_still) {
      if (_gesture.isNotEmpty && (c - _gesture.last).distance > 300) {
        _gesture.clear(); // a jump, not a gesture
      }
      if (_gesture.isEmpty || (c - _gesture.last).distance > 3) {
        _gesture.add(c);
        if (_gesture.length > 240) _gesture.removeAt(0);
        _gestureFade = 1;
        changed = true;
      }
    } else if (_gestureFade > 0) {
      _gestureFade = math.max(
        0,
        _gestureFade - (_ink.isEmpty ? .02 : .006),
      ); // drawings linger ~3 s
      if (_gestureFade == 0) {
        _gesture.clear();
        _ink.clear();
      }
      changed = true;
    }
    if (clearTarget) {
      setState(() {
        _target = null;
        _vantage = null;
        _leaving = false;
        _pos = rest;
        _aim = 0;
      });
      return;
    }
    if ((next - _pos).distance > .12 || (aim - _aim).abs() > .004) {
      changed = true;
    }
    // Fading down is a change the user sees, so it has to repaint even when nothing moved.
    if (_dim != _shownDim) changed = true;
    _shownDim = _dim;
    _pos = next;
    _aim = aim;
    if (changed) _frame.value++;
  }

  double _shownDim = 1;

  /// Clicks pass through the overlay to your apps, except while the mouse is over a
  /// card of Compii's, so you can answer it, or put the wheel on an answer and read it.
  void _catchClicksOverCard(Offset c) {
    var over = false;
    if (asking || _roomy) {
      final box = _card.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        over = (box.localToGlobal(Offset.zero) & box.size)
            .inflate(6)
            .contains(c);
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
      _catchAllSafety = Timer(
        const Duration(seconds: 30),
        () => _setCatchAll(false),
      );
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

  /// Tap one of Compii's choices (or "you decide") on the card beside the cursor.
  Future<void> _answer(String answer, {String? shown}) async {
    final id = _questionId;
    setState(() {
      _questionId = '';
      _choices = const [];
      state = 'thinking';
      text = shown ?? answer;
    });
    _catching = false;
    await widget.setClickThrough?.call(true);
    await widget.onAnswer?.call(id, answer);
  }

  /// "Done — carry on" (or skip): the secret step was the user's, Compii never saw it.
  Future<void> _finishTakeover(String outcome) async {
    final id = _takeoverId;
    setState(() {
      _takeoverId = '';
      state = 'thinking';
      text = outcome == 'skip' ? 'Skipping that step…' : 'Thanks — carrying on…';
    });
    _catching = false;
    await widget.setClickThrough?.call(true);
    await widget.onTakeover?.call(id, outcome);
  }

  /// Where the moon stands to point: just past the edge of the item that faces
  /// the pointer, so the beam is a short, readable line rather than a cord
  /// crossing the screen. Huge targets (a whole window) get a spot just above
  /// or below the middle, near where the user is looking.
  Offset _parkingSpot(Rect target, Size screen) {
    const edge = 40.0;
    final center = target.center;
    Offset spot;
    if (target.width > 340 || target.height > 260) {
      final x = (_cursor?.dx ?? center.dx).clamp(
        target.left + 24,
        target.right - 24,
      );
      final above = target.top - 36;
      final below = target.bottom + 36;
      final y = above > edge
          ? above
          : (below < screen.height - edge ? below : center.dy);
      spot = Offset(x, y);
    } else {
      var dir = (_cursor ?? center) - center;
      if (dir.distance < 1) dir = const Offset(-1, -1);
      dir /= dir.distance;
      final reach = math.min(
        100.0,
        math.max(target.width, target.height) / 2 + 24,
      );
      spot = center + dir * reach;
    }
    return Offset(
      spot.dx.clamp(edge, math.max(edge, screen.width - edge)),
      spot.dy.clamp(edge, math.max(edge, screen.height - edge)),
    );
  }

  void _onPoint() {
    final p = widget.points?.value;
    if (p == null) return;
    double n(String k) => (p[k] as num).toDouble() / widget.scale;
    final target = Rect.fromLTWH(
      n('x') - widget.origin.dx / widget.scale,
      n('y') - widget.origin.dy / widget.scale,
      n('w'),
      n('h'),
    );
    final vantage = _parkingSpot(target, MediaQuery.sizeOf(context));
    final message = (p['message'] as String?)?.trim() ?? '';
    setState(() {
      _target = target;
      _vantage = vantage;
      _leaving = false;
      _returnT = 1;
      _aim = math.atan2(
        target.center.dy - vantage.dy,
        target.center.dx - vantage.dx,
      );
      _targetLabel = message.isNotEmpty ? message : '${p['name'] ?? ''}';
      _flyFrom = _pos;
    });
    _fly.duration = Duration(
      milliseconds: (380 + (vantage - _flyFrom).distance * .32)
          .clamp(460, 900)
          .round(),
    );
    _fly.forward(from: 0);
    _flyBack?.cancel();
    _flyBack = Timer(const Duration(seconds: 7), _returnToRest);
  }

  /// Glide back to wherever it belongs — the corner if Compii is busy, the pointer's
  /// shoulder if not — instead of snapping there; the ring and beam fade with the
  /// same motion.
  void _returnToRest() {
    if (!mounted || _target == null || _leaving) return;
    setState(() {
      _leaving = true;
      _returnT = 0;
      _returnFrom = _pos;
    });
    _flyBack?.cancel();
  }

  // ---- what Compii is doing ----

  void onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'voice_buddy':
        final s = '${e['state']}';
        setState(() {
          state = s;
          _approvalId = s == 'needs_you' ? '${e['approval_id'] ?? ''}' : '';
          _questionId = s == 'needs_you' ? '${e['question_id'] ?? ''}' : '';
          _takeoverId = s == 'needs_you' ? '${e['takeover_id'] ?? ''}' : '';
          _choices = s == 'needs_you'
              ? [for (final c in (e['choices'] as List? ?? const [])) '$c']
              : const [];
          switch (s) {
            case 'listening':
              text = '';
              heard = '';
              _pickedWords = '';
              _gesture.clear();
            case 'selected':
              text = '${e['text'] ?? ''}';
              _pickedWords = text;
              _pickedFrom = '${e['window'] ?? ''}';
              _pickedCount = (e['words'] as num?)?.toInt() ?? 0;
            case 'watching':
              text = e['text'] != null
                  ? '${e['text']}'
                  : 'Watching — show me, then hold Ctrl+Alt and say “done”';
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
        } else if (s == 'answer' ||
            s == 'setup' ||
            s == 'error' ||
            s == 'selected') {
          // Long enough to read; while Compii is talking it stays (see voice_speaking).
          // The words card lasts longer: reading someone else's paragraph takes time.
          // A research answer in the corner panel is read at your own pace, and the
          // pointer does not have to stay near it, so it gets minutes, not seconds.
          final panel = s == 'answer' && text.length > 320;
          _hide = Timer(
            Duration(
              milliseconds: s == 'selected'
                  ? (9000 + text.length * 60).clamp(9000, 20000)
                  : panel
                  ? (14000 + text.length * 45).clamp(14000, 60000)
                  : (2500 + text.length * 45).clamp(3000, 12000),
            ),
            _closeIfQuiet,
          );
        }
      case 'voice_draw':
        double n(Map m, String k) => (m[k] as num).toDouble() / widget.scale;
        Rect r(Map m) => Rect.fromLTWH(
          n(m, 'x') - widget.origin.dx / widget.scale,
          n(m, 'y') - widget.origin.dy / widget.scale,
          n(m, 'w'),
          n(m, 'h'),
        );
        final shapes = [
          for (final m in (e['shapes'] as List? ?? const []).cast<Map>())
            _Mark(
              '${m['kind']}',
              r(m),
              m['from'] is Map ? r(m['from'] as Map) : null,
            ),
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
      case 'voice_sight':
        setState(() => _seeing = e['looking'] == true);
      case 'voice_partial' when state == 'listening' || state == 'dictating':
        setState(() => text = '${e['text']}');
      case 'voice_level' when state == 'listening' || state == 'dictating':
        level = (e['level'] as num).toDouble();
      case 'voice_caption'
          when state == 'answer' || state == 'thinking' || state == 'needs_you':
        setState(() => text = '${e['text']}');
      case 'voice_speaking':
        setState(() => speaking = e['on'] == true);
        if (e['on'] != true && state == 'answer') {
          _hide?.cancel();
          _hide = Timer(
            const Duration(seconds: 2),
            _goIdle,
          ); // closes soon after it stops talking
        }
    }
  }

  /// The timer that closes an answer: it keeps going while the mouse is on the card,
  /// because that is someone reading it, and while Compii is still talking.
  void _closeIfQuiet() {
    if (speaking) return; // voice_speaking(off) will close it
    if (_catching && mounted) {
      // The mouse is on the card: they are reading it or about to tap, not finished.
      _hide = Timer(const Duration(seconds: 6), _closeIfQuiet);
      return;
    }
    _goIdle();
  }

  void _goIdle() {
    if (!mounted) return;
    setState(() {
      state = 'idle';
      text = '';
      _pickedWords = '';
    });
  }

  /// Compii's own colour, except when the state has to be told apart at a glance:
  /// amber when it needs you, red when something went wrong or it is recording you.
  Color get _tint => switch (state) {
    'needs_you' => const Color(0xFFFF9B3D),
    'watching' || 'error' || 'setup' => const Color(0xFFFF5A4E),
    _ => compiiColor.value,
  };

  /// The words on a card's header: what Compii is doing, in one or two words.
  String get _title => switch (state) {
    _ when _target != null => 'Showing you',
    'listening' => 'Listening',
    'dictating' => 'Dictating',
    'thinking' => 'Working',
    'watching' => 'Watching you',
    'needs_you' => _takeoverId.isNotEmpty ? 'Your turn' : 'Needs you',
    'selected' => 'Your selection',
    'error' => 'Problem',
    'setup' => 'Setup',
    _ => 'Compii',
  };

  /// Where the eyes look: back at your pointer, or at what they are showing you.
  Offset get _gaze {
    if (_target != null) return Offset(math.cos(_aim), math.sin(_aim));
    final d = _center - _pos;
    final n = d.distance;
    return n < 1 ? Offset.zero : d / n;
  }

  /// The header every card wears: the eyes, in the state's mood, and the title.
  Widget _header() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CardEyes(mood: moodForBuddy(state, speaking: speaking), color: _tint, size: 14),
        const SizedBox(width: 8),
        Text(
          _title,
          style: TextStyle(
            color: Color.lerp(_tint, Colors.white, .55),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: .2,
            decoration: TextDecoration.none,
            fontFamily: 'Segoe UI Variable Text',
          ),
        ),
      ],
    ),
  );

  /// Showing you something: the screen dims and the item stays lit, ringed.
  Widget _spotlightLayer() => Positioned.fill(
    child: IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([_fly, _pulse]),
        builder: (context, _) => CustomPaint(
          painter: SpotlightPainter(
            target: _target!,
            color: _tint,
            progress: _fly.value,
            pulse: _pulse.value,
            fade: _leaving ? 1 - _returnT : 1,
          ),
        ),
      ),
    ),
  );

  /// The outcome first: the answer's first sentence is the headline, the rest is
  /// the detail under it.
  (String, String) _split(String line) {
    final m = RegExp(r'^(.{12,200}?[.!?])(\s+)(.+)$', dotAll: true).firstMatch(line.trim());
    if (m == null) return (line.trim(), '');
    return (m.group(1)!, m.group(3)!.trim());
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _still = still;
    if (!still &&
        (talking || _seeing || _target != null) &&
        !_pulse.isAnimating) {
      _pulse.repeat();
    }
    if ((still || !(talking || _seeing || _target != null)) &&
        _pulse.isAnimating) {
      _pulse.stop();
    }
    // Hidden (Ctrl+Alt+H): only appears while you're actually talking to it.
    final engaged = _engagedStates.contains(state) || _target != null;
    // Even with the buddy hidden, a look at the screen still shows: hiding Compii is not hiding
    // the fact that it is reading.
    final bare =
        _cursor == null ||
        (_hidden && !engaged) ||
        (!widget.alwaysVisible && !talking && _target == null);
    if (bare && !_seeing) return const SizedBox.expand();

    final screen = MediaQuery.sizeOf(context);
    if (bare) {
      return IgnorePointer(
        child: Stack(
          children: [
            if (_seeing) Positioned(right: 14, top: 14, child: _sightChip()),
          ],
        ),
      );
    }
    final listening = state == 'listening' || state == 'dictating';
    final watching = state == 'watching';
    final thinking = state == 'thinking';
    final arrived = _target != null && _fly.value > .95;
    final (String line, bool muted) = switch (state) {
      _ when arrived && _targetLabel.isNotEmpty => (_targetLabel, false),
      'thinking' => text.isNotEmpty ? (text, true) : (heard, true),
      'idle' => ('', false),
      _ => (text, false),
    };
    final showLabel = line.isNotEmpty || listening || thinking || watching;
    final roomy = _roomy && _target == null;
    if (roomy != _cardShown) {
      _cardShown = roomy;
      if (roomy) {
        _cardOnLeft = _center.dx > screen.width * .5;
        _cardAt = _center;
      }
    }
    final onLeft = _cardOnLeft;
    final body = TextStyle(
      color: muted ? const Color(0xB3FFFFFF) : const Color(0xF2FFFFFF),
      fontSize: listening ? 16 : 14,
      height: 1.45,
      letterSpacing: .1,
      fontWeight: FontWeight.w500,
      decoration: TextDecoration.none,
      fontFamily: 'Segoe UI Variable Text',
    );
    // A corner panel holds paragraphs, so it is wide, and shows as many lines as the
    // top of the screen has room for instead of eight lines and a shrug.
    final panelWidth = (roomy ? 440.0 : 320.0) - 32;
    final panelLines = ((screen.height * .5 - 90) / 21).floor().clamp(5, 36);
    final cutOff =
        roomy && line.isNotEmpty && _losesLines(line, body, panelLines, panelWidth);
    // Built once per state change; the moving frame only repositions it, so its
    // text never re-lays-out and a button under it never loses its state.
    final label = showLabel
        ? _GlassLabel(
            key: _card,
            tint: _tint,
            maxWidth: roomy ? 440 : 320,
            roomy: roomy || asking,
            header: _header(),
            child: asking && state == 'selected'
                ? _selectionCard(line)
                : asking
                ? _askCard(line)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: line.isEmpty
                                ? _Shimmer(
                                    text: state == 'dictating'
                                        ? 'Say it, and it types where your cursor is'
                                        : (listening ? 'Say what you need' : 'On it'),
                                    t: _pulse,
                                  )
                                : roomy && !listening
                                ? Builder(
                                    builder: (context) {
                                      final (head, rest) = _split(line);
                                      return Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            head,
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                            style: body.copyWith(
                                              fontSize: 17,
                                              height: 1.3,
                                              fontWeight: FontWeight.w600,
                                              fontFamily: 'Segoe UI Variable Display',
                                            ),
                                          ),
                                          if (rest.isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Text(
                                              rest,
                                              maxLines: math.max(2, panelLines - 3),
                                              overflow: TextOverflow.ellipsis,
                                              style: body.copyWith(
                                                color: const Color(0xC7FFFFFF),
                                                fontWeight: FontWeight.w400,
                                              ),
                                            ),
                                          ],
                                        ],
                                      );
                                    },
                                  )
                                : Text(
                                    line,
                                    maxLines: roomy ? panelLines : 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: body,
                                  ),
                          ),
                          if (listening) ...[
                            const SizedBox(width: 10),
                            AnimatedBuilder(
                              animation: _pulse,
                              builder: (context, _) => CustomPaint(
                                size: const Size(20, 18),
                                painter: _WavePainter(_pulse.value, level, _tint),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (listening)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Let go of Ctrl+Alt to send',
                            style: TextStyle(
                              color: Color(0x8CFFFFFF),
                              fontSize: 11.5,
                              decoration: TextDecoration.none,
                              fontFamily: 'Segoe UI Variable Text',
                            ),
                          ),
                        ),
                      if (roomy && !asking && line.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _Pill(
                                label: 'Copy',
                                tint: _tint,
                                onTap: () => Clipboard.setData(ClipboardData(text: line)),
                              ),
                              _Pill(
                                label: 'Dismiss',
                                tint: _tint,
                                onTap: () {
                                  _hide?.cancel();
                                  _goIdle();
                                },
                              ),
                            ],
                          ),
                        ),
                      if (cutOff)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'The full answer is in Compii',
                            style: TextStyle(
                              color: Color(0x8CFFFFFF),
                              fontSize: 10.5,
                              letterSpacing: .1,
                              decoration: TextDecoration.none,
                              fontFamily: 'Segoe UI Variable Text',
                            ),
                          ),
                        ),
                    ],
                  ),
          )
        : null;

    return MouseRegion(
      cursor: listening ? SystemMouseCursors.precise : MouseCursor.defer,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: listening
            ? (e) => setState(() => _ink.add([e.localPosition]))
            : null,
        onPointerMove: listening
            ? (e) {
                if (e.down && _ink.isNotEmpty) {
                  setState(() => _ink.last.add(e.localPosition));
                }
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
                      builder: (context, _) => CustomPaint(
                        painter: _MarkerPainter(_marks, _marker.value),
                      ),
                    ),
                  ),
                ),
              if (_seeing) Positioned(right: 14, top: 14, child: _sightChip()),
              Positioned.fill(
                child: ValueListenableBuilder<int>(
                  valueListenable: _frame,
                  builder: (context, _, _) {
                    // While it points at something the label sits clear of the item,
                    // above it when there is room, so it never hides what is being
                    // pointed at. At every other moment the card is in Compii's corner.
                    final pointingTarget = _target;
                    // The card hangs off the badge, not off the pointer: a caption that
                    // sits where the cursor is hides the very line you are reading.
                    final at = _pos;
                    final flipX = at.dx + 330 > screen.width;
                    // A bubble is short; it flips when the badge is near the bottom.
                    final flipY = at.dy + 90 > screen.height;
                    final labelLeft = pointingTarget == null
                        ? 0.0
                        : (pointingTarget.left - 6)
                              .clamp(8.0, math.max(8.0, screen.width - 298))
                              .toDouble();
                    final labelTop = pointingTarget == null
                        ? 0.0
                        : (pointingTarget.top > 130
                                  ? pointingTarget.top - 78
                                  : pointingTarget.bottom + 12)
                              .clamp(8.0, math.max(8.0, screen.height - 60))
                              .toDouble();
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Ink and the listening gesture move with the pointer,
                        // so they belong to the fast layer too.
                        for (final stroke in _ink)
                          if (stroke.length > 1)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _InkPainter(
                                    List.of(stroke),
                                    _tint,
                                    listening ? 1 : _gestureFade,
                                  ),
                                ),
                              ),
                            ),
                        if (_gesture.length > 1 && _ink.isEmpty)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _TrailPainter(
                                  List.of(_gesture),
                                  _tint,
                                  _gestureFade,
                                ),
                              ),
                            ),
                          ),
                        if (_target != null) _spotlightLayer(),
                        if ((listening || thinking || watching) && _target == null)
                          Positioned(
                            left: _center.dx - 40,
                            top: _center.dy - 40,
                            child: IgnorePointer(
                              child: RepaintBoundary(
                                child: AnimatedBuilder(
                                  animation: _pulse,
                                  builder: (context, _) => CustomPaint(
                                    size: const Size(80, 80),
                                    painter: CursorRingPainter(
                                      color: watching ? _tint : compiiColor.value,
                                      t: _still ? .2 : _pulse.value,
                                      level: listening ? level : 0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned(
                          left: _pos.dx - 22,
                          top: _pos.dy - 22,
                          child: IgnorePointer(
                            child: RepaintBoundary(
                              child: AnimatedBuilder(
                                animation: _pulse,
                                builder: (context, _) => CustomPaint(
                                  size: const Size(44, 44),
                                  painter: CursorMarkPainter(
                                    mood: moodForBuddy(state, speaking: speaking),
                                    color: _tint,
                                    t: _still ? .2 : _pulse.value,
                                    engaged: talking || _target != null,
                                    level: listening ? level : 0,
                                    gaze: _gaze,
                                    fade: _dim * (_leaving ? 1 - _returnT : 1),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (label != null)
                          if (roomy)
                            // Compii's card opens at the top of the screen, in the corner
                            // away from your pointer — never over what you are reading, and
                            // never where the taskbar is. A question you have to answer
                            // takes the click itself; a card you are reading closes when
                            // you tap it.
                            Positioned(
                              left: onLeft
                                  ? null
                                  : (_cardAt.dx + 28).clamp(12.0, math.max(12.0, screen.width - 452)),
                              right: onLeft
                                  ? (screen.width - _cardAt.dx + 28).clamp(12.0, math.max(12.0, screen.width - 452))
                                  : null,
                              top: _cardAt.dy < screen.height * .55
                                  ? (_cardAt.dy + 18).clamp(12.0, math.max(12.0, screen.height - 160))
                                  : null,
                              bottom: _cardAt.dy < screen.height * .55
                                  ? null
                                  : (screen.height - _cardAt.dy + 18).clamp(12.0, math.max(12.0, screen.height - 160)),
                              child: label,
                            )
                          else
                            Positioned(
                              left: pointingTarget != null
                                  ? labelLeft
                                  : (flipX ? null : at.dx + 16),
                              right: pointingTarget != null
                                  ? null
                                  : (flipX ? screen.width - at.dx + 16 : null),
                              top: pointingTarget != null
                                  ? labelTop
                                  : (flipY ? null : at.dy - 2),
                              bottom: pointingTarget != null
                                  ? null
                                  : (flipY ? screen.height - at.dy - 2 : null),
                              child: label,
                            ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The corner light: on while Core says it is reading the screen, off the moment it stops.
  Widget _sightChip() => IgnorePointer(
    child: AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => _GlassLabel(
        tint: compiiColor.value,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: compiiColor.value,
                boxShadow: [
                  BoxShadow(
                    color: compiiColor.value.withValues(alpha: .25 + .45 * _pulse.value),
                    blurRadius: 5 + 7 * _pulse.value,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 9),
            const Text(
              'Compii is looking at your screen',
              style: TextStyle(
                color: Color(0xF2FFFFFF),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: .2,
                decoration: TextDecoration.none,
                fontFamily: 'Segoe UI Variable Text',
              ),
            ),
          ],
        ),
      ),
    ),
  );

  static const _youDecide =
      'I’d rather you decide — use your best judgement and tell me what you chose.';

  /// What a tap on the words card asks for, and the words Compii is told.
  static const _wordTaps = [
    ('Explain', 'Explain this in plain words'),
    ('Summarise', 'Summarise this'),
    ('Translate', 'Translate this'),
    ('Look it up', 'Look this up: what is it, and why does it matter here?'),
  ];

  /// Tap one: work on the highlighted words. Never sent if there are no words in front of Compii.
  Future<void> _doWithWords(String instruction) async {
    setState(() {
      _pickedWords = '';
      state = 'thinking';
      text = instruction;
    });
    _catching = false;
    await widget.setClickThrough?.call(true);
    await widget.onSelect?.call(instruction);
  }

  /// The words they had highlighted, and taps for what to do with them — for when speaking
  /// isn't the easier move. Nothing is copied: these came from the app's own selection.
  Widget _selectionCard(String line) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '“$line”',
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xF2FFFFFF),
          fontSize: 13,
          height: 1.42,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
          fontFamily: 'Segoe UI Variable Text',
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _pickedCount > 0
            ? '$_pickedCount words selected'
                  '${_pickedFrom.isEmpty ? '' : ' in $_pickedFrom'} — tap what to do'
            : 'Tap what to do with these',
        style: const TextStyle(
          color: Color(0x99FFFFFF),
          fontSize: 11.5,
          height: 1.4,
          decoration: TextDecoration.none,
          fontFamily: 'Segoe UI Variable Text',
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (i, tap) in _wordTaps.indexed)
            _Pill(
              label: tap.$1,
              primary: i == 0,
              tint: _tint,
              onTap: () => _doWithWords(tap.$2),
            ),
        ],
      ),
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          'Or hold Ctrl+Alt and just say it.',
          style: TextStyle(
            color: Color(0x8CFFFFFF),
            fontSize: 11.5,
            height: 1.4,
            decoration: TextDecoration.none,
            fontFamily: 'Segoe UI Variable Text',
          ),
        ),
      ),
    ],
  );

  Widget _askCard(String line) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        line.isEmpty
            ? (_takeoverId.isNotEmpty
                  ? 'A password or code needs your hands.'
                  : _questionId.isNotEmpty
                  ? 'Compii needs to know something.'
                  : 'May I go ahead?')
            : line,
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xF2FFFFFF),
          fontSize: 13,
          height: 1.42,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.none,
          fontFamily: 'Segoe UI Variable Text',
        ),
      ),
      const SizedBox(height: 8),
      if (_takeoverId.isNotEmpty)
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Pill(
              label: 'Done — carry on',
              primary: true,
              tint: _tint,
              onTap: () => _finishTakeover('done'),
            ),
            _Pill(
              label: 'Skip',
              tint: _tint,
              onTap: () => _finishTakeover('skip'),
            ),
          ],
        )
      else if (_questionId.isEmpty)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Pill(
              label: 'Yes',
              primary: true,
              tint: _tint,
              onTap: () => _decide(true),
            ),
            const SizedBox(width: 6),
            _Pill(label: 'No', tint: _tint, onTap: () => _decide(false)),
          ],
        )
      else
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (i, choice) in _choices.indexed)
              _Pill(
                label: choice,
                primary: i == 0,
                tint: _tint,
                onTap: () => _answer(choice),
              ),
            _Pill(
              label: 'You decide',
              tint: _tint,
              onTap: () => _answer(_youDecide, shown: 'You decide'),
            ),
          ],
        ),
      if (_takeoverId.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            'Only you type it — Compii never sees or keeps it.',
            style: TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 11.5,
              height: 1.4,
              decoration: TextDecoration.none,
              fontFamily: 'Segoe UI Variable Text',
            ),
          ),
        ),
      if (_questionId.isNotEmpty && _choices.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            'Or type it in Compii.',
            style: TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 11.5,
              height: 1.4,
              decoration: TextDecoration.none,
              fontFamily: 'Segoe UI Variable Text',
            ),
          ),
        ),
    ],
  );
}

/// A small button on the permission card.
class _Pill extends StatefulWidget {
  const _Pill({
    required this.label,
    required this.tint,
    required this.onTap,
    this.primary = false,
  });
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
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: widget.primary
                ? Color(_hover ? 0xFFFFFFFF : 0xFFF2F2F5)
                : Color(_hover ? 0x2EFFFFFF : 0x17FFFFFF),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.primary
                    ? const Color(0xFF0A0A0D)
                    : const Color(0xF2FFFFFF),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
                fontFamily: 'Segoe UI Variable Text',
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Does this text actually lose lines at the panel's size? Measured, not guessed: the
/// line about the rest of the answer only appears when there really is a rest.
bool _losesLines(String text, TextStyle style, int maxLines, double width) {
  final p = TextPainter(textDirection: TextDirection.ltr, maxLines: maxLines)
    ..text = TextSpan(text: text, style: style)
    ..layout(maxWidth: width);
  return p.didExceedMaxLines;
}

/// Compii's card: black glass with a hairline edge, the eyes and a title on top.
/// Roomy when it is meant to be read or answered, compact when it is a glance.
class _GlassLabel extends StatelessWidget {
  const _GlassLabel({
    super.key,
    required this.child,
    required this.tint,
    this.maxWidth = 320,
    this.roomy = false,
    this.header,
  });
  final Widget child;
  final Color tint;
  final double maxWidth;
  final bool roomy;
  final Widget? header;
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(roomy ? 22 : 18);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: [
            const BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 18)),
            BoxShadow(color: tint.withValues(alpha: .16), blurRadius: 30, spreadRadius: -10),
          ],
        ),
        child: ClipRRect(
          borderRadius: r,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: roomy
                  ? const EdgeInsets.fromLTRB(18, 14, 18, 16)
                  : const EdgeInsets.fromLTRB(14, 10, 14, 12),
              decoration: BoxDecoration(
                borderRadius: r,
                color: const Color(0xEB08080B),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [?header, child],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
        stops: [
          (t.value - .3).clamp(0.0, 1.0),
          t.value,
          (t.value + .3).clamp(0.0, 1.0),
        ],
      ).createShader(r),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: .3,
          decoration: TextDecoration.none,
          fontFamily: 'Segoe UI Variable Text',
        ),
      ),
    ),
  );
}

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
        drawn.addPath(
          metric.extractPath(0, math.min(left, metric.length)),
          Offset.zero,
        );
        left -= metric.length;
      }
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(
        drawn,
        pen
          ..strokeWidth = 11
          ..color = ink.withValues(alpha: .22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawPath(
        drawn,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 4
          ..color = ink,
      );
    }
  }

  Path _path(_Mark m, Size size) {
    final r = m.rect;
    switch (m.kind) {
      case 'underline':
        return Path()
          ..moveTo(r.left - 4, r.bottom + 5)
          ..quadraticBezierTo(
            r.center.dx,
            r.bottom + 9,
            r.right + 6,
            r.bottom + 3,
          );
      case 'box':
        return Path()..addRRect(
          RRect.fromRectAndRadius(r.inflate(7), const Radius.circular(8)),
        );
      case 'arrow':
        // Edge to edge: from the side of the first item that faces the second.
        final f = m.from;
        final vertical =
            f != null &&
            (r.center.dy - f.center.dy).abs() >
                (r.center.dx - f.center.dx).abs();
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
        final mid = Offset(
          (start.dx + end.dx) / 2,
          math.min(start.dy, end.dy) - 30,
        );
        final dir = end - mid;
        final a = math.atan2(dir.dy, dir.dx);
        Offset head(double turn) =>
            end - Offset(math.cos(a + turn), math.sin(a + turn)) * 16;
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
          final pt = Offset(
            c.dx + math.cos(th) * rx * wobble,
            c.dy + math.sin(th) * ry * wobble,
          );
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
    canvas.drawPath(
      path,
      pen
        ..strokeWidth = 12
        ..color = color.withValues(alpha: .25 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 4.5
        ..color = color.withValues(alpha: .95 * fade),
    );
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
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: .18 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: .75 * fade),
    );
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
      final h =
          (s.height *
                  (.3 +
                      .7 *
                          level.clamp(0.1, 1.0) *
                          (.5 +
                              .5 * math.sin(t * math.pi * 8 + i * 1.7).abs())))
              .clamp(3.0, s.height);
      canvas.drawLine(
        Offset(x, s.height / 2 - h / 2),
        Offset(x, s.height / 2 + h / 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) => true;
}
