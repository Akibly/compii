import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../art/gem_mesh.dart';
import '../console/character.dart' show Mood, moodLabel;
import 'glyphs.dart';
import 'tokens.dart';

/// The six volumetric characters a teammate can be. Every teammate wears one.
enum AgentShape { orb, gem, planet, gyro, capsule, comet }

extension AgentShapeInfo on AgentShape {
  String get label => switch (this) {
    AgentShape.orb => 'Orb',
    AgentShape.gem => 'Facet',
    AgentShape.planet => 'Orbit',
    AgentShape.gyro => 'Gyro',
    AgentShape.capsule => 'Pod',
    AgentShape.comet => 'Comet',
  };

  String get note => switch (this) {
    AgentShape.orb => 'A polished sphere with a molten heart. It breathes, drifts and blinks.',
    AgentShape.gem => 'A crystal that turns in the light, with a face in its front facet.',
    AgentShape.planet => 'A small world with a ring, a moon and a look on its face.',
    AgentShape.gyro => 'Three rings around a glowing core. The core is the face.',
    AgentShape.capsule => 'A glass ampoule with a living light, and a lit visor for eyes.',
    AgentShape.comet => 'A chrome spark with a tail of light, and a busy little expression.',
  };
}


/// What is saved on a bot: `a1.<shape>.<seed>`. A token that is missing or
/// unusable falls back to a character drawn from the name, so a teammate looks
/// the same every time even before anyone has chosen one.
class AgentLook {
  const AgentLook(this.shape, this.seed);

  final AgentShape shape;
  final int seed;

  String encode() => 'a1.${shape.name}.$seed';

  static AgentLook parse(String raw, {String name = ''}) {
    final bits = raw.trim().split('.');
    if (bits.length == 3 && bits.first == 'a1') {
      final shape = AgentShape.values.asNameMap()[bits[1]];
      if (shape != null) {
        final seed = int.tryParse(bits[2])?.abs() ?? 0;
        return AgentLook(shape, (seed - 1) % 9973 + 1);
      }
    }
    return name.isEmpty ? const AgentLook(AgentShape.orb, 1) : forName(name);
  }

  /// A stable design for a name, used where no saved bot exists yet.
  static AgentLook forName(String name) {
    var h = 0x811c9dc5;
    for (final c in name.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    final shape = AgentShape.values[h.abs() % AgentShape.values.length];
    return AgentLook(shape, h.abs() % 9973 + 1);
  }
}

/// A teammate's face: a small object cut from glass, wearing what it is doing.
/// Lists keep them still; homes let them move.
class AgentFace extends StatefulWidget {
  const AgentFace({
    super.key,
    required this.color,
    required this.shape,
    this.seed = 1,
    this.size = 28,
    this.animate = false,
    this.ring = false,
    this.backgroundDisc = true,
    this.mood = Mood.idle,
    this.semanticLabel,
  });

  final Color color;
  final AgentShape shape;
  final int seed;
  final double size;
  final bool animate;
  final bool ring;

  /// What the teammate is doing, worn as an expression.
  final Mood mood;

  /// Lists, chips and the editor keep the soft disc; the character picker
  /// shows the object on its own.
  final bool backgroundDisc;
  final String? semanticLabel;

  @override
  State<AgentFace> createState() => _AgentFaceState();
}

class _AgentFaceState extends State<AgentFace> with SingleTickerProviderStateMixin {
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AgentFace old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) _sync();
  }

  void _sync() {
    final still = !widget.animate || MediaQuery.of(context).disableAnimations;
    if (still) {
      clock.stop();
    } else if (!clock.isAnimating) {
      clock.repeat();
    }
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final face = AnimatedBuilder(
      animation: clock,
      builder: (context, _) {
        final still = !widget.animate || MediaQuery.of(context).disableAnimations;
        return CustomPaint(
          painter: AgentFacePainter(
            shape: widget.shape,
            color: color,
            seed: widget.seed,
            mood: widget.mood,
            t: still ? .18 : clock.value,
            still: still,
            detail: widget.size >= 44 ? 2 : (widget.size >= 24 ? 1 : 0),
          ),
        );
      },
    );
    return Semantics(
      label: widget.semanticLabel ?? '${widget.shape.label} character, ${moodLabel(widget.mood)}',
      image: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: widget.backgroundDisc
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-.35, -.45),
                      radius: .95,
                      colors: [color.withValues(alpha: .18), color.withValues(alpha: .07)],
                    ),
                    border: Border.all(
                      color: color.withValues(alpha: widget.ring ? .85 : .28),
                      width: widget.ring ? 1.5 : 1,
                    ),
                  ),
                  child: face,
                )
              : face,
        ),
      ),
    );
  }
}

