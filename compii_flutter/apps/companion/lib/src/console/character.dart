import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the companion is doing right now. Every state has to be readable at a
/// glance, from across the room and at eighteen pixels.
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

/// Compii's body. The face is one shared rig worn by all of them: the rig is the
/// identity and the body is a preference, which is how Muse and ChatGPT's dots
/// shipped it. `plush` is the default — a big-headed round creature with large
/// dark eyes and nothing that names a species, because a silhouette that only
/// reads if you know the animal has nowhere to go at 38 px.
enum CompiiBody { plush, moth, spark, shell, drop }

extension CompiiBodyInfo on CompiiBody {
  String get label => switch (this) {
    CompiiBody.plush => 'Pip',
    CompiiBody.moth => 'Mica',
    CompiiBody.spark => 'Ember',
    CompiiBody.shell => 'Pebble',
    CompiiBody.drop => 'Dew',
  };

  String get note => switch (this) {
    CompiiBody.plush => 'Round, soft and warm. The one Compii starts as.',
    CompiiBody.moth => 'Furry and wide, wings folded over its back.',
    CompiiBody.spark => 'A small flame the colour of whatever it is doing.',
    CompiiBody.shell => 'A smooth pebble with a seam. Quiet and steady.',
    CompiiBody.drop => 'Soft-bodied: it leans, squashes and settles.',
  };
}

/// The body Compii wears, chosen in Settings and kept on this PC.
final compiiBody = ValueNotifier<CompiiBody>(CompiiBody.plush);

/// Compii is one small creature with a face, wearing a body you choose. Not a
/// logo, not a lens, not an abstract light: a face fires from three dots in a
/// downward triangle, large eyes and a big head carry the liking, and a
/// stylised creature beats a realistic one.
///
/// The face carries *feeling*. The lights beside it carry *work* — one per
/// running job. Everything else — what it is doing, what it found, what it
/// needs — is text next to the character, never a code to decode from its shape.
class CharacterSlot extends StatelessWidget {
  const CharacterSlot({
    super.key,
    required this.mood,
    this.jobs = 0,
    this.size = 260,
  });
  final Mood mood;

  /// Tasks running right now; each one is drawn as a small light beside Compii.
  final int jobs;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Compii, ${moodLabel(mood)}${jobs > 1 ? ', $jobs tasks running' : ''}',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: Ember(mood: mood, jobs: jobs),
    ),
  );
}

/// The fixed materials. The state colour comes from [core].
class EmberPalette {
  /// Cream fur: the body material. Identity, never a mood colour.
  static const paper = Color(0xFFF2E3C8);
  static const paperShade = Color(0xFFB99A72);
  static const fur = Color(0xFF4A382F);
  static const furLight = Color(0xFF8A6647);
  static const ash = Color(0xFF241D2A);
  static const deep = Color(0xFF120D16);
  static const room = Color(0xFF1C1322);

  /// The cool edge, so warm cream never turns to jam against a warm light.
  static const rim = Color(0xFF5FD8C8);

  /// Focus rings and the overlay frame — the product's indigo, not the creature's.
  static const frame = Color(0xFF6B5FFF);
  static const light = Color(0xFFFFF0D8);
  static const gold = Color(0xFFFFC86B);

  /// Cheek blush, deliberately outside the mood colours so it is never a state.
  static const blush = Color(0xFFF4907E);

  static Color core(Mood mood) => switch (mood) {
    Mood.idle => const Color(0xFFEFC08A),
    Mood.listening => const Color(0xFF5FE0D2),
    Mood.thinking => const Color(0xFF8FC4FF),
    Mood.acting => const Color(0xFFFFA23A),
    Mood.speaking => const Color(0xFFFFE2A8),
    Mood.waiting => const Color(0xFFFF8A6B),
    Mood.happy => const Color(0xFF7FE8A8),
    Mood.problem => const Color(0xFFFF5A52),
    Mood.offline => const Color(0xFF7E7570),
  };
}

class Ember extends StatefulWidget {
  const Ember({
    super.key,
    required this.mood,
    this.jobs = 0,
    this.animate = true,
    this.phase = .25,
    this.face = false,
    this.reach,
    this.level = 0,
    this.followPointer = true,
    this.body,
  });
  final Mood mood;
  final int jobs;
  final bool animate;

  /// Microphone level 0..1 while speaking or listening; the mouth answers it.
  final double level;

  /// Compii turns its eyes toward the mouse pointer when free to attend.
  final bool followPointer;

  /// Close-up: Compii fills the room (the phone's Presence View).
  final bool face;

