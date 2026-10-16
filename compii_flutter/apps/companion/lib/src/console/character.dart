import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the companion is doing right now. Every character design must show each one.
enum Mood { idle, thinking, acting, waiting, happy, problem, offline }

String moodLabel(Mood mood) => switch (mood) {
  Mood.idle => 'Ready',
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
  });
  final Mood mood;
  final int jobs;
  final bool animate;

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
        animation: Listenable.merge([clock, blend]),
        builder: (context, _) => CustomPaint(
          painter: OrblingPainter(
            mood: widget.mood,
            previous: previous,
            blend: Curves.easeOutBack.transform(blend.value).clamp(0, 1.08),
            jobs: widget.jobs,
            t: still ? widget.phase : clock.value,
            still: still,
          ),
        ),
      ),
    );
  }
}

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
  });
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;
  final bool still;


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
    _drawMitten(canvas, pose.right + Offset(0, -hover + _handBob(left: false)), pose.rightTurn, mirror: true);

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
        final g = Offset(pose.gaze.dx * (w - pw) / 2 * .9, pose.gaze.dy * (h - ph) / 2 * .9);
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
      final pulse = mood == Mood.waiting ? 1 + .25 * math.sin(t * 2 * math.pi * 3) : 1.0;
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
      case Mood.idle || Mood.acting:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant OrblingPainter old) =>
      old.mood != mood || old.t != t || old.blend != blend || old.jobs != jobs || old.previous != previous;
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
