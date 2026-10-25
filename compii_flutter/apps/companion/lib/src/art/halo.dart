import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../console/character.dart' show Mood;

/// Compii and every teammate are one object: a smooth piece of black glass —
/// the same material as the island it lives in — with two eyes of light and a
/// halo of colour around its edge.
///
/// Why this and not a creature: what makes a character eerie is a mismatch of
/// cues — realistic eyes on a realistic texture, a face that is almost a face.
/// The characters people love most (EVE, Vector) are the opposite: a clean body
/// and graphic eyes that do all the feeling. So nothing here imitates life. The
/// eyes are two shapes of light; the glass is glass; the halo is the light the
/// work gives off. Every expression is the eyes changing shape, and the halo
/// says how hard it is working — the same signal Apple's edge glow gives.
enum HaloForm { orb, tile, pill, tower, gem }

extension HaloFormInfo on HaloForm {
  /// Screen readers only. Pickers show the shape and never a name.
  String get desc => switch (this) {
    HaloForm.orb => 'A round glass orb with two eyes of light',
    HaloForm.tile => 'A soft square of glass with two eyes of light',
    HaloForm.pill => 'A wide glass capsule with two eyes of light',
    HaloForm.tower => 'A tall glass capsule with two eyes of light',
    HaloForm.gem => 'A glass diamond with two eyes of light',
  };
}

/// The default light. Any colour is a choice; this is where it starts.
const haloBlue = Color(0xFF3D8BFF);

/// Quick picks. Any colour works — these are the ones a click away.
const haloSwatches = <Color>[
  haloBlue,
  Color(0xFF2FD3FF),
  Color(0xFF7B6CFF),
  Color(0xFFC06BFF),
  Color(0xFFFF5FA8),
  Color(0xFFFF5A4E),
  Color(0xFFFF9B3D),
  Color(0xFFFFD84A),
  Color(0xFF3BE08F),
  Color(0xFFF2EFE8),
  Color(0xFF9AA3B2),
];

String colorHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color? parseHex(String raw) {
  final s = raw.trim().replaceFirst('#', '');
  final v = int.tryParse(s, radix: 16);
  return v == null || s.length != 6 ? null : Color(0xFF000000 | v);
}

/// A hue turned by [deg] degrees, kept bright enough to glow.
Color _turn(Color c, double deg, {double light = 0}) {
  final h = HSLColor.fromColor(c);
  return h
      .withHue((h.hue + deg) % 360)
      .withLightness((math.max(h.lightness, .5) + light).clamp(0.0, .92))
      .withSaturation(math.max(h.saturation, .5))
      .toColor();
}

/// What a mood does to the eyes and the halo.
///
/// `open` is eye height (0 shut, 1 normal), `wide` eye width, `tilt` slants the
/// top of each eye (+ worried, inner corners up; − cross, inner corners down),
/// `joy` turns the eyes into happy arcs, `wink` closes the right eye partly
/// (the look-inward of thinking), `glance` is where the eyes go when the mood
/// rather than the pointer steers them, `glow` how strong the halo is and
/// `spin` how fast it orbits.
class EyeRig {
  const EyeRig({
    this.open = 1,
    this.wide = 1,
    this.tilt = 0,
    this.joy = 0,
    this.wink = 0,
    this.glance = Offset.zero,
    this.glow = .4,
    this.spin = .2,
    this.bob = .01,
  });
  final double open, wide, tilt, joy, wink, glow, spin, bob;
  final Offset glance;

  static EyeRig of(Mood m) => switch (m) {
    Mood.idle => const EyeRig(),
    Mood.listening => const EyeRig(open: 1.15, wide: 1.06, glow: .75, spin: .5, bob: .014),
    Mood.thinking => const EyeRig(open: .62, wink: .45, glance: Offset(.55, -.7), glow: .65, spin: 1.6, bob: .006),
    Mood.acting => const EyeRig(open: .42, wide: 1.3, glow: .85, spin: 1.1, bob: .016),
    Mood.speaking => const EyeRig(open: 1.05, glow: .6, spin: .4, bob: .014),
    Mood.waiting => const EyeRig(open: 1.1, tilt: .75, glow: .7, spin: .3, bob: .008),
    Mood.happy => const EyeRig(joy: 1, glow: .9, spin: .7, bob: .03),
    Mood.problem => const EyeRig(open: .75, tilt: -.8, glow: .55, spin: .15, bob: 0),
    Mood.offline => const EyeRig(open: .07, wide: 1.1, glow: 0, spin: 0, bob: 0),
  };

