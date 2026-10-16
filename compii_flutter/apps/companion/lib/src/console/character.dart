import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the companion is doing right now. Every character design must show each one.
enum Mood { idle, listening, thinking, acting, speaking, waiting, happy, problem, offline }

String moodLabel(Mood mood) => switch (mood) {
  Mood.idle => 'Ready',
  Mood.listening => 'Listening',
  Mood.speaking => 'Speaking',
  Mood.thinking => 'Thinking',
  Mood.acting => 'Working',
  Mood.waiting => 'Needs you',
  Mood.happy => 'Done',
  Mood.problem => 'Problem',
  Mood.offline => 'Offline',
};

/// Compii is an Orbling: an invented creature that carries its own little
/// orbit. Each golden mote circling it is a job it is working on, so you can
/// see at a glance how busy it is. Its mitten hands float free of its body
/// so they can go and do things.
class CharacterSlot extends StatelessWidget {
  const CharacterSlot({
    super.key,
    required this.mood,
    this.jobs = 0,
    this.size = 260,
  });
  final Mood mood;

  /// Tasks running right now; each one is drawn as a mote.
  final int jobs;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Compii, ${moodLabel(mood)}${jobs > 1 ? ', $jobs tasks running' : ''}',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: Orbling(mood: mood, jobs: jobs),
    ),
  );
}

class OrblingPalette {
  static const body = Color(0xFF4B3FE0);
  static const bodyDeep = Color(0xFF3226B8);
  static const bodyLight = Color(0xFF7468F0);
  static const mitten = Color(0xFFFFF1DA);
  static const mittenShade = Color(0xFFF1D9B5);
  static const ink = Color(0xFF15122E);
  static const cheek = Color(0xFFFF8FA3);
  static const gold = Color(0xFFFFC94D);

  static Color mote(Mood mood) => switch (mood) {
    Mood.thinking => const Color(0xFF7CC8FF),
    Mood.waiting => const Color(0xFFFFA928),
    Mood.problem => const Color(0xFFFF6B6B),
    Mood.offline => const Color(0xFFB8BCC6),
    Mood.listening => const Color(0xFF5CE1E6),
    _ => gold,
  };
}

class Orbling extends StatefulWidget {
  const Orbling({
    super.key,
    required this.mood,
    this.jobs = 0,
    this.animate = true,
    this.phase = .25,
    this.face = false,
    this.reach,
    this.level = 0,
    this.followPointer = true,
  });
  final Mood mood;
  final int jobs;
  final bool animate;

  /// Microphone level 0..1 while listening; makes the motes pulse with your voice.
  final double level;

  /// Eyes follow the mouse pointer when the character is free to look around.
  final bool followPointer;

  /// Close-up: the face fills the whole area (the phone's Face View).
  final bool face;

  /// Where the free right mitten reaches to, in units of this widget's size
  /// (may be outside 0..1). Used by the desktop overlay to point at things.
  final Offset? reach;

  /// Animation phase used when not animating (for stills and tests).
  final double phase;
  @override
  State<Orbling> createState() => _OrblingState();
}

class _OrblingState extends State<Orbling> with TickerProviderStateMixin {
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  // Eases between poses so hands and face glide rather than jump.
  late final AnimationController blend = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );
  late Mood previous = widget.mood;

  @override
  void didUpdateWidget(covariant Orbling old) {
    super.didUpdateWidget(old);
    if (old.mood != widget.mood) {
      previous = old.mood;
      blend.forward(from: 0);
    }
  }

  @override
  void dispose() {
    clock.dispose();
    blend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = !widget.animate || MediaQuery.of(context).disableAnimations;
    if (still) {
      clock.stop();
    } else if (!clock.isAnimating) {
      clock.repeat();
    }
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([clock, blend, if (widget.followPointer) pointer]),
        builder: (context, _) {
          final b = Curves.easeOutBack.transform(blend.value).clamp(0.0, 1.08);
          final t = still ? widget.phase : clock.value;
          final look = widget.followPointer ? _look(context) : null;
          return CustomPaint(
            size: Size.infinite,
            painter: widget.face
                ? OrblingFacePainter(mood: widget.mood, previous: previous, blend: b, jobs: widget.jobs, t: t, still: still, look: look, level: widget.level)
                : OrblingPainter(mood: widget.mood, previous: previous, blend: b, jobs: widget.jobs, t: t, still: still, reach: widget.reach, look: look, level: widget.level),
          );
        },
      ),
    );
  }

  /// Direction from the character to the mouse, -1..1 on each axis.
  Offset? _look(BuildContext context) {
    final p = pointer.value;
    final box = context.findRenderObject();
    if (p == null || box is! RenderBox || !box.hasSize || !box.attached) return null;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    final d = p - centre;
    final reach = box.size.shortestSide * 2.5;
    return Offset((d.dx / reach).clamp(-1.0, 1.0), (d.dy / reach).clamp(-1.0, 1.0));
  }
}