  /// Where Compii should reach, in units of this widget's size (may be outside
  /// 0..1). Used by the desktop overlay to point at things.
  final Offset? reach;

  /// Animation phase used when not animating (for stills and tests).
  final double phase;

  /// Overrides [compiiBody] for a one-off render, as the picker does.
  final CompiiBody? body;

  @override
  State<Ember> createState() => _EmberState();
}

class _EmberState extends State<Ember> with TickerProviderStateMixin {
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  // Eases between states so the face glides into an expression instead of jumping.
  late final AnimationController blend = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );
  late Mood previous = widget.mood;

  @override
  void initState() {
    super.initState();
    compiiBody.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant Ember old) {
    super.didUpdateWidget(old);
    if (old.mood != widget.mood) {
      previous = old.mood;
      if (MediaQuery.disableAnimationsOf(context)) {
        blend.value = 1;
      } else {
        blend.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    compiiBody.removeListener(_changed);
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
          final b = Curves.easeOutCubic.transform(blend.value).clamp(0.0, 1.0);
          final t = still ? widget.phase : clock.value;
          final look = widget.followPointer ? _look(context) : null;
          return CustomPaint(
            size: Size.infinite,
            painter: widget.face
                ? EmberFacePainter(
                    body: widget.body ?? compiiBody.value,
                    mood: widget.mood,
                    previous: previous,
                    blend: b,
                    jobs: widget.jobs,
                    t: t,
                    still: still,
                    look: look,
                    level: widget.level,
                  )
                : EmberPainter(
                    body: widget.body ?? compiiBody.value,
                    mood: widget.mood,
                    previous: previous,
                    blend: b,
                    jobs: widget.jobs,
                    t: t,
                    still: still,
                    reach: widget.reach,
                    look: look,
                    level: widget.level,
                  ),
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

// ---------------------------------------------------------------------------
// The expression. One table read by every body, so the 18 px chip and the
// phone's full-screen close-up wear the same face in the same mood.
// ---------------------------------------------------------------------------

/// What a mood does to the face and the stance. `brow` is raised(+)/furrowed(-),
/// `tilt` is worried(+)/aimed(-), `eye` is shut..wide, and `mouth` runs
/// frown..smile with values above 1.5 meaning "open, speaking".
class _Rig {
  const _Rig({
    required this.brow,
    required this.tilt,
    required this.eye,
    required this.mouth,
    required this.bob,
    required this.lean,
  });
  final double brow;
  final double tilt;
  final double eye;
  final double mouth;
  final double bob;
  final double lean;

  static _Rig of(Mood m) => switch (m) {
    // Ready: nothing is happening, and that is fine.
    Mood.idle => const _Rig(brow: 0, tilt: 0, eye: 1, mouth: .35, bob: .012, lean: 0),
    // Listening: a little wide, brows up, leaning toward the sound.
    Mood.listening => const _Rig(brow: .55, tilt: .15, eye: 1.18, mouth: .1, bob: .02, lean: -.05),
    // Thinking: eyes partly down and away, one brow up. Looking inward.
    Mood.thinking => const _Rig(brow: .3, tilt: -.12, eye: .66, mouth: .0, bob: .008, lean: .06),
    // Working: narrowed and steady. Not unhappy — aimed, so the mouth stays calm.
    Mood.acting => const _Rig(brow: -.15, tilt: -.28, eye: .74, mouth: .08, bob: .026, lean: 0),
    // Speaking: an open mouth sized by the voice.
    Mood.speaking => const _Rig(brow: .2, tilt: 0, eye: 1.02, mouth: 2, bob: .018, lean: 0),
    // Needs you: brows up and pulled together — the classic worried face.
    Mood.waiting => const _Rig(brow: .7, tilt: .85, eye: 1.15, mouth: -.45, bob: .014, lean: -.03),
    // Done: eyes closed into arcs and a big smile. The one happy face.
    Mood.happy => const _Rig(brow: .5, tilt: 0, eye: .05, mouth: .95, bob: .05, lean: 0),
    // Problem: brows down and in, mouth turned down, nothing else moving.
    Mood.problem => const _Rig(brow: -.7, tilt: -.8, eye: .68, mouth: -.6, bob: 0, lean: .02),
    // Offline: shut and slack.
    Mood.offline => const _Rig(brow: 0, tilt: 0, eye: 0, mouth: 0, bob: 0, lean: .09),
  };

  static _Rig mix(_Rig a, _Rig b, double t) => _Rig(
    brow: a.brow + (b.brow - a.brow) * t,
    tilt: a.tilt + (b.tilt - a.tilt) * t,
    eye: a.eye + (b.eye - a.eye) * t,
    mouth: a.mouth + (b.mouth - a.mouth) * t,
    bob: a.bob + (b.bob - a.bob) * t,
    lean: a.lean + (b.lean - a.lean) * t,
  );
}

/// Where a body puts its face, and how big the face is there.
class _Fit {
  const _Fit(this.centre, this.scale);
  final Offset centre;
  final double scale;
}

/// One running job, as a small light rising beside the body.
class _Job {
  const _Job(this.at, this.r, this.alpha);
  final Offset at;
  final double r;
  final double alpha;
}

/// The creature. Figure units: the body fits inside about -0.5..0.5 on both
/// axes, origin at the middle of the figure, y down.
class _Figure {
  _Figure({
    required this.body,
    required this.rig,
    required this.mood,
    required this.t,
    required this.still,
    required this.jobs,
    required this.level,
    required this.look,
    required this.detail,
    required this.unit,
    required this.color,
    required this.dim,
  });

  final CompiiBody body;
  final _Rig rig;
  final Mood mood;
  final double t;
  final bool still;
  final int jobs;
  final double level;
  final Offset? look;

  /// 0 chip, 1 bar, 2 close-up. Detail adds and removes parts; it never blurs.
  final int detail;

  /// One device pixel in figure units, so a hairline stays a hairline at 18 px.
  final double unit;
  final Color color;
  final bool dim;

  double _px(double n) => math.max(unit * n, .004);

  /// The idle life in the body: a small bob and a lean, both from the rig.
  late final Offset seat = Offset(
    (still ? 0 : math.sin(t * 2 * math.pi) * .010) + rig.lean,
    still ? 0 : math.sin(t * 4 * math.pi) * rig.bob,
  );

  _Fit get fit => switch (body) {
    CompiiBody.plush => const _Fit(Offset(0, -.15), 1),
    CompiiBody.moth => const _Fit(Offset(0, -.235), .52),
    CompiiBody.spark => const _Fit(Offset(0, .11), .80),
    CompiiBody.shell => const _Fit(Offset(0, -.02), .92),
    CompiiBody.drop => const _Fit(Offset(0, .10), .84),
  };

  void draw(Canvas canvas) {
    for (final j in _jobLights(front: false)) {
      _job(canvas, j);
    }
    canvas.save();
    canvas.translate(seat.dx, seat.dy);
    switch (body) {
      case CompiiBody.plush:
        _plush(canvas);
      case CompiiBody.moth:
        _moth(canvas);
      case CompiiBody.spark:
        _spark(canvas);
      case CompiiBody.shell:
        _shell(canvas);
      case CompiiBody.drop:
        _drop(canvas);
    }
    _face(canvas);
    canvas.restore();
    for (final j in _jobLights(front: true)) {
      _job(canvas, j);
    }
    _signals(canvas);
  }

  void _job(Canvas canvas, _Job j) {
    // A blurred halo, never a solid one: a translucent disc drawn over the dark
    // room reads as a brown ring with a hole in it.
    canvas.drawCircle(j.at, j.r * 2.4, _soft(color.withValues(alpha: j.alpha * .34), j.r * 1.15));
    canvas.drawCircle(j.at, j.r, Paint()..color = EmberPalette.light.withValues(alpha: j.alpha));
  }

  /// Jobs rise on the right, half of them behind the body so three never stack
  /// into one blob.
  List<_Job> _jobLights({required bool front}) {
    final n = math.min(jobs, 6);
    final all = <_Job>[];
    for (var i = 0; i < n; i++) {
      final p = n == 1 ? .5 : i / (n - 1);
      final rise = still ? .35 + p * .3 : (t + i * .17) % 1;
      final at = Offset(.29 + p * .09, .18 - rise * .44);
      all.add(_Job(at, math.max(_px(1.5), .017), .9 * (1 - rise * .55)));
    }
    return [for (var i = 0; i < all.length; i++) if (i.isEven == front) all[i]];
  }

  // -- bodies ---------------------------------------------------------------

  /// The default: a big round head, a small soft body, two stubby feet. No ears,
  /// no wings, no shell — nothing that names a species and can therefore be wrong.
  void _plush(Canvas canvas) {
    final shape = Path()
      ..addOval(Rect.fromCenter(center: const Offset(0, .185), width: .40, height: .34))
      ..addOval(Rect.fromCenter(center: const Offset(0, -.155), width: .56, height: .53));
    for (final s in const [-1.0, 1.0]) {
      shape.addOval(Rect.fromCenter(center: Offset(s * .115, .345), width: .15, height: .085));
    }
    canvas.drawPath(shape, _skin(shape.getBounds(), const Offset(0, -.28)));
    if (dim || detail < 2) return;
    // The crown catches the light and the jaw does not, so it reads as a volume
    // rather than a cream-coloured disc.
    canvas.save();
    canvas.clipPath(shape);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, -.36), width: .36, height: .16),
      _soft(EmberPalette.light.withValues(alpha: .22), .055),
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, .33), width: .38, height: .13),
      _soft(EmberPalette.paperShade.withValues(alpha: .30), .05),
    );
    canvas.restore();
  }

  /// A moth as it actually sits: wings tented over the back like a roof, so from
  /// the front they are one broad slope with the furry thorax breaking it in the
  /// middle. Two flat lobes held out either side of a thin body is a butterfly,
  /// and that is the read this has to avoid.
  void _moth(Canvas canvas) {
    final beat = still ? 0.0 : math.sin(t * 4 * math.pi) * .022;
    final roof = Path()
      ..moveTo(0, -.30)
      ..cubicTo(.30 + beat, -.27, .40 + beat, -.02, .25, .23)
      ..cubicTo(.13, .34, -.13, .34, -.25, .23)
      ..cubicTo(-.40 - beat, -.02, -.30 - beat, -.27, 0, -.30)
      ..close();
    canvas.drawPath(roof, _skin(roof.getBounds(), const Offset(-.10, -.22)));
    if (!dim) {
      canvas.drawPath(
        roof,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _px(1.4)
          ..color = EmberPalette.paperShade.withValues(alpha: .26),
      );
      // The far side of the tent falls away from the light. This one shading is
      // what turns a flat pair of wings into a roof.
      canvas.save();
      canvas.clipPath(roof);
      canvas.drawPath(
        Path()
          ..moveTo(.02, -.32)
          ..cubicTo(.26, -.26, .40, .0, .26, .26)
          ..lineTo(.46, .30)
          ..lineTo(.46, -.36)
          ..close(),
        _soft(EmberPalette.paperShade.withValues(alpha: .34), .045),
      );
      if (detail >= 2) {
        final veins = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _px(.8)
          ..color = EmberPalette.paperShade.withValues(alpha: .22);
        for (var i = 0; i < 4; i++) {
          final y = -.16 + i * .115;
          canvas.drawLine(Offset(.03, y), Offset(.33, y + .07), veins);
          canvas.drawLine(Offset(-.03, y), Offset(-.33, y + .07), veins);
        }
      }
      canvas.restore();
    }
    // Abdomen, thorax, head: the thorax is the fattest thing about the creature.
    final body = Path()
      ..addOval(Rect.fromCenter(center: const Offset(0, .20), width: .175, height: .28))
      ..addOval(Rect.fromCenter(center: const Offset(0, -.04), width: .26, height: .30))
      ..addOval(Rect.fromCenter(center: const Offset(0, -.235), width: .19, height: .17));
    canvas.drawPath(body, _skin(body.getBounds(), const Offset(0, -.30)));
    if (!dim && detail >= 1) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(.9)
        ..color = EmberPalette.paperShade.withValues(alpha: .32);
      for (var i = 0; i < 3; i++) {
        final y = .14 + i * .062;
        canvas.drawLine(Offset(-.065, y), Offset(.065, y), ring);
      }
    }
    _combs(canvas);
  }

  /// A small flame — the one body whose own material *is* the state colour.
  /// Tall, licking to one side, and read through its value ramp more than its
  /// hue: a pale state colour still has to look like something burning.
  void _spark(Canvas canvas) {
    final lick = still ? 0.0 : math.sin(t * 6 * math.pi) * .035;
    final shape = Path()
      ..moveTo(.10, -.47 - lick)
      // Down into the notch, then out over the left shoulder.
      ..cubicTo(.03, -.31, -.05, -.26, -.09, -.31)
      ..cubicTo(-.17, -.15, -.30, -.05, -.30, .13)
      ..cubicTo(-.30, .33, -.14, .43, .04, .41)
      ..cubicTo(.24, .39, .33, .24, .30, .06)
      ..cubicTo(.27, -.14, .18, -.31, .10, -.47 - lick)
      ..close();
    final b = shape.getBounds();
    canvas.drawPath(
      shape,
      _radial(
        b,
        const Offset(0, .22),
        [
          Color.lerp(EmberPalette.light, color, .18)!.withValues(alpha: dim ? .32 : .96),
          color.withValues(alpha: dim ? .24 : .88),
          Color.lerp(color, EmberPalette.deep, .62)!.withValues(alpha: dim ? .20 : .70),
        ],
        const [0, .48, 1],
      ),
    );
    if (dim) return;
    canvas.drawPath(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.2)
        ..color = EmberPalette.light.withValues(alpha: .26),
    );
    if (detail < 1) return;
    // The hot core.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.01, .18), width: .19, height: .27),
      _soft(Color.lerp(EmberPalette.light, color, .22)!.withValues(alpha: .62), .055),
    );
  }

  /// A river stone: wider than it is tall with a settled base and one seam.
  /// Quiet and steady, and nothing like the soft bodies around it.
  void _shell(Canvas canvas) {
    final shape = Path()
      ..moveTo(-.31, .14)
      ..cubicTo(-.35, -.11, -.19, -.30, .02, -.30)
      ..cubicTo(.25, -.30, .37, -.11, .32, .13)
      ..cubicTo(.29, .25, .22, .29, .0, .29)
      ..cubicTo(-.22, .29, -.28, .25, -.31, .14)
      ..close();
    canvas.drawPath(shape, _skin(shape.getBounds(), const Offset(-.10, -.20)));
    if (dim) return;
    canvas.drawPath(
      Path()
        ..moveTo(-.26, -.06)
        ..quadraticBezierTo(-.02, -.16, .24, -.02),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.3)
        ..strokeCap = StrokeCap.round
        ..color = EmberPalette.paperShade.withValues(alpha: .34),
    );
  }

  /// A soft drop: plump and wider than it is tall, with a short neck at the top
  /// and a wet highlight. It squashes as it settles, which is the whole point.
  void _drop(Canvas canvas) {
    final squash = still ? 0.0 : math.sin(t * 4 * math.pi) * .035;
    final w = .30 * (1 + squash); // half-width at the belly
    final bottom = .38 * (1 - squash);
    final top = -.19 + squash * .5; // the neck shortens as the belly spreads
    final shape = Path()
      ..moveTo(-.02, top)
      ..cubicTo(.13, top + .10, w, -.04, w, .08)
      ..cubicTo(w, bottom - .09, .17, bottom, -.02, bottom)
      ..cubicTo(-.21, bottom, -w - .01, bottom - .10, -w, .07)
      ..cubicTo(-w + .01, -.05, -.14, top + .11, -.02, top)
      ..close();
    canvas.drawPath(shape, _skin(shape.getBounds(), const Offset(-.09, -.12)));
    if (dim) return;
    canvas.drawPath(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.1)
        ..strokeCap = StrokeCap.round
        ..color = EmberPalette.rim.withValues(alpha: .22),
    );
    if (detail < 2) return;
    // A wet highlight: the one thing that says liquid rather than fur.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(-.14, -.06), width: .09, height: .16),
      _soft(EmberPalette.light.withValues(alpha: .34), .035),
    );
  }

  /// Combs, not clubs: a moth's antennae are feathers swept back off the head.
  void _combs(Canvas canvas) {
    final shaft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _px(1.4)
      ..strokeCap = StrokeCap.round
      ..color = Color.lerp(EmberPalette.furLight, color, dim ? 0 : .2)!.withValues(alpha: dim ? .3 : .8);
    for (final s in const [-1.0, 1.0]) {
      final start = Offset(s * .055, -.30);
      final ctl = Offset(s * .19, -.42);
      final tip = Offset(s * (.31 + (look?.dx ?? 0) * .03 * s), -.33 + (look?.dy ?? 0) * .02);
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..quadraticBezierTo(ctl.dx, ctl.dy, tip.dx, tip.dy),
        shaft,
      );
      if (detail < 2 || dim) continue;
      final teeth = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(.8)
        ..strokeCap = StrokeCap.round
        ..color = EmberPalette.furLight.withValues(alpha: .5);
      for (var i = 1; i <= 5; i++) {
        final u = i / 6;
        final p = _quad(start, ctl, tip, u);
        final q = _quad(start, ctl, tip, (u + .08).clamp(0.0, 1.0));
        final n = Offset(-(q.dy - p.dy), q.dx - p.dx);
        if (n.distance == 0) continue;
        final out = (n / n.distance) * .020;
        canvas.drawLine(p - out, p + out, teeth);
      }
    }
  }

  // -- the face, shared by every body ---------------------------------------

  /// Face units are the figure's, moved and scaled by [fit], so one set of
  /// numbers gives the right face on a wide moth head and a narrow drop.
  void _face(Canvas canvas) {
    final f = fit;
    canvas.save();
    canvas.translate(f.centre.dx, f.centre.dy);
    canvas.scale(f.scale);

    final open = _blink();
    final lx = look?.dx ?? 0.0, ly = look?.dy ?? 0.0;
    // A pupil near centre already reads as eye contact, so the gaze is allowed
    // to be shy: it follows the mouse without rolling off the eye.
    final gaze = Offset(lx, ly) * .022;

    for (final s in const [-1.0, 1.0]) {
      final at = Offset(s * .108, 0);
      if (detail >= 2) _brow(canvas, s, at);
      if (open < .12) {
        // Shut: an arc. A big smile lifts the lids into upward arcs — the classic
        // happy squint — while a resting lid curves the other way.
        final happy = rig.mouth > .6;
        canvas.drawPath(
          Path()
            ..moveTo(at.dx - .055, at.dy + (happy ? .012 : -.004))
            ..quadraticBezierTo(
              at.dx,
              at.dy + (happy ? -.034 : .014),
              at.dx + .055,
              at.dy + (happy ? .012 : -.004),
            ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _px(1.9)
            ..strokeCap = StrokeCap.round
            ..color = dim ? EmberPalette.ash.withValues(alpha: .55) : EmberPalette.deep,
        );
        continue;
      }
      // The white is only ever a thin ring; the dark is the eye.
      canvas.drawOval(
        Rect.fromCenter(center: at, width: .118, height: .118 * open * 1.15),
        Paint()..color = EmberPalette.light.withValues(alpha: dim ? .20 : .92),
      );
      canvas.drawOval(
        Rect.fromCenter(center: at + gaze, width: .088, height: .094 * open * 1.15),
        Paint()..color = dim ? const Color(0xFF332C38) : EmberPalette.deep,
      );
      if (detail >= 1) {
        canvas.drawCircle(
          at + gaze + Offset(-.016, -.020),
          math.max(_px(1.1), .015),
          Paint()..color = Colors.white.withValues(alpha: dim ? .12 : .92),
        );
      }
    }

    if (detail >= 2) _cheeks(canvas);
    if (detail >= 1) _mouth(canvas);
    canvas.restore();
  }

  void _brow(Canvas canvas, double s, Offset at) {
    if (dim || rig.brow == 0 && rig.tilt == 0) return;
    // `brow` lifts both ends; `tilt` lifts the inner one, which is the worried
    // brow. Dropping it instead aims the brow at the nose — working, not sad.
    final lift = rig.brow * .010;
    final inner = at + Offset(-s * .055, -.082 - lift - rig.tilt * .028);
    final outer = at + Offset(s * .062, -.080 - lift + rig.tilt * .012);
    canvas.drawLine(
      inner,
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.6)
        ..strokeCap = StrokeCap.round
        ..color = Color.lerp(EmberPalette.furLight, EmberPalette.paperShade, .4)!.withValues(alpha: .9),
    );
  }

  void _cheeks(Canvas canvas) {
    if (dim) return;
    for (final s in const [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(s * .185, .052), width: .088, height: .052),
        _soft(EmberPalette.blush.withValues(alpha: .32), .024),
      );
    }
  }

  void _mouth(Canvas canvas) {
    final at = const Offset(0, .085);
    final m = rig.mouth;
    final ink = (dim ? EmberPalette.ash : EmberPalette.deep).withValues(alpha: .9);
    if (m > 1.5) {
      // Speaking: an open mouth sized by the voice, not a fixed shape.
      final o = .026 + level * .050;
      canvas.drawOval(
        Rect.fromCenter(center: at, width: .062, height: o * 2),
        Paint()..color = ink,
      );
      return;
    }
    if (m.abs() < .12) {
      canvas.drawLine(
        at - const Offset(.030, 0),
        at + const Offset(.030, 0),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _px(1.5)
          ..strokeCap = StrokeCap.round
          ..color = ink,
      );
      return;
    }
    canvas.drawPath(
      Path()
        ..moveTo(at.dx - .042, at.dy)
        ..quadraticBezierTo(at.dx, at.dy + m * .048, at.dx + .042, at.dy),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.7)
        ..strokeCap = StrokeCap.round
        ..color = ink,
    );
  }

  /// One blink per eight-second cycle.
  double _blink() {
    if (rig.eye <= .06) return 0;
    if (still) return rig.eye;
    final p = t % 1;
    if (p < .855 || p > .885) return rig.eye;
    // Ease the lids so a blink is a blink and not a flicker.
    return rig.eye * (1 - math.sin((p - .855) / .030 * math.pi));
  }

  // -- gestures on top ------------------------------------------------------

  void _signals(Canvas canvas) {
    if (dim) return;
    if (mood == Mood.waiting) {
      // A signal light, not a ring: an outlined circle over the head reads as an
      // antenna, and the creature already has a face to look at.
      final pulse = still ? .6 : (math.sin(t * 8 * math.pi) + 1) / 2;
      final at = Offset(0, fit.centre.dy - .31);
      final r = math.max(_px(1.6), .021);
      canvas.drawCircle(at, r * 2.4, _soft(color.withValues(alpha: .30 + .30 * pulse), r * 1.2));
      canvas.drawCircle(at, r, Paint()..color = EmberPalette.light.withValues(alpha: .55 + .45 * pulse));
    }
    if (mood == Mood.happy && !still) {
      final p = t % 1;
      if (p < .22) {
        final k = p / .22;
        final rays = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _px(1.5)
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: (1 - k) * .8);
        for (var i = 0; i < 7; i++) {
          final a = i / 7 * 2 * math.pi - 1.57;
          final d = .30 + k * .16;
          canvas.drawLine(
            Offset(math.cos(a) * d, math.sin(a) * d - .05),
            Offset(math.cos(a) * (d + .06), math.sin(a) * (d + .06) - .05),
            rays,
          );
        }
      }
    }
  }

  // -- material -------------------------------------------------------------

  /// The body's own skin: cream fur, lit from wherever the light falls on it.
  Paint _skin(Rect b, Offset litAt) {
    if (dim) {
      return _radial(
        b,
        litAt,
        [const Color(0xFF3E3646).withValues(alpha: .95), EmberPalette.ash.withValues(alpha: .85)],
        const [0, 1],
      );
    }
    final lit = Color.lerp(EmberPalette.paper, EmberPalette.light, .32)!;
    final mid = Color.lerp(EmberPalette.paper, color, .16)!;
    final edge = Color.lerp(mid, EmberPalette.paperShade, .44)!;
    return _radial(
      b,
      litAt,
      [lit.withValues(alpha: .98), mid.withValues(alpha: .98), edge.withValues(alpha: .92)],
      const [0, .52, 1],
    );
  }
}