  static EyeRig mix(EyeRig a, EyeRig b, double t) {
    double l(double x, double y) => x + (y - x) * t;
    return EyeRig(
      open: l(a.open, b.open),
      wide: l(a.wide, b.wide),
      tilt: l(a.tilt, b.tilt),
      joy: l(a.joy, b.joy),
      wink: l(a.wink, b.wink),
      glance: Offset.lerp(a.glance, b.glance, t)!,
      glow: l(a.glow, b.glow),
      spin: l(a.spin, b.spin),
      bob: l(a.bob, b.bob),
    );
  }
}

/// How shut the eyes are from blinking, 0..1, on the slow cycle [s]. Four blinks
/// a cycle, one doubled, shifted by the seed so a row of teammates never blinks
/// in unison.
double haloBlink(double s, int seed) {
  var b = 0.0;
  final shift = (seed % 97) / 97 * .3;
  for (final at in const [.09, .41, .445, .76]) {
    final c = (at + shift) % 1;
    var d = (s - c).abs();
    d = math.min(d, 1 - d);
    b = math.max(b, (1 - d / .0065).clamp(0.0, 1.0));
  }
  return b;
}

/// One frame: what the character is doing and where it is looking.
class HaloPose {
  const HaloPose({
    required this.mood,
    this.previous,
    this.blend = 1,
    this.t = .25,
    this.s = .3,
    this.still = true,
    this.look = Offset.zero,
    this.level = 0,
    this.jobs = 0,
    this.moodColor,
  });
  final Mood mood;
  final Mood? previous;
  final double blend;

  /// 0..1 around the breath cycle; the halo orbits on it.
  final double t;

  /// 0..1 around the slow cycle: blinks.
  final double s;
  final bool still;

  /// Pointer direction, -1..1 on each axis.
  final Offset look;

  /// Voice level 0..1; the halo and the eyes answer it.
  final double level;
  final int jobs;

  /// The state light, for the job lights; null draws none.
  final Color? moodColor;
}

/// The outline of each form in figure units, centred on the origin.
Path haloShape(HaloForm form) {
  switch (form) {
    case HaloForm.orb:
      return Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: .36));
    case HaloForm.pill:
      return Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: .8, height: .46), const Radius.circular(.23)));
    case HaloForm.tower:
      return Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: .5, height: .76), const Radius.circular(.25)));
    case HaloForm.tile:
      return _squircle(.35, .335, 4.6, 0);
    case HaloForm.gem:
      return _squircle(.37, .37, 2.6, math.pi / 4);
  }
}

/// A superellipse — the continuous-curvature corner Apple draws its icons with,
/// not a rounded rectangle's arc welded to a straight line.
Path _squircle(double a, double b, double n, double rotate) {
  final p = Path();
  const steps = 96;
  for (var i = 0; i <= steps; i++) {
    final th = i / steps * 2 * math.pi;
    final c = math.cos(th), s = math.sin(th);
    var x = a * c.sign * math.pow(c.abs(), 2 / n);
    var y = b * s.sign * math.pow(s.abs(), 2 / n);
    if (rotate != 0) {
      final rx = x * math.cos(rotate) - y * math.sin(rotate);
      final ry = x * math.sin(rotate) + y * math.cos(rotate);
      x = rx;
      y = ry * .94;
    }
    i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
  }
  return p..close();
}