/// Last known mouse position in global coordinates, fed by the app root.
final pointer = ValueNotifier<Offset?>(null);

/// Moods where the character is free to look at you (and your pointer).
bool _canLook(Mood m) => m == Mood.idle || m == Mood.listening || m == Mood.speaking || m == Mood.waiting;

/// Pose = where everything sits for a mood, in unit coordinates.
class _Pose {
  const _Pose({
    required this.left,
    required this.right,
    required this.gaze,
    required this.brow,
    required this.squash,
    this.leftTurn = 0,
    this.rightTurn = 0,
  });
  final Offset left;
  final Offset right;
  final Offset gaze; // -1..1
  final double brow; // + raised/worried inner, - focused
  final double squash; // + wider/shorter
  final double leftTurn;
  final double rightTurn;

  static _Pose of(Mood mood) => switch (mood) {
    Mood.idle => const _Pose(left: Offset(.19, .71), right: Offset(.81, .71), gaze: Offset(0, .1), brow: 0, squash: 0),
    // Mittens cupped by its sides, leaning in to hear you.
    Mood.listening => const _Pose(left: Offset(.15, .56), right: Offset(.85, .56), gaze: Offset(0, .05), brow: .35, squash: -.04, leftTurn: .5, rightTurn: -.5),
    // One mitten gestures while it talks.
    Mood.speaking => const _Pose(left: Offset(.19, .72), right: Offset(.84, .6), gaze: Offset(0, .1), brow: .15, squash: 0, rightTurn: -.35),
    Mood.thinking => const _Pose(left: Offset(.18, .72), right: Offset(.63, .695), gaze: Offset(-.55, -.7), brow: .25, squash: -.02, rightTurn: -.6),
    Mood.acting => const _Pose(left: Offset(.37, .775), right: Offset(.63, .775), gaze: Offset(0, .8), brow: -.35, squash: .015, leftTurn: -.25, rightTurn: .25),
    Mood.waiting => const _Pose(left: Offset(.18, .71), right: Offset(.84, .44), gaze: Offset(0, .05), brow: .45, squash: -.03, rightTurn: -.4),
    Mood.happy => const _Pose(left: Offset(.15, .42), right: Offset(.85, .42), gaze: Offset.zero, brow: .3, squash: -.05, leftTurn: .5, rightTurn: -.5),
    Mood.problem => const _Pose(left: Offset(.2, .72), right: Offset(.67, .3), gaze: Offset(-.2, -.2), brow: .8, squash: .02, rightTurn: -1.1),
    Mood.offline => const _Pose(left: Offset(.31, .8), right: Offset(.69, .8), gaze: Offset.zero, brow: 0, squash: .08),
  };

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(
    left: Offset.lerp(a.left, b.left, t)!,
    right: Offset.lerp(a.right, b.right, t)!,
    gaze: Offset.lerp(a.gaze, b.gaze, t)!,
    brow: a.brow + (b.brow - a.brow) * t,
    squash: a.squash + (b.squash - a.squash) * t,
    leftTurn: a.leftTurn + (b.leftTurn - a.leftTurn) * t,
    rightTurn: a.rightTurn + (b.rightTurn - a.rightTurn) * t,
  );
}

class OrblingPainter extends CustomPainter {
  OrblingPainter({
    required this.mood,
    required this.previous,
    required this.blend,
    required this.jobs,
    required this.t,
    this.still = false,
    this.reach,
    this.look,
    this.level = 0,
  });
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;
  final bool still;
  final Offset? reach;
  final Offset? look;
  final double level;

  Offset _gaze(_Pose pose) => look != null && _canLook(mood) ? look! : pose.gaze;

  double get _wave => math.sin(t * 2 * math.pi);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    canvas.scale(s);
    final pose = _Pose.lerp(_Pose.of(previous), _Pose.of(mood), blend);
    final calm = mood == Mood.offline;
    final hover = calm ? 0.0 : _wave * .012;
    final breathe = calm ? math.sin(t * 2 * math.pi) * .01 : _wave * .015;