Offset _quad(Offset a, Offset c, Offset b, double t) {
  final u = 1 - t;
  return a * (u * u) + c * (2 * u * t) + b * (t * t);
}

/// A radial fill anchored at a point *inside* the shape. Flutter measures a
/// gradient radius against the rect's shortest side, so the radius has to be
/// worked out from the farthest corner — otherwise the outer third of a wide
/// shape never gets past the first colour stop and the body reads as a band.
Paint _radial(Rect b, Offset at, List<Color> colors, List<double> stops) {
  if (b.isEmpty) return Paint()..color = colors.first;
  final far = [
    b.topLeft,
    b.topRight,
    b.bottomLeft,
    b.bottomRight,
  ].map((c) => (c - at).distance).reduce(math.max);
  final side = math.min(b.width, b.height);
  return Paint()
    ..shader = RadialGradient(
      center: Alignment(
        ((at.dx - b.left) / b.width * 2 - 1).clamp(-1.0, 1.0),
        ((at.dy - b.top) / b.height * 2 - 1).clamp(-1.0, 1.0),
      ),
      radius: side == 0 ? 1.0 : (far / side).clamp(1.0, 2.6),
      colors: colors,
      stops: stops,
    ).createShader(b);
}

/// A blur that is never asked to blur a fraction of a pixel.
Paint _soft(Color color, double sigma) => Paint()
  ..color = color
  ..maskFilter = sigma < .004 ? null : MaskFilter.blur(BlurStyle.normal, sigma);