/// Where the eyes sit and how big they are, for each form.
({Offset centre, double gap, double w, double h}) _face(HaloForm form) => switch (form) {
  HaloForm.orb => (centre: const Offset(0, -.01), gap: .085, w: .082, h: .17),
  HaloForm.tile => (centre: const Offset(0, -.01), gap: .088, w: .084, h: .17),
  HaloForm.pill => (centre: const Offset(0, -.005), gap: .1, w: .08, h: .15),
  HaloForm.tower => (centre: const Offset(0, -.06), gap: .07, w: .07, h: .15),
  HaloForm.gem => (centre: const Offset(0, -.005), gap: .075, w: .07, h: .145),
};

class Halo {
  Halo._();

  static void paint(
    Canvas canvas, {
    required Offset centre,
    required double span,
    required HaloForm form,
    required Color color,
    required HaloPose pose,
    int seed = 1,
    bool shadow = true,
  }) {
    final rig = EyeRig.mix(EyeRig.of(pose.previous ?? pose.mood), EyeRig.of(pose.mood), pose.blend);
    final dim = pose.mood == Mood.offline;
    final unit = 1 / span;
    final tau = 2 * math.pi;
    final breath = pose.still ? 0.0 : math.sin(pose.t * tau);
    final float = pose.still ? 0.0 : math.sin(pose.t * tau * 2) * rig.bob;
    final level = pose.level.clamp(0.0, 1.0);
    final glow = (rig.glow * (dim ? 0 : 1) + level * .35).clamp(0.0, 1.2);
    // The orbit is the halo's own clock: idle drifts, thinking races.
    final orbit = pose.still ? .12 : (pose.t * (1 + rig.spin * 3) + seed * .137) % 1;
    final body = haloShape(form);
    final bounds = body.getBounds();

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(span);

    if (shadow) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(0, bounds.bottom + .06), width: bounds.width * .78, height: .05),
        Paint()
          ..color = Colors.black.withValues(alpha: dim ? .18 : .32)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(.014, unit * 2)),
      );
      if (glow > 0) {
        // The halo's light falling on the floor.
        canvas.drawOval(
          Rect.fromCenter(center: Offset(0, bounds.bottom + .06), width: bounds.width * .9, height: .07),
          Paint()
            ..color = color.withValues(alpha: .16 * glow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(.03, unit * 3)),
        );
      }
    }

    _jobs(canvas, pose, bounds, front: false);

    canvas.save();
    canvas.translate(0, float);
    canvas.scale(1 + breath * .008, 1 - breath * .008);

    if (glow > 0) _halo(canvas, body, color, glow, orbit, unit);
    _glass(canvas, body, bounds, color, glow, orbit, pose.look, unit, dim);
    final blink = pose.still ? 0.0 : haloBlink(pose.s, seed);
    final gaze = rig.glance == Offset.zero
        ? pose.look
        : Offset.lerp(pose.look, rig.glance, (rig.glance.distance).clamp(0.0, 1.0) * .85)!;
    final f = _face(form);
    canvas.save();
    canvas.clipPath(body);
    paintHaloEyes(
      canvas,
      centre: f.centre + Offset(gaze.dx * f.gap * .55, gaze.dy * f.h * .3),
      gap: f.gap,
      w: f.w,
      h: f.h,
      color: color,
      rig: rig,
      blink: blink,
      bounce: pose.mood == Mood.speaking && !pose.still ? level * .2 + math.sin(pose.t * 60) * .05 : 0,
      unit: unit,
      dim: dim,
      reflect: true,
    );
    canvas.restore();
    canvas.restore();

    _jobs(canvas, pose, bounds, front: true);
    canvas.restore();
  }

  /// The halo: a ring of the colour, its neighbours on the wheel either side,
  /// orbiting the edge and bloomed in two layers — a tight rim and a wide wash.
  static void _halo(Canvas canvas, Path body, Color c, double glow, double orbit, double unit) {
    final colors = [
      c,
      _turn(c, 38, light: .08),
      _turn(c, -30, light: .16),
      _turn(c, 70),
      c,
    ];
    final shader = SweepGradient(
      colors: colors,
      transform: GradientRotation(orbit * 2 * math.pi),
    ).createShader(const Rect.fromLTWH(-.5, -.5, 1, 1));
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .09
        ..shader = shader
        ..color = Colors.white.withValues(alpha: (.55 * glow).clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(.06, unit * 4)),
    );
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .03
        ..shader = shader
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(.014, unit * 1.5)),
    );
  }

  /// The glass: near-black, faintly tinted, lit from above, with an edge that
  /// catches the halo and a specular sweep that moves as the pointer does.
  static void _glass(Canvas canvas, Path body, Rect b, Color c, double glow, double orbit, Offset look,
      double unit, bool dim) {
    canvas.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(b.topCenter, b.bottomCenter, [
          Color.lerp(const Color(0xFF1E1F27), c, .07)!,
          const Color(0xFF0C0C11),
          const Color(0xFF040406),
        ], const [0, .55, 1]),
    );
    canvas.save();
    canvas.clipPath(body);
    // Light from inside, low in the glass: the eyes and halo glowing through it.
    // Painted over the whole shape so the falloff, not an outline, ends it.
    canvas.drawRect(
      b.inflate(.02),
      Paint()
        ..shader = ui.Gradient.radial(Offset(0, b.bottom + b.height * .1), b.height * .75, [
          c.withValues(alpha: dim ? 0 : .14 + .1 * glow),
          c.withValues(alpha: 0),
        ]),
    );
    // The specular sweep across the top, as a falloff over the whole shape.
    final sx = -look.dx * b.width * .08;
    canvas.drawRect(
      b.inflate(.02),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(sx, b.top + b.height * .02),
          b.width * .55,
          [Colors.white.withValues(alpha: .13), Colors.white.withValues(alpha: .03), Colors.white.withValues(alpha: 0)],
          const [0, .45, 1],
          TileMode.clamp,
          Matrix4.diagonal3Values(1, .5, 1).storage,
          Offset(sx, b.top + b.height * .02),
        ),
    );
    canvas.restore();
    // The rim: a hairline that catches the halo's colour where it is brightest.
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(.006, unit * .9)
        ..shader = SweepGradient(
          colors: [
            Colors.white.withValues(alpha: .35),
            c.withValues(alpha: .25 + .5 * glow.clamp(0.0, 1.0)),
            Colors.white.withValues(alpha: .08),
            c.withValues(alpha: .2 + .4 * glow.clamp(0.0, 1.0)),
            Colors.white.withValues(alpha: .35),
          ],
          transform: GradientRotation(orbit * 2 * math.pi),
        ).createShader(const Rect.fromLTWH(-.5, -.5, 1, 1)),
    );
  }

  static void _jobs(Canvas canvas, HaloPose pose, Rect b, {required bool front}) {
    final n = math.min(pose.jobs, 5);
    final color = pose.moodColor;
    if (n == 0 || color == null) return;
    for (var i = 0; i < n; i++) {
      final a = (pose.still ? .15 : pose.t) * 2 * math.pi + i * 2 * math.pi / n;
      if ((math.sin(a) >= 0) != front) continue;
      final at = Offset(math.cos(a) * (b.width / 2 + .1), b.center.dy + .04 + math.sin(a) * .1);
      final r = .022 + math.sin(a) * .005;
      canvas.drawCircle(at, r * 3, Paint()..color = color.withValues(alpha: .16));
      canvas.drawCircle(at, r, Paint()..color = Color.lerp(color, Colors.white, .5)!);
    }
  }
}