    // Ground shadow shrinks as it floats up.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.5, .88), width: .46 - hover * 2, height: .04),
      Paint()..color = OrblingPalette.ink.withValues(alpha: .1),
    );

    final motes = _motes();
    for (final m in motes.where((m) => m.behind)) {
      _drawMote(canvas, m);
    }

    canvas.save();
    canvas.translate(0, -hover);
    // Squash and stretch around the base.
    canvas.translate(.5, .84);
    canvas.scale(1 + pose.squash + breathe * .5, 1 - pose.squash - breathe * .5);
    canvas.translate(-.5, -.84);
    _drawBody(canvas);
    _drawFace(canvas, pose);
    canvas.restore();

    _drawMitten(canvas, pose.left + Offset(0, -hover + _handBob(left: true)), pose.leftTurn, mirror: false);
    final target = reach;
    if (target == null) {
      _drawMitten(canvas, pose.right + Offset(0, -hover + _handBob(left: false)), pose.rightTurn, mirror: true);
    } else {
      // Free mitten flies out and points: fingers toward the target.
      final from = const Offset(.62, .62);
      final dir = target - from;
      final tip = target - dir / dir.distance * .1;
      canvas.save();
      canvas.translate(tip.dx, tip.dy);
      canvas.scale(1.5);
      canvas.translate(-tip.dx, -tip.dy);
      _drawMitten(canvas, tip, math.atan2(dir.dy, dir.dx) + math.pi / 2, mirror: true);
      canvas.restore();
    }

    for (final m in motes.where((m) => !m.behind)) {
      _drawMote(canvas, m);
    }
    _drawExtras(canvas);
  }

  double _handBob({required bool left}) => switch (mood) {
    // Alternating taps, like typing.
    Mood.acting => math.max(0, math.sin(t * 2 * math.pi * 6 + (left ? 0 : math.pi))) * .025,
    Mood.waiting when !left => math.sin(t * 2 * math.pi * 3) * .015,
    Mood.happy => -math.max(0, math.sin(t * 2 * math.pi * 2)) * .02,
    Mood.offline => 0,
    _ => math.sin(t * 2 * math.pi + (left ? 0 : 1.3)) * .008,
  };

  Path _bodyPath() => Path()
    ..moveTo(.29, .82)
    ..quadraticBezierTo(.5, .865, .71, .82)
    ..cubicTo(.81, .78, .82, .6, .72, .45)
    ..cubicTo(.64, .33, .57, .275, .5, .275)
    ..cubicTo(.43, .275, .36, .33, .28, .45)
    ..cubicTo(.18, .6, .19, .78, .29, .82)
    ..close();

  void _drawBody(Canvas canvas) {
    final body = _bodyPath();
    final dim = mood == Mood.offline;
    for (final x in [.4, .6]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, .845), width: .1, height: .06),
        Paint()..color = dim ? const Color(0xFF524B9C) : OrblingPalette.bodyDeep,
      );
    }
    canvas.drawPath(body, Paint()..color = dim ? const Color(0xFF6A63B8) : OrblingPalette.body);
    // Soft underside for volume.
    canvas.save();
    canvas.clipPath(body);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.56, .88), width: .7, height: .3),
      Paint()..color = (dim ? const Color(0xFF524B9C) : OrblingPalette.bodyDeep).withValues(alpha: .55),
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.41, .41), width: .16, height: .09),
      Paint()..color = OrblingPalette.bodyLight.withValues(alpha: .7),
    );
    canvas.restore();
    // The curl: its signature silhouette.
    canvas.drawPath(
      Path()
        ..moveTo(.5, .285)
        ..cubicTo(.49, .2, .6, .16, .615, .225)
        ..cubicTo(.625, .27, .565, .275, .57, .235),
      Paint()
        ..color = dim ? const Color(0xFF6A63B8) : OrblingPalette.body
        ..style = PaintingStyle.stroke
        ..strokeWidth = .04
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawFace(Canvas canvas, _Pose pose) {
    final ink = Paint()..color = OrblingPalette.ink;
    final stroke = Paint()
      ..color = OrblingPalette.ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = .016;

    // Cheeks.
    for (final x in [.355, .645]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, .645), width: .07, height: .034),
        Paint()..color = OrblingPalette.cheek.withValues(alpha: mood == Mood.happy ? .85 : .5),
      );
    }

    final blink = mood == Mood.idle && !still && t > .62 && t < .645;
    for (final (x, side) in [(.405, -1.0), (.595, 1.0)]) {
      final c = Offset(x, .555);
      if (mood == Mood.happy) {
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - .035, c.dy + .01)
            ..quadraticBezierTo(c.dx, c.dy - .045, c.dx + .035, c.dy + .01),
          stroke..strokeWidth = .019,
        );
      } else if (mood == Mood.offline || blink) {
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - .032, c.dy)
            ..quadraticBezierTo(c.dx, c.dy + .022, c.dx + .032, c.dy),
          stroke..strokeWidth = .016,
        );
      } else {
        final w = .1, h = mood == Mood.acting ? .115 : .14;
        canvas.drawOval(Rect.fromCenter(center: c, width: w, height: h), Paint()..color = Colors.white);
        final pw = mood == Mood.problem ? .04 : .058;
        final ph = mood == Mood.problem ? .056 : .08;
        final gz = _gaze(pose);
        final g = Offset(gz.dx * (w - pw) / 2 * .9, gz.dy * (h - ph) / 2 * .9);
        final pc = c + g;
        canvas.drawOval(Rect.fromCenter(center: pc, width: pw, height: ph), ink);
        canvas.drawCircle(pc + Offset(-pw * .22, -ph * .22), pw * .24, Paint()..color = Colors.white);
        canvas.drawCircle(pc + Offset(pw * .2, ph * .22), pw * .1, Paint()..color = Colors.white);
      }
      // Brows: inner end rises when worried or eager, drops when focused.
      if (mood != Mood.offline) {
        final inner = Offset(c.dx - side * .025, .462 - pose.brow * .02);
        final outer = Offset(c.dx + side * .035, .47 + pose.brow * .008);
        canvas.drawLine(inner, outer, stroke..strokeWidth = .014);
      }
    }

    // Mouth.
    final m = const Offset(.5, .655);
    switch (mood) {
      case Mood.happy:
        final open = Path()
          ..moveTo(m.dx - .045, m.dy - .008)
          ..quadraticBezierTo(m.dx, m.dy + .07, m.dx + .045, m.dy - .008)
          ..close();
        canvas.drawPath(open, ink);
        canvas.drawOval(Rect.fromCenter(center: m + const Offset(0, .025), width: .035, height: .018), Paint()..color = OrblingPalette.cheek);
      case Mood.waiting:
        canvas.drawOval(Rect.fromCenter(center: m, width: .028, height: .034), ink);
      case Mood.problem:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - .03, m.dy + .008)
            ..quadraticBezierTo(m.dx - .015, m.dy - .01, m.dx, m.dy + .004)
            ..quadraticBezierTo(m.dx + .015, m.dy + .016, m.dx + .03, m.dy - .002),
          stroke..strokeWidth = .013,
        );
      case Mood.acting:
        // Tongue-tip of concentration.
        canvas.drawLine(m + const Offset(-.022, 0), m + const Offset(.022, 0), stroke..strokeWidth = .013);
        canvas.drawOval(Rect.fromCenter(center: m + const Offset(.016, .01), width: .018, height: .016), Paint()..color = OrblingPalette.cheek);
      case Mood.thinking:
        canvas.drawOval(Rect.fromCenter(center: m + const Offset(.012, 0), width: .02, height: .012), ink);
      case Mood.listening:
        canvas.drawOval(Rect.fromCenter(center: m, width: .022, height: .026), ink);
      case Mood.speaking:
        // Mouth opens and closes while it talks.
        final open = .35 + .65 * (math.sin(t * 2 * math.pi * 24) * .5 + .5);
        canvas.drawOval(Rect.fromCenter(center: m + const Offset(0, .004), width: .05, height: .012 + .03 * open), ink);
        canvas.drawOval(Rect.fromCenter(center: m + Offset(0, .006 + .008 * open), width: .026, height: .008 + .008 * open), Paint()..color = OrblingPalette.cheek);
      case Mood.idle || Mood.offline:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - .03, m.dy - .004)
            ..quadraticBezierTo(m.dx, m.dy + .026, m.dx + .03, m.dy - .004),
          stroke..strokeWidth = .014,
        );
    }
  }

  void _drawMitten(Canvas canvas, Offset at, double turn, {required bool mirror}) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turn);
    if (mirror) canvas.scale(-1, 1);
    canvas.scale(1.3);
    final palm = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: .085, height: .095),
      const Radius.circular(.042),
    );
    canvas.drawRRect(palm, Paint()..color = OrblingPalette.mitten);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.038, .006), width: .036, height: .05),
      Paint()..color = OrblingPalette.mitten,
    );
    canvas.drawRRect(
      palm,
      Paint()
        ..color = OrblingPalette.mittenShade
        ..style = PaintingStyle.stroke
        ..strokeWidth = .006,
    );
    // Cuff band in the body colour ties hands to the body.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(0, .047), width: .07, height: .02),
        const Radius.circular(.01),
      ),
      Paint()..color = mood == Mood.offline ? const Color(0xFF6A63B8) : OrblingPalette.body,
    );
    canvas.restore();
  }

  List<_Mote> _motes() {
    final color = OrblingPalette.mote(mood);
    if (mood == Mood.offline) {
      return [_Mote(const Offset(.8, .87), .02, color, behind: false, trail: false)];
    }
    if (mood == Mood.happy) return const [];
    final count = switch (mood) {
      Mood.thinking => math.max(3, jobs),
      Mood.idle => 1,
      Mood.listening => 3,
      _ => math.max(1, jobs),
    }.clamp(1, 6);
    final speed = switch (mood) {
      Mood.thinking => 2.0,
      Mood.acting => 1.5,
      Mood.idle => .5,
      _ => 1.0,
    };
    final out = <_Mote>[];
    for (var i = 0; i < count; i++) {
      final a = t * 2 * math.pi * speed + i * 2 * math.pi / count;
      // Tilted ellipse around the body.
      final x = .5 + math.cos(a) * .4;
      final y = .6 + math.sin(a) * .2;
      final pulse = mood == Mood.waiting
          ? 1 + .25 * math.sin(t * 2 * math.pi * 3)
          : (mood == Mood.listening ? 1 + level * 1.2 : 1.0);
      out.add(_Mote(Offset(x, y), .03 * pulse, color, behind: math.sin(a) < 0, trail: true, angle: a, speed: speed));
    }
    return out;
  }

  void _drawMote(Canvas canvas, _Mote m) {
    if (m.trail) {
      for (var k = 1; k <= 3; k++) {
        final a = m.angle - k * .13 * m.speed.sign;
        final p = Offset(.5 + math.cos(a) * .4, .6 + math.sin(a) * .2);
        canvas.drawCircle(p, m.r * (1 - k * .22), Paint()..color = m.color.withValues(alpha: .35 - k * .09));
      }
    }
    canvas.drawCircle(m.at, m.r, Paint()..color = m.color);
    // Four-point glint.
    final g = m.r * .55;
    canvas.drawPath(
      Path()
        ..moveTo(m.at.dx, m.at.dy - g)
        ..quadraticBezierTo(m.at.dx, m.at.dy, m.at.dx + g, m.at.dy)
        ..quadraticBezierTo(m.at.dx, m.at.dy, m.at.dx, m.at.dy + g)
        ..quadraticBezierTo(m.at.dx, m.at.dy, m.at.dx - g, m.at.dy)
        ..quadraticBezierTo(m.at.dx, m.at.dy, m.at.dx, m.at.dy - g),
      Paint()..color = Colors.white.withValues(alpha: .85),
    );
  }

  void _drawExtras(Canvas canvas) {
    switch (mood) {
      case Mood.happy:
        // Its motes burst into sparkles when a job is done.
        for (final (x, y, r) in const [(.14, .24, .03), (.86, .22, .026), (.5, .13, .022), (.27, .12, .016), (.74, .1, .018)]) {
          final k = r * (1 + .25 * _wave);
          final paint = Paint()..color = OrblingPalette.gold;
          canvas.drawPath(
            Path()
              ..moveTo(x, y - k * 2)
              ..quadraticBezierTo(x, y, x + k * 2, y)
              ..quadraticBezierTo(x, y, x, y + k * 2)
              ..quadraticBezierTo(x, y, x - k * 2, y)
              ..quadraticBezierTo(x, y, x, y - k * 2),
            paint,
          );
        }
      case Mood.thinking:
        for (var i = 0; i < 3; i++) {
          final lit = ((t * 6).floor() % 4) > i;
          canvas.drawCircle(Offset(.73 + i * .045, .2 - i * .03), .012 + i * .004,
              Paint()..color = (lit ? OrblingPalette.body : OrblingPalette.bodyLight).withValues(alpha: lit ? 1 : .35));
        }
      case Mood.waiting:
        // A small speech card: it has a question for you.
        final card = RRect.fromRectAndRadius(
          Rect.fromCenter(center: const Offset(.84, .3), width: .1, height: .08),
          const Radius.circular(.02),
        );
        canvas.drawRRect(card, Paint()..color = Colors.white);
        canvas.drawRRect(card, Paint()
          ..color = OrblingPalette.mote(Mood.waiting)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .008);
        canvas.drawCircle(const Offset(.84, .3), .012, Paint()..color = OrblingPalette.mote(Mood.waiting));
      case Mood.problem:
        canvas.drawPath(
          Path()
            ..moveTo(.78, .36)
            ..quadraticBezierTo(.81, .42, .78, .43)
            ..quadraticBezierTo(.75, .42, .78, .36),
          Paint()..color = const Color(0xFF7CC8FF),
        );
      case Mood.offline:
        final z = Paint()
          ..color = OrblingPalette.body.withValues(alpha: .45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .011
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        for (final (x, y, k) in const [(.66, .22, .035), (.73, .13, .048)]) {
          final dy = .01 * _wave;
          canvas.drawPath(
            Path()
              ..moveTo(x, y + dy)
              ..lineTo(x + k, y + dy)
              ..lineTo(x, y + k + dy)
              ..lineTo(x + k, y + k + dy),
            z,
          );
        }
      case Mood.listening:
        // Sound waves arriving, bigger when you speak louder.
        final wave = Paint()
          ..color = OrblingPalette.mote(Mood.listening).withValues(alpha: .8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .012
          ..strokeCap = StrokeCap.round;
        for (final side in [-1.0, 1.0]) {
          for (var i = 0; i < 3; i++) {
            final r = .05 + i * .035 + level * .03;
            final c = Offset(.5 + side * .42, .5);
            canvas.drawArc(Rect.fromCircle(center: c, radius: r), side < 0 ? math.pi - .6 : -.6, 1.2, false,
                wave..color = wave.color.withValues(alpha: (.85 - i * .25) * (.4 + level * .6)));
          }
        }
      case Mood.speaking:
        final wave = Paint()
          ..color = OrblingPalette.body.withValues(alpha: .5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .01
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 2; i++) {
          final r = .04 + i * .03 + .01 * math.sin(t * 2 * math.pi * 12 + i);
          canvas.drawArc(Rect.fromCircle(center: const Offset(.6, .66), radius: r), -.7, 1.4, false, wave);
        }
      case Mood.idle || Mood.acting:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant OrblingPainter old) =>
      old.mood != mood || old.t != t || old.blend != blend || old.jobs != jobs || old.previous != previous ||
      old.look != look || old.level != level;
}

class _Mote {
  const _Mote(this.at, this.r, this.color, {required this.behind, required this.trail, this.angle = 0, this.speed = 1});
  final Offset at;
  final double r;
  final Color color;
  final bool behind;
  final bool trail;
  final double angle;
  final double speed;
}

/// The phone's Face View: the screen is Compii's head. Its curl peeks in at
/// the top, its eyes fill the middle, its hands rise from the bottom edge
/// and its motes drift across the front.
class OrblingFacePainter extends CustomPainter {
  OrblingFacePainter({
    required this.mood,
    required this.previous,
    required this.blend,
    required this.jobs,
    required this.t,
    this.still = false,
    this.look,
    this.level = 0,
  });
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;
  final bool still;
  final Offset? look;
  final double level;

  Offset _gaze(_Pose pose) => look != null && _canLook(mood) ? look! : pose.gaze;

  double get _wave => math.sin(t * 2 * math.pi);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final pose = _Pose.lerp(_Pose.of(previous), _Pose.of(mood), blend);
    final dim = mood == Mood.offline;
    final body = dim ? const Color(0xFF6A63B8) : OrblingPalette.body;

    // Night sky behind the head.
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1B1550));

    // The head: a huge dome whose top sits just below the screen edge.
    final breathe = dim ? 0.0 : _wave * h * .006;
    final top = h * .1 - breathe;
    final head = Path()
      ..moveTo(-w * .1, h * 1.1)
      ..lineTo(-w * .1, h * .62)
      ..cubicTo(-w * .02, top + h * .12, w * .3, top, w * .5, top)
      ..cubicTo(w * .7, top, w * 1.02, top + h * .12, w * 1.1, h * .62)
      ..lineTo(w * 1.1, h * 1.1)
      ..close();
    canvas.drawPath(head, Paint()..color = body);
    canvas.save();
    canvas.clipPath(head);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * .3, top + h * .14), width: w * .32, height: h * .12),
      Paint()..color = OrblingPalette.bodyLight.withValues(alpha: .55),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * .55, h * 1.05), width: w * 1.3, height: h * .35),
      Paint()..color = OrblingPalette.bodyDeep.withValues(alpha: .6),
    );
    canvas.restore();

    // The curl peeking in at the top.
    final u = math.min(w, h);
    final cx = w * .5;
    canvas.drawPath(
      Path()
        ..moveTo(cx, top + u * .01)
        ..cubicTo(cx - u * .02, top - u * .12, cx + u * .14, top - u * .17, cx + u * .16, top - u * .08)
        ..cubicTo(cx + u * .17, top - u * .02, cx + u * .09, top - u * .02, cx + u * .1, top - u * .07),
      Paint()
        ..color = body
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * .06
        ..strokeCap = StrokeCap.round,
    );

    // Face geometry scales with the shorter side so portrait and landscape both work.
    final eyeH = math.min(h * .36, w * .3);
    final eyeW = eyeH * .72;
    final eyeY = h * .5;
    final gap = eyeW * .95;
    final ink = Paint()..color = OrblingPalette.ink;
    final stroke = Paint()
      ..color = OrblingPalette.ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = eyeH * .07;

    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + side * gap * 1.45, eyeY + eyeH * .62), width: eyeW * .7, height: eyeH * .2),
        Paint()..color = OrblingPalette.cheek.withValues(alpha: mood == Mood.happy ? .8 : .45),
      );
    }

    final blink = mood == Mood.idle && !still && t > .62 && t < .645;
    for (final side in [-1.0, 1.0]) {
      final c = Offset(cx + side * gap, eyeY);
      if (mood == Mood.happy) {
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - eyeW * .42, c.dy + eyeH * .08)
            ..quadraticBezierTo(c.dx, c.dy - eyeH * .45, c.dx + eyeW * .42, c.dy + eyeH * .08),
          stroke,
        );
      } else if (dim || blink) {
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - eyeW * .4, c.dy)
            ..quadraticBezierTo(c.dx, c.dy + eyeH * .2, c.dx + eyeW * .4, c.dy),
          stroke,
        );
      } else {
        final eh = mood == Mood.acting ? eyeH * .82 : eyeH;
        canvas.drawOval(Rect.fromCenter(center: c, width: eyeW, height: eh), Paint()..color = Colors.white);
        final small = mood == Mood.problem;
        final pw = eyeW * (small ? .42 : .6);
        final ph = eh * (small ? .42 : .6);
        final gz = _gaze(pose);
        final g = Offset(gz.dx * (eyeW - pw) / 2 * .9, gz.dy * (eh - ph) / 2 * .9);
        final pc = c + g;
        canvas.drawOval(Rect.fromCenter(center: pc, width: pw, height: ph), ink);
        canvas.drawCircle(pc + Offset(-pw * .22, -ph * .22), pw * .22, Paint()..color = Colors.white);
        canvas.drawCircle(pc + Offset(pw * .2, ph * .2), pw * .09, Paint()..color = Colors.white);
      }
      if (!dim) {
        final browY = eyeY - eyeH * .68;
        final inner = Offset(c.dx - side * eyeW * .28, browY - pose.brow * eyeH * .14);
        final outer = Offset(c.dx + side * eyeW * .4, browY + pose.brow * eyeH * .05);
        canvas.drawLine(inner, outer, stroke);
      }
    }

    // Mouth.
    final m = Offset(cx, eyeY + eyeH * .7);
    final k = eyeH * .2;
    switch (mood) {
      case Mood.happy:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - k * 1.3, m.dy - k * .2)
            ..quadraticBezierTo(m.dx, m.dy + k * 1.8, m.dx + k * 1.3, m.dy - k * .2)
            ..close(),
          ink,
        );
        canvas.drawOval(Rect.fromCenter(center: m + Offset(0, k * .65), width: k, height: k * .5), Paint()..color = OrblingPalette.cheek);
      case Mood.waiting:
        canvas.drawOval(Rect.fromCenter(center: m, width: k * .8, height: k), ink);
      case Mood.problem:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - k, m.dy + k * .2)
            ..quadraticBezierTo(m.dx - k * .5, m.dy - k * .35, m.dx, m.dy + k * .1)
            ..quadraticBezierTo(m.dx + k * .5, m.dy + k * .5, m.dx + k, m.dy - k * .1),
          stroke,
        );
      case Mood.acting:
        canvas.drawLine(m - Offset(k * .7, 0), m + Offset(k * .7, 0), stroke);
        canvas.drawOval(Rect.fromCenter(center: m + Offset(k * .45, k * .3), width: k * .55, height: k * .45), Paint()..color = OrblingPalette.cheek);
      case Mood.thinking:
        canvas.drawOval(Rect.fromCenter(center: m + Offset(k * .35, 0), width: k * .6, height: k * .36), ink);
      case Mood.listening:
        canvas.drawOval(Rect.fromCenter(center: m, width: k * .7, height: k * .8), ink);
      case Mood.speaking:
        final open = .35 + .65 * (math.sin(t * 2 * math.pi * 24) * .5 + .5);
        canvas.drawOval(Rect.fromCenter(center: m, width: k * 1.6, height: k * (.3 + 1.1 * open)), ink);
        canvas.drawOval(Rect.fromCenter(center: m + Offset(0, k * .35 * open), width: k * .8, height: k * .35 * open + 1), Paint()..color = OrblingPalette.cheek);
      case Mood.idle || Mood.offline:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - k * .9, m.dy - k * .1)
            ..quadraticBezierTo(m.dx, m.dy + k * .8, m.dx + k * .9, m.dy - k * .1),
          stroke,
        );
    }

    _hands(canvas, size, pose, u);
    _motes(canvas, size, u);
  }

  void _hands(Canvas canvas, Size size, _Pose pose, double u) {
    final w = size.width, h = size.height;
    final tap = math.sin(t * 2 * math.pi * 6);
    // Hands come into view from the bottom edge only when they say something.
    final (double, double) raise = switch (mood) {
      Mood.happy => (.62, .62),
      Mood.waiting => (1.2, .72 + math.sin(t * 2 * math.pi * 3) * .02),
      Mood.problem => (1.2, .55),
      Mood.thinking => (1.2, .86),
      Mood.acting => (.9 + math.max(0, tap) * .02, .9 + math.max(0, -tap) * .02),
      _ => (1.2, 1.2),
    };
    final (double, double) xs = switch (mood) {
      Mood.acting => (.4, .6),
      Mood.problem => (.12, .78),
      _ => (.12, .88),
    };
    for (final (i, y) in [(0, raise.$1), (1, raise.$2)]) {
      if (y > 1.1) continue;
      // Stay clear of the controls along the bottom edge.
      final at = Offset(w * (i == 0 ? xs.$1 : xs.$2), math.min(h * y, h - 100));
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(i == 0 ? pose.leftTurn : pose.rightTurn);
      if (i == 1) canvas.scale(-1, 1);
      final r = u * .11;
      final palm = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: r, height: r * 1.12), Radius.circular(r * .5));
      canvas.drawRRect(palm, Paint()..color = OrblingPalette.mitten);
      canvas.drawOval(Rect.fromCenter(center: Offset(r * .45, r * .07), width: r * .42, height: r * .6), Paint()..color = OrblingPalette.mitten);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, r * .56), width: r * .82, height: r * .24), Radius.circular(r * .12)),
        Paint()..color = OrblingPalette.bodyDeep,
      );
      canvas.restore();
    }
  }

  void _motes(Canvas canvas, Size size, double u) {
    if (mood == Mood.happy) {
      for (final (x, y, r) in const [(.18, .2, .035), (.84, .18, .03), (.08, .55, .02), (.93, .5, .025)]) {
        final k = u * r * (1 + .2 * _wave);
        final c = Offset(size.width * x, size.height * y);
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy - k * 2)
            ..quadraticBezierTo(c.dx, c.dy, c.dx + k * 2, c.dy)
            ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + k * 2)
            ..quadraticBezierTo(c.dx, c.dy, c.dx - k * 2, c.dy)
            ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - k * 2),
          Paint()..color = OrblingPalette.gold,
        );
      }
      return;
    }
    if (mood == Mood.offline) return;
    final count = switch (mood) {
      Mood.thinking => math.max(3, jobs),
      Mood.idle => 1,
      Mood.listening => 3,
      _ => math.max(1, jobs),
    }.clamp(1, 6);
    final speed = mood == Mood.thinking ? 2.0 : mood == Mood.idle ? .5 : 1.0;
    final color = OrblingPalette.mote(mood);
    for (var i = 0; i < count; i++) {
      // A wide flat ring around the head; only the front (lower) arc shows on the face.
      final a = t * 2 * math.pi * speed + i * 2 * math.pi / count;
      final front = math.sin(a);
      if (front < -.15) continue;
      final ringY = math.min(size.height * .8, size.height - 96);
      final c = Offset(size.width * (.5 + math.cos(a) * .46), ringY + size.height * front * .05);
      final r = u * .028 * (mood == Mood.waiting ? 1 + .25 * math.sin(t * 2 * math.pi * 3) : 1);
      canvas.drawCircle(c, r, Paint()..color = color);
      canvas.drawCircle(c + Offset(-r * .3, -r * .3), r * .3, Paint()..color = Colors.white.withValues(alpha: .85));
    }
  }

  @override
  bool shouldRepaint(covariant OrblingFacePainter old) =>
      old.mood != mood || old.t != t || old.blend != blend || old.jobs != jobs || old.previous != previous ||
      old.look != look || old.level != level;
}