// ---------------------------------------------------------------------------
// The two views. Both hand the same _Figure a transform and nothing else, so
// the dock chip and the phone's full screen are the same creature.
// ---------------------------------------------------------------------------

/// Figure units per device pixel, and the detail level that falls out of it.
({int detail, double unit}) _fitScale(double span) => (
  detail: span >= 64 ? 2 : (span >= 30 ? 1 : 0),
  unit: 1 / span,
);

class EmberPainter extends CustomPainter {
  EmberPainter({
    required this.body,
    required this.mood,
    required this.previous,
    required this.blend,
    required this.jobs,
    required this.t,
    required this.still,
    required this.look,
    required this.level,
    this.reach,
  });

  final CompiiBody body;
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;
  final bool still;
  final Offset? look;
  final double level;
  final Offset? reach;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final dim = mood == Mood.offline;
    final color = Color.lerp(EmberPalette.core(previous), EmberPalette.core(mood), blend)!;
    final span = s * .86;
    final centre = Offset(size.width / 2, size.height / 2 - s * .02);

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centre.dx, centre.dy + span * .44),
        width: span * .46,
        height: span * .08,
      ),
      _soft(EmberPalette.deep.withValues(alpha: dim ? .12 : .34), span * .018),
    );
    if (reach != null) _reach(canvas, centre, s);

    final f = _fitScale(span);
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(span);
    _Figure(
      body: body,
      rig: _Rig.mix(_Rig.of(previous), _Rig.of(mood), blend),
      mood: mood,
      t: t,
      still: still,
      jobs: jobs,
      level: level,
      look: look,
      detail: f.detail,
      unit: f.unit,
      color: color,
      dim: dim,
    ).draw(canvas);
    canvas.restore();
  }

  /// A thread of light to the thing being pointed at, drawn in the widget's own
  /// space so it can fall outside the figure's square.
  void _reach(Canvas canvas, Offset centre, double s) {
    final to = reach! * s;
    final d = to - centre;
    if (d.distance < s * .04) return;
    final end = centre + d * .92;
    canvas.drawLine(
      centre + d * .18,
      end,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.4, s * .012)
        ..strokeCap = StrokeCap.round
        ..color = EmberPalette.light.withValues(alpha: .34),
    );
    canvas.drawCircle(end, math.max(2.4, s * .022), Paint()..color = EmberPalette.light);
  }

  @override
  bool shouldRepaint(covariant EmberPainter old) =>
      old.body != body ||
      old.mood != mood ||
      old.previous != previous ||
      old.blend != blend ||
      old.jobs != jobs ||
      old.t != t ||
      old.still != still ||
      old.look != look ||
      old.level != level ||
      old.reach != reach;
}