class AgentFacePainter extends CustomPainter {
  AgentFacePainter({
    required this.shape,
    required this.color,
    required this.seed,
    required this.t,
    required this.detail,
    this.mood = Mood.idle,
    this.still = false,
  });

  final AgentShape shape;
  final Color color;
  final int seed;
  final double t;
  final int detail;
  final Mood mood;

  /// True for lists, chips and saved frames: the pose holds, nothing blinks.
  final bool still;

  double get loop => t * math.pi * 2;
  double get phase => (seed % 360) / 360 * math.pi * 2;

  Color get light => Color.lerp(color, Colors.white, .42)!;
  Color get pale => Color.lerp(color, Colors.white, .78)!;
  Color get deep => Color.lerp(color, const Color(0xFF070610), .62)!;
  Color get ink => Color.lerp(color, const Color(0xFF070610), .82)!;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    canvas.scale(s / 100);

    switch (shape) {
      case AgentShape.orb:
        _orb(canvas);
      case AgentShape.gem:
        _gem(canvas);
      case AgentShape.planet:
        _planet(canvas);
      case AgentShape.gyro:
        _gyro(canvas);
      case AgentShape.capsule:
        _capsule(canvas);
      case AgentShape.comet:
        _comet(canvas);
    }
    canvas.restore();
  }

  // -- helpers ---------------------------------------------------------------

  void _shadow(Canvas canvas, double width) {
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(50, 80), width: width, height: width * .18),
      Paint()
        ..color = const Color(0xFF070610).withValues(alpha: .28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
  }

  void _aura(Canvas canvas, Offset at, double radius, double alpha) {
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
  }

  void _heart(Canvas canvas, Offset at, double r, double alpha) {
    canvas.drawCircle(
      at,
      r * 4.2,
      Paint()
        ..shader = RadialGradient(
          colors: [pale.withValues(alpha: .35 * alpha), pale.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: at, radius: r * 4.2)),
    );
    canvas.drawCircle(
      at,
      r * 1.8,
      Paint()
        ..color = color.withValues(alpha: .3 * alpha)
        ..maskFilter = detail > 0 ? MaskFilter.blur(BlurStyle.normal, r * .7) : null,
    );
    canvas.drawCircle(
      at,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.35, -.4),
          radius: .95,
          colors: [Colors.white, pale, color],
          stops: const [0, .4, 1],
        ).createShader(Rect.fromCircle(center: at, radius: r)),
    );
    canvas.drawCircle(at + Offset(-r * .28, -r * .32), r * .3, Paint()..color = Colors.white.withValues(alpha: .9 * alpha));
  }

  Path _circleClip(Offset center, double r) => Path()..addOval(Rect.fromCircle(center: center, radius: r));

  // -- the face --------------------------------------------------------------

  /// How the face is set this frame: lids, eye size, brows, mouth, where it is
  /// looking and how far the head tips.
  ({double open, double eye, double raise, double asym, double slant, double smile, double part, Offset gaze,
  double blush, double tilt}) _expression() {
    // Two beats of the mouth per breath while it talks.
    final beat = still ? .55 : math.pow(math.sin(loop * 5), 2).toDouble();
    final drift = still
        ? Offset.zero
        : Offset(math.sin(loop * .8 + phase) * .3, math.cos(loop * .55 + phase) * .2);
    return switch (mood) {
      Mood.idle => (
        open: 1, eye: 1, raise: 0, asym: 0, slant: 0, smile: .45, part: 0, gaze: drift, blush: .1, tilt: 0
      ),
      Mood.listening => (
        open: 1, eye: 1.14, raise: .55, asym: 0, slant: -.15, smile: .15, part: .08,
        gaze: const Offset(0, -.08), blush: 0, tilt: -.02
      ),
      Mood.thinking => (
        open: .82, eye: .96, raise: .1, asym: .65, slant: .2, smile: .05, part: 0,
        gaze: const Offset(.6, -.5), blush: 0, tilt: .05
      ),
      Mood.acting => (
        open: .95, eye: .9, raise: -.5, asym: 0, slant: .5, smile: .12, part: 0,
        gaze: const Offset(0, .45), blush: 0, tilt: 0
      ),
      Mood.speaking => (
        open: 1, eye: 1.02, raise: .2, asym: .12, slant: -.05, smile: .45, part: .18 + .5 * beat,
        gaze: drift * .5, blush: .15, tilt: .01
      ),
      Mood.waiting => (
        open: 1, eye: 1.06, raise: .75, asym: .1, slant: -.62, smile: -.1, part: .48,
        gaze: const Offset(0, -.35), blush: 0, tilt: -.04
      ),
      Mood.happy => (
        open: .45, eye: 1, raise: .35, asym: 0, slant: .35, smile: .95, part: .34,
        gaze: Offset.zero, blush: .55, tilt: .02
      ),
      Mood.problem => (
        open: .72, eye: .9, raise: .55, asym: 0, slant: -.7, smile: -.75, part: .12,
        gaze: const Offset(0, .15), blush: 0, tilt: -.06
      ),
      Mood.offline => (
        open: .3, eye: .88, raise: .05, asym: 0, slant: -.3, smile: -.15, part: 0,
        gaze: const Offset(0, .25), blush: 0, tilt: .03
      ),
    };
  }

  /// How shut the lids are, 0 open .. 1 closed. Three blinks a cycle, at a
  /// point set by the seed so no two teammates blink together.
  double get _shut {
    if (still || mood == Mood.offline) return 0;
    final q = (t * 3 + (seed % 71) / 71) % 1;
    if (q > .045) return 0;
    return math.sin(q / .045 * math.pi);
  }

  /// Two big eyes, brows and a mouth, painted straight onto the body. One rig
  /// drives all six shapes so every teammate reads the same way; [w] is the
  /// distance from centre to one eye and everything else scales from it.
  /// [emissive] is for a face lit from inside a dark visor instead of cut into
  /// a bright body.
  void _face(
    Canvas canvas, {
    required Offset at,
    required double w,
    double tilt = 0,
    bool emissive = false,
  }) {
    final e = _expression();
    final open = (e.open * (1 - _shut)).clamp(0.0, 1.0);
    final r = w * (detail >= 2 ? .53 : .58) * e.eye;
    final eyeY = -w * .26;
    final gx = e.gaze.dx * r * .5;
    final gy = e.gaze.dy * r * .5;
    final glow = emissive ? color : pale;
    final brow = emissive ? pale.withValues(alpha: .9) : deep.withValues(alpha: .92);
    final dark = emissive ? const Color(0xFF070610) : const Color(0xFF05040F);

    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(tilt + e.tilt);

    if (e.blush > 0) {
      for (final side in [-1.0, 1.0]) {
        canvas.drawOval(
          Rect.fromCenter(
              center: Offset(side * w * 1.16, eyeY + r * 2.1), width: r * 2.3, height: r * 1.15),
          Paint()
            ..color = color.withValues(alpha: .3 * e.blush)
            ..maskFilter = detail > 0 ? MaskFilter.blur(BlurStyle.normal, r * .5) : null,
        );
      }
    }

    for (final side in [-1.0, 1.0]) {
      final c = Offset(side * w, eyeY);
      if (detail >= 2) {
        canvas.drawCircle(
          c,
          r * 2.3,
          Paint()
            ..shader = RadialGradient(
              colors: [glow.withValues(alpha: emissive ? .3 : .13), glow.withValues(alpha: 0)],
            ).createShader(Rect.fromCircle(center: c, radius: r * 2.3)),
        );
      }
      // The lid closes from the top, so the eye keeps its bottom edge.
      final top = c.dy + r * (1 - 2 * open);
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(c.dx - r * 1.9, top, c.dx + r * 1.9, c.dy + r * 2.0));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.26, -.3),
            radius: 1.06,
            colors: emissive ? [Colors.white, pale] : [deep, ink],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
      canvas.drawCircle(Offset(c.dx + gx, c.dy + gy), r * .62, Paint()..color = emissive ? light : color);
      canvas.drawCircle(
        Offset(c.dx + gx * 1.15, c.dy + gy * 1.15),
        r * .34,
        Paint()..color = dark,
      );
      if (detail >= 1) {
        canvas.drawCircle(c + Offset(-r * .3, -r * .44), r * .24, Paint()..color = Colors.white.withValues(alpha: .95));
        if (detail >= 2) {
          canvas.drawCircle(c + Offset(r * .3, r * .34), r * .12, Paint()..color = Colors.white.withValues(alpha: .5));
        }
      }
      canvas.restore();
      if (detail >= 2) {
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * .12
            ..color = glow.withValues(alpha: emissive ? .55 : .34),
        );
      }
      if (open < .96 && detail >= 1) {
        canvas.drawLine(
          Offset(c.dx - r * .95, top),
          Offset(c.dx + r * .95, top),
          Paint()
            ..strokeWidth = r * .24
            ..strokeCap = StrokeCap.round
            ..color = emissive ? pale : ink,
        );
      }
      // Brows only from 44 px up: below that they turn the face to mud.
      if (detail >= 2) {
        final raise = e.raise + side * e.asym;
        final base = eyeY - r * 1.44 - raise * r * .95;
        final inner = Offset(side * w * .58, base + e.slant * r * .72);
        final outer = Offset(side * w * 1.34, base - e.slant * r * .26 - raise * r * .22);
        canvas.drawPath(
          Path()
            ..moveTo(inner.dx, inner.dy)
            ..quadraticBezierTo((inner.dx + outer.dx) / 2, base - raise * r * .55 - r * .12, outer.dx, outer.dy),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * .3
            ..strokeCap = StrokeCap.round
            ..color = brow,
        );
      }
    }

    final mw = w * .86;
    final my = w * .66;
    final curve = e.smile * mw * .95;
    final ph = e.part * mw * .95;
    if (ph <= mw * .07) {
      canvas.drawPath(
        Path()
          ..moveTo(-mw, my)
          ..quadraticBezierTo(0, my + curve, mw, my),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * .34
          ..strokeCap = StrokeCap.round
          ..color = emissive ? pale : ink,
      );
    } else {
      final mouth = Path()
        ..moveTo(-mw, my)
        ..quadraticBezierTo(0, my + curve + ph * .3, mw, my)
        ..quadraticBezierTo(0, my + curve + ph * 1.7, -mw, my)
        ..close();
      canvas.drawPath(mouth, Paint()..color = const Color(0xFF070610).withValues(alpha: emissive ? .55 : .92));
      canvas.save();
      canvas.clipPath(mouth);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(0, my + curve + ph * 1.1), width: mw * 1.3, height: ph * 1.1),
        Paint()..color = (emissive ? pale : light).withValues(alpha: .55),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  // -- orb -------------------------------------------------------------------

  void _orb(Canvas canvas) {
    final center = Offset(50 + math.sin(loop) * 1.4, 49 + math.sin(loop * 2) * 1.2);
    const r = 25.0;
    _shadow(canvas, 34);
    _aura(canvas, center, 38, .18);

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.45, -.52),
          radius: .98,
          colors: [pale, light, color, deep],
          stops: const [0, .30, .72, 1],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    canvas.save();
    canvas.clipPath(_circleClip(center, r));
    // A slow current inside the glass.
    final band = Path()
      ..moveTo(center.dx - r, center.dy + r * .12)
      ..cubicTo(center.dx - r * .35, center.dy - r * .42, center.dx + r * .38, center.dy + r * .48,
          center.dx + r, center.dy - r * .04);
    canvas.drawPath(
      band,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: .16),
    );
    if (detail >= 1) {
      canvas.drawPath(
        band,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: .16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    // Light caught on the lower edge, as if it were standing on a table.
    canvas.drawArc(
      Rect.fromCircle(center: center + const Offset(0, 1.5), radius: r - 2),
      .35,
      1.25,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = pale.withValues(alpha: .20),
    );
    canvas.restore();

    // The molten heart, low in the glass: a glow rather than a second face.
    final core = center + Offset(math.cos(loop + phase) * r * .16, r * .66 + math.sin(loop * 2 + phase) * r * .06);
    canvas.drawCircle(
      core,
      9.5,
      Paint()
        ..shader = RadialGradient(
          colors: [pale.withValues(alpha: .42), color.withValues(alpha: .12), color.withValues(alpha: 0)],
          stops: const [0, .5, 1],
        ).createShader(Rect.fromCircle(center: core, radius: 9.5)),
    );

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: .75), color.withValues(alpha: .20), deep.withValues(alpha: .30)],
          stops: const [0, .55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Mirror glint, high on the glass so the brows have room under it.
    canvas.save();
    canvas.translate(center.dx - r * .5, center.dy - r * .68);
    canvas.rotate(-.72);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 10, height: 3.2),
      Paint()
        ..color = Colors.white.withValues(alpha: .85)
        ..maskFilter = detail > 0 ? const MaskFilter.blur(BlurStyle.normal, 1.1) : null,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 5.4, height: 1.1),
      Paint()..color = Colors.white,
    );
    canvas.restore();

    _face(
      canvas,
      at: center + Offset(math.sin(loop) * .8, -2.2),
      w: 10.0,
      tilt: math.sin(loop * .8 + phase) * .022,
    );

    if (detail >= 1) {
      final a = loop + phase;
      final moon = center + Offset(math.cos(a) * (r + 7), math.sin(a) * (r + 3) * .55);
      canvas.drawCircle(moon, 2.6, Paint()..color = pale.withValues(alpha: .8));
      canvas.drawCircle(moon, 6, Paint()..color = pale.withValues(alpha: .12));
    }
  }

  // -- gem -------------------------------------------------------------------

  void _gem(Canvas canvas) {
    const geometry = GemGeometry(
      top: -.9,
      upperY: -.34,
      upperRadius: .44,
      lowerY: .28,
      lowerRadius: .48,
      bottom: .9,
    );
    const center = Offset(50, 50);
    // It turns to show its facets, but only as far as a head turns: enough for
    // the light to move across the crystal, never so far that the face is lost.
    final sway = math.sin(loop * .6 + phase);
    final yaw = sway * .62;
    final pitch = .16 + math.sin(loop * 1.2 + phase) * .05;
    const scale = 27.0;
    _shadow(canvas, 33);
    _aura(canvas, center, 36, .16);

    final faces = geometry.faces(yaw: yaw, pitch: pitch, cx: center.dx, cy: center.dy, scale: scale);
    final hull = geometry.silhouette(yaw: yaw, pitch: pitch, cx: center.dx, cy: center.dy, scale: scale);
    final body = pathFrom(hull);
    final bounds = body.getBounds();

    canvas.drawPath(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [light, deep, ink],
          stops: const [0, .55, 1],
        ).createShader(bounds),
    );

    for (final face in faces.where((f) => !f.front)) {
      canvas.drawPath(
        face.path,
        Paint()..color = Color.lerp(ink, color, .16 + .22 * face.lit)!.withValues(alpha: .9),
      );
    }

    canvas.save();
    canvas.clipPath(body);
    canvas.drawCircle(
      center,
      scale * .42,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: .42), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: scale * .42)),
    );
    _heart(canvas, center + Offset(0, scale * .3), scale * .1, .8);
    canvas.restore();

    for (final face in faces.where((f) => f.front)) {
      final tint = Color.lerp(deep, color, .16 + .28 * face.lit)!;
      final fill = Color.lerp(tint, Colors.white, .06 + .24 * face.lit)!;
      canvas.drawPath(face.path, Paint()..color = fill.withValues(alpha: .52));
      if (detail >= 1) {
        canvas.drawPath(
          face.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = .8
            ..color = Colors.white.withValues(alpha: .12 + .34 * face.lit),
        );
      }
    }

    canvas.save();
    canvas.clipPath(body);
    canvas.translate(center.dx - scale * .46, center.dy - scale * .66);
    canvas.rotate(-.62);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 9, height: 2.2),
      Paint()
        ..color = Colors.white.withValues(alpha: .5)
        ..maskFilter = detail > 0 ? const MaskFilter.blur(BlurStyle.normal, 1.2) : null,
    );
    canvas.restore();

    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: .75), pale.withValues(alpha: .35), color.withValues(alpha: .5)],
        ).createShader(bounds),
    );

    // The face rides on the front facet, lit from inside the crystal so it
    // reads against the dark glass.
    _face(canvas, at: center + Offset(sway * 2.6, -.4), w: 6.9, tilt: sway * .05, emissive: true);
  }

  // -- planet ----------------------------------------------------------------

  Offset _orbit(double a, {double rx = 35, double ry = 12, double tilt = -.36}) {
    final x = math.cos(a) * rx;
    final y = math.sin(a) * ry;
    return const Offset(50, 49) + Offset(x * math.cos(tilt) - y * math.sin(tilt), x * math.sin(tilt) + y * math.cos(tilt));
  }

  void _planet(Canvas canvas) {
    const center = Offset(50, 49);
    final tilt = -.36 + math.sin(loop) * .05;
    _shadow(canvas, 36);
    _aura(canvas, center, 36, .13);

    // Far half of both rings.
    for (final (rx, ry, w, a) in [(37.0, 13.0, 2.2, .35), (31.5, 10.5, 1.0, .16)]) {
      final path = Path();
      for (var i = 0; i <= 36; i++) {
        final angle = math.pi + i / 36 * math.pi;
        final p = _orbit(angle, rx: rx, ry: ry, tilt: tilt);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round
          ..color = Color.lerp(deep, color, .35)!.withValues(alpha: a + .18),
      );
    }

    final moonAngle = loop + phase;
    final moon = _orbit(moonAngle, rx: 39, ry: 15, tilt: tilt);
    final moonBehind = math.sin(moonAngle) < 0;
    if (moonBehind) _moon(canvas, moon, .5);

    const r = 21.0;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.42, -.5),
          radius: .98,
          colors: [pale, light, color, deep],
          stops: const [0, .24, .7, 1],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Cloud belts, slowly drifting, kept below the face.
    canvas.save();
    canvas.clipPath(_circleClip(center, r));
    for (var i = -2; i <= 2; i++) {
      final drift = math.sin(loop + i) * 2.2;
      final y = center.dy + 7 + i * 5.4 + drift;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(center.dx, y), width: 52, height: 5),
        Paint()..color = (i.isEven ? Colors.white : deep).withValues(alpha: i.isEven ? .10 : .14),
      );
    }
    // The ring's shadow.
    canvas.save();
    canvas.translate(center.dx, center.dy + 10);
    canvas.rotate(-.28);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 46, height: 3.4),
      Paint()..color = deep.withValues(alpha: .28),
    );
    canvas.restore();
    canvas.restore();

    // Near half of the rings.
    for (final (rx, ry, w, a) in [(37.0, 13.0, 2.4, .55), (31.5, 10.5, 1.0, .24)]) {
      final path = Path();
      for (var i = 0; i <= 36; i++) {
        final angle = i / 36 * math.pi;
        final p = _orbit(angle, rx: rx, ry: ry, tilt: tilt);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round
          ..color = Color.lerp(pale, color, .35)!.withValues(alpha: a),
      );
    }

    if (!moonBehind) _moon(canvas, moon, 1);

    canvas.save();
    canvas.translate(center.dx - 12, center.dy - 13);
    canvas.rotate(-.5);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 8, height: 2.8),
      Paint()
        ..color = Colors.white.withValues(alpha: .42)
        ..maskFilter = detail > 0 ? const MaskFilter.blur(BlurStyle.normal, 1.2) : null,
    );
    canvas.restore();

    // The face sits on the north of the world, clear of the ring.
    _face(
      canvas,
      at: center + Offset(math.sin(loop) * 1.0, -4.2),
      w: 8.6,
      tilt: math.sin(loop * .7 + phase) * .03,
    );
  }

  void _moon(Canvas canvas, Offset at, double alpha) {
    canvas.drawCircle(at, 3.2, Paint()..color = pale.withValues(alpha: .85 * alpha));
    canvas.drawCircle(at, 7, Paint()..color = pale.withValues(alpha: .10 * alpha));
  }

  // -- gyro ------------------------------------------------------------------

  Offset _gyroPoint(double angle, double rotation, {double rx = 33, double ry = 19}) {
    final x = math.cos(angle) * rx;
    final y = math.sin(angle) * ry;
    return const Offset(50, 49) + Offset(x * math.cos(rotation) - y * math.sin(rotation), x * math.sin(rotation) + y * math.cos(rotation));
  }

  void _gyro(Canvas canvas) {
    const center = Offset(50, 49);
    _shadow(canvas, 34);
    _aura(canvas, center, 35, .15);

    final precession = math.sin(loop) * .16;
    final rotations = [-.55 + precession, .45 - precession * .6, 1.32 + precession * .4];

    for (var i = 0; i < rotations.length; i++) {
      _ringHalf(canvas, i, rotations[i], back: true);
    }

    // The core is the face: big enough to read, and it holds still while the
    // rings work around it.
    const core = 16.5;
    canvas.drawCircle(
      center,
      core,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.4, -.45),
          radius: .95,
          colors: [Colors.white, pale, color, deep],
          stops: const [0, .22, .68, 1],
        ).createShader(Rect.fromCircle(center: center, radius: core)),
    );
    canvas.drawCircle(
      center,
      core,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .9
        ..color = Colors.white.withValues(alpha: .35),
    );
    _face(
      canvas,
      at: center + Offset(math.sin(loop + phase) * .8, -1.4),
      w: 7.0,
      tilt: math.sin(loop * .9 + phase) * .03,
    );

    for (var i = 0; i < rotations.length; i++) {
      _ringHalf(canvas, i, rotations[i], back: false);
    }
  }

  void _ringHalf(Canvas canvas, int i, double rotation, {required bool back}) {
    final start = back ? math.pi : 0.0;
    final path = Path();
    for (var k = 0; k <= 30; k++) {
      final angle = start + k / 30 * math.pi;
      final p = _gyroPoint(angle, rotation);
      if (k == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    final stroke = switch (i) {
      0 => light,
      1 => pale,
      _ => color,
    };
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = back ? 1.2 : 1.6
        ..strokeCap = StrokeCap.round
        ..color = stroke.withValues(alpha: back ? .28 : .75),
    );

    final beadAngle = loop * 2 + i * 2.1;
    final bead = _gyroPoint(beadAngle, rotation);
    final beadFront = math.sin(beadAngle) >= 0;
    if (beadFront == !back) {
      canvas.drawCircle(bead, 4.2, Paint()..color = stroke.withValues(alpha: back ? .12 : .22));
      canvas.drawCircle(bead, 1.8, Paint()..color = stroke.withValues(alpha: back ? .5 : 1));
      if (!back) canvas.drawCircle(bead - const Offset(.5, .6), .7, Paint()..color = Colors.white);
    }
  }

  // -- capsule ---------------------------------------------------------------

  void _capsule(Canvas canvas) {
    _shadow(canvas, 28);
    canvas.save();
    canvas.translate(50, 50 + math.sin(loop * 2 + phase) * 1.2);
    canvas.rotate(math.sin(loop + phase) * .055);
    canvas.translate(-50, -50);
    _aura(canvas, const Offset(50, 49), 34, .14);

    final body = RRect.fromLTRBR(37, 16, 63, 84, const Radius.circular(13));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, .5)!, color, deep, ink],
          stops: const [0, .28, .75, 1],
        ).createShader(const Rect.fromLTRB(37, 16, 63, 84)),
    );

    // The living light sits low in the glass and rises when it is working.
    canvas.save();
    canvas.clipRRect(body);
    final busy = mood == Mood.acting || mood == Mood.speaking || mood == Mood.listening;
    final level = (busy ? 60.0 : 66.0) + math.sin(loop * 2 + phase) * 3.5;
    final pool = Path()
      ..moveTo(37, level)
      ..quadraticBezierTo(46, level - 4, 63, level)
      ..lineTo(63, 84)
      ..lineTo(37, 84)
      ..close();
    canvas.drawPath(
      pool,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [pale, color, deep],
        ).createShader(Rect.fromLTRB(37, level - 4, 63, 84)),
    );
    final bubble = (loop * 9 + phase * 4) % 20;
    canvas.drawCircle(Offset(45 + math.sin(loop * 2) * 2, 80 - bubble), 1.1, Paint()..color = Colors.white.withValues(alpha: .5));
    canvas.drawCircle(Offset(55 - math.sin(loop) * 2, 80 - (bubble * 1.4) % 16), .8, Paint()..color = Colors.white.withValues(alpha: .4));
    canvas.restore();

    // A dark visor, lit from inside: this is where the character lives.
    final visor = RRect.fromLTRBR(40, 24, 60, 55, const Radius.circular(9));
    canvas.drawRRect(visor, Paint()..color = const Color(0xFF070610).withValues(alpha: .78));
    canvas.save();
    canvas.clipRRect(visor);
    canvas.drawCircle(
      const Offset(50, 39),
      14,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: busy ? .3 : .16), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: const Offset(50, 39), radius: 14)),
    );
    _face(canvas, at: const Offset(50, 38.5), w: 5.9, emissive: true);
    canvas.restore();
    canvas.drawRRect(
      visor,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .9
        ..color = Colors.white.withValues(alpha: .32),
    );

    // Seams and the pilot light at the top.
    canvas.drawLine(const Offset(40, 21), const Offset(60, 21), Paint()..color = Colors.white.withValues(alpha: .16));
    canvas.drawLine(const Offset(40, 59), const Offset(60, 59), Paint()..color = deep.withValues(alpha: .3));
    canvas.drawCircle(const Offset(50, 19), 1.8, Paint()..color = pale);
    canvas.drawCircle(const Offset(50, 19), 4.2, Paint()..color = pale.withValues(alpha: .18));

    // Mirror streak down the left shoulder, out of the way of the visor.
    canvas.save();
    canvas.clipRRect(body);
    canvas.translate(40.4, 68);
    canvas.rotate(-.06);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 3.2, height: 16),
      Paint()
        ..color = Colors.white.withValues(alpha: .26)
        ..maskFilter = detail > 0 ? const MaskFilter.blur(BlurStyle.normal, 1.4) : null,
    );
    canvas.restore();
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: .7), pale.withValues(alpha: .3), deep.withValues(alpha: .2)],
        ).createShader(const Rect.fromLTRB(37, 16, 63, 84)),
    );
    canvas.restore();
  }

  // -- comet -----------------------------------------------------------------

  void _comet(Canvas canvas) {
    _shadow(canvas, 30);
    const center = Offset(59, 47);
    final angle = -.58 + math.sin(loop + phase) * .10;
    final back = Offset(math.cos(angle + math.pi), math.sin(angle + math.pi));
    final side = Offset(-back.dy, back.dx);
    _aura(canvas, center, 34, .18);

    // Tail: a long triangular wisp behind the sphere.
    final baseA = center + back * 12 + side * 9;
    final baseB = center + back * 12 - side * 9;
    final tip = center + back * (40 + math.sin(loop * 2) * 3) + side * 2;
    final tail = Path()
      ..moveTo(baseA.dx, baseA.dy)
      ..quadraticBezierTo(center.dx + back.dx * 27 + side.dx * 6, center.dy + back.dy * 27 + side.dy * 6, tip.dx, tip.dy)
      ..quadraticBezierTo(center.dx + back.dx * 27 - side.dx * 6, center.dy + back.dy * 27 - side.dy * 6, baseB.dx, baseB.dy)
      ..close();
    final tailBounds = tail.getBounds();
    canvas.drawPath(
      tail,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-back.dx, -back.dy),
          end: Alignment(back.dx, back.dy),
          colors: [color.withValues(alpha: .55), light.withValues(alpha: .22), color.withValues(alpha: 0)],
        ).createShader(tailBounds),
    );
    for (var i = 0; i < 3; i++) {
      final offset = (i - 1) * 4.5;
      final from = center + back * 13 + side * offset;
      final to = center + back * (31 + i * 4) + side * (offset * .35);
      canvas.drawLine(
        from,
        to,
        Paint()
          ..strokeWidth = 1.1 - i * .2
          ..strokeCap = StrokeCap.round
          ..color = pale.withValues(alpha: .3 - i * .07),
      );
    }

    // The sphere.
    const r = 18.0;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.45, -.5),
          radius: .98,
          colors: [Colors.white, pale, color, deep],
          stops: const [0, .18, .62, 1],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
    canvas.save();
    canvas.clipPath(_circleClip(center, r));
    canvas.drawCircle(
      center + Offset(back.dx * 5, back.dy * 5),
      r * .7,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(-back.dx, -back.dy),
          radius: 1,
          colors: [Colors.transparent, deep.withValues(alpha: .45)],
        ).createShader(Rect.fromCircle(center: center + Offset(back.dx * 5, back.dy * 5), radius: r * .7)),
    );
    _heart(canvas, center + Offset(back.dx * 7, back.dy * 7), 3.6, .55);
    canvas.restore();

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: .8), pale.withValues(alpha: .2), deep.withValues(alpha: .3)],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Sparks riding the wake, behind the sphere so the face stays clear.
    for (var i = 0; i < 3; i++) {
      final a = loop * 2 + i * math.pi * 2 / 3;
      final p = center + back * (17 + (i % 2) * 7 + math.sin(a) * 2.5) + side * (math.cos(a) * 7);
      canvas.drawCircle(
        p,
        1.3 + (math.sin(a) * .5 + .5) * .8,
        Paint()..color = pale.withValues(alpha: .45 + .45 * math.sin(a)),
      );
    }

    _face(
      canvas,
      at: center + Offset(-back.dx * 1.2, -1.8),
      w: 7.2,
      tilt: math.sin(loop + phase) * .06,
    );
  }

  @override
  bool shouldRepaint(covariant AgentFacePainter old) =>
      old.shape != shape ||
      old.color != color ||
      old.seed != seed ||
      old.t != t ||
      old.detail != detail ||
      old.mood != mood ||
      old.still != still;
}