/// The two eyes, shared by the characters and by the island so the island's
/// eyes are Compii's eyes. Each eye is a capsule of light: a coloured bloom, a
/// pale core and a hot centre. Expressions only ever change the shapes.
void paintHaloEyes(
  Canvas canvas, {
  required Offset centre,
  required double gap,
  required double w,
  required double h,
  required Color color,
  required EyeRig rig,
  double blink = 0,
  double bounce = 0,
  double unit = 0,
  bool dim = false,
  bool reflect = false,
}) {
  final core = Color.lerp(color, Colors.white, dim ? .1 : .62)!;
  final bloom = dim ? color.withValues(alpha: .25) : color;
  for (final side in const [-1.0, 1.0]) {
    final at = centre + Offset(side * gap, -bounce * h * .3);
    final ew = w * rig.wide;
    var open = (rig.open * (1 - blink)).clamp(0.0, 1.3);
    if (side > 0) open *= 1 - rig.wink;
    if (rig.joy > .5 && !dim) {
      _arc(canvas, at, ew, h, core, bloom, unit);
      continue;
    }
    final eh = math.max(h * open, ew * .34);
    final rect = Rect.fromCenter(center: at, width: ew, height: eh);
    final shape = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(math.min(ew, eh) / 2)));
    // Tilt: cut the top of the eye along a slanted line. Worried lifts the inner
    // corners, cross drops them.
    Path eye = shape;
    if (rig.tilt.abs() > .02 && eh > ew * .5) {
      final k = rig.tilt.clamp(-1.0, 1.0) * eh * .3;
      final inner = rect.top + (k < 0 ? -k : 0);
      final outer = rect.top + (k > 0 ? k : 0);
      final xi = at.dx - side * ew, xo = at.dx + side * ew;
      final keep = Path()
        ..moveTo(xi, inner)
        ..lineTo(xo, outer)
        ..lineTo(xo, rect.bottom + 1)
        ..lineTo(xi, rect.bottom + 1)
        ..close();
      eye = Path.combine(PathOperation.intersect, shape, keep);
    }
    canvas.drawPath(
      eye,
      Paint()
        ..color = bloom.withValues(alpha: dim ? .3 : .85)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(ew * .55, unit * 2)),
    );
    canvas.drawPath(eye, Paint()..color = core);
    if (!dim && eh > ew * .6) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: at - Offset(0, eh * .12), width: ew * .42, height: eh * .5),
            Radius.circular(ew * .21)),
        Paint()
          ..color = Colors.white.withValues(alpha: .7)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(ew * .14, unit * .6)),
      );
    }
    if (reflect && !dim) {
      // The eye's light on the glass beneath it.
      canvas.drawOval(
        Rect.fromCenter(center: at + Offset(0, eh / 2 + h * .32), width: ew * 1.3, height: h * .2),
        Paint()
          ..color = color.withValues(alpha: .14)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(ew * .4, unit * 2)),
      );
    }
  }
}