class EmberFacePainter extends CustomPainter {
  EmberFacePainter({
    required this.body,
    required this.mood,
    required this.previous,
    required this.blend,
    required this.jobs,
    required this.t,
    required this.still,
    required this.look,
    required this.level,
  });

  final CompiiBody body;
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;
  final bool still;
  final Offset? look;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = mood == Mood.offline;
    final color = Color.lerp(EmberPalette.core(previous), EmberPalette.core(mood), blend)!;
    final u = size.shortestSide;

    // The room, warmed by whatever Compii is doing.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -.15),
          radius: 1.25,
          colors: [
            Color.lerp(EmberPalette.room, color, dim ? .02 : .12)!,
            const Color(0xFF0A0710),
            const Color(0xFF050308),
          ],
          stops: const [0, .62, 1],
        ).createShader(Offset.zero & size),
    );
    _dust(canvas, size, color, dim);

    final span = u * .58;
    final centre = Offset(size.width / 2, size.height * .47);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centre.dx, centre.dy + span * .46),
        width: span * .5,
        height: span * .09,
      ),
      _soft(EmberPalette.deep.withValues(alpha: dim ? .18 : .42), span * .020),
    );

    final f = _fitScale(span);
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(span);
    _Figure(
      body: body,
      rig: _Rig.mix(_Rig.of(previous), _Rig.of(mood), blend),
      mood: mood,
      t: t,
      still: still,
      jobs: jobs,
      level: level,
      look: look,
      detail: f.detail,
      unit: f.unit,
      color: color,
      dim: dim,
    ).draw(canvas);
    canvas.restore();
  }

  /// Dust in the light, so the close-up is a place and not an icon on a page.
  void _dust(Canvas canvas, Size size, Color color, bool dim) {
    if (dim) return;
    for (var i = 0; i < 26; i++) {
      final seed = (i * 97 % 89) / 89;
      final rise = still ? seed : (t * (.10 + seed * .16) + seed) % 1;
      final x = (i.isEven ? seed : 1 - seed) * size.width;
      final y = size.height * (1.05 - rise * 1.1);
      final r = size.shortestSide * (.0016 + .0022 * ((i * 31) % 7 / 7));
      canvas.drawCircle(
        Offset(x + math.sin(rise * 6 + i) * size.shortestSide * .012, y),
        r,
        Paint()
          ..color = Color.lerp(color, EmberPalette.light, .5)!
              .withValues(alpha: .10 + .10 * (1 - rise)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant EmberFacePainter old) =>
      old.body != body ||
      old.mood != mood ||
      old.previous != previous ||
      old.blend != blend ||
      old.jobs != jobs ||
      old.t != t ||
      old.still != still ||
      old.look != look ||
      old.level != level;
}