/// Pick which character a teammate wears. Each one previews live in the bot's
/// own accent colour.
Future<AgentLook?> showAgentPicker(BuildContext context, {required Color color, required AgentLook look}) =>
    showDialog<AgentLook>(context: context, builder: (_) => _AgentPicker(color: color, look: look));

class _AgentPicker extends StatefulWidget {
  const _AgentPicker({required this.color, required this.look});
  final Color color;
  final AgentLook look;

  @override
  State<_AgentPicker> createState() => _AgentPickerState();
}

class _AgentPickerState extends State<_AgentPicker> {
  late AgentShape _shape = widget.look.shape;
  late int _seed = widget.look.seed;

  void _pickShape(AgentShape shape) => setState(() => _shape = shape);

  void _surprise() => setState(() => _seed = math.Random().nextInt(9973) + 1);

  AgentLook get _look => AgentLook(_shape, _seed);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: const Text('Choose a character'),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 600),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(36),
                        gradient: RadialGradient(colors: [widget.color.withValues(alpha: .16), Colors.transparent]),
                      ),
                      child: AgentFace(
                        color: widget.color,
                        shape: _shape,
                        seed: _seed,
                        size: 112,
                        animate: true,
                        backgroundDisc: false,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_shape.label, style: context.type.headlineSmall),
                          const SizedBox(height: 4),
                          Text(_shape.note, style: context.type.bodySmall?.copyWith(color: c.muted)),
                          const SizedBox(height: 10),
                          FilledButton.tonalIcon(
                            onPressed: _surprise,
                            icon: const Glyph(G.wand, size: 16),
                            label: const Text('Surprise me'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('CHARACTERS', style: context.type.labelSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final shape in AgentShape.values)
                      _ShapeButton(
                        shape: shape,
                        color: widget.color,
                        seed: _seed,
                        selected: _shape == shape,
                        onTap: () => _pickShape(shape),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Every character is drawn live: it blinks, looks up and takes the bot’s accent colour, '
                  'and its face shows what the teammate is doing. Lists keep them still; their home lets them move.',
                  style: context.type.labelMedium?.copyWith(color: c.faint),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _look),
          child: const Text('Use this character'),
        ),
      ],
    );
  }
}

class _ShapeButton extends StatelessWidget {
  const _ShapeButton({
    required this.shape,
    required this.color,
    required this.seed,
    required this.selected,
    required this.onTap,
  });
  final AgentShape shape;
  final Color color;
  final int seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 92,
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected ? c.accentSoft : Colors.transparent,
          border: Border.all(color: selected ? c.accent : c.border, width: selected ? 1.6 : 1),
        ),
        child: Column(
          children: [
            AgentFace(
              color: color,
              shape: shape,
              seed: seed,
              size: 64,
              animate: true,
              backgroundDisc: false,
            ),
            const SizedBox(height: 6),
            Text(shape.label, style: context.type.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