/// A happy eye: an arc of light, like a smile closed over the eye.
void _arc(Canvas canvas, Offset at, double w, double h, Color core, Color bloom, double unit) {
  final p = Path()
    ..moveTo(at.dx - w * .62, at.dy + h * .12)
    ..quadraticBezierTo(at.dx, at.dy - h * .45, at.dx + w * .62, at.dy + h * .12);
  final stroke = w * .62;
  canvas.drawPath(
    p,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke * 1.3
      ..color = bloom.withValues(alpha: .8)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(w * .5, unit * 2)),
  );
  canvas.drawPath(
    p,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = core,
  );
}

/// A character on its own, for lists, pickers and anywhere that does not need
/// the companion's room around it.
class HaloPainter extends CustomPainter {
  HaloPainter({
    required this.form,
    required this.color,
    required this.pose,
    this.seed = 1,
    this.scale = .9,
  });
  final HaloForm form;
  final Color color;
  final HaloPose pose;
  final int seed;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    Halo.paint(
      canvas,
      centre: size.center(Offset.zero),
      span: size.shortestSide * scale,
      form: form,
      color: color,
      pose: pose,
      seed: seed,
    );
  }

  @override
  bool shouldRepaint(covariant HaloPainter old) =>
      old.form != form ||
      old.color != color ||
      old.seed != seed ||
      old.scale != scale ||
      old.pose.mood != pose.mood ||
      old.pose.previous != pose.previous ||
      old.pose.blend != pose.blend ||
      old.pose.t != pose.t ||
      old.pose.s != pose.s ||
      old.pose.still != pose.still ||
      old.pose.look != pose.look ||
      old.pose.level != pose.level ||
      old.pose.jobs != pose.jobs;
}
