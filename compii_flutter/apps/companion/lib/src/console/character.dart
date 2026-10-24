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
  /// Screen readers only. The picker shows the shape and never a name.
  String get desc => switch (this) {
    CompiiBody.plush => 'Round head on a small body',
    CompiiBody.moth => 'Wings folded over a furry back',
    CompiiBody.spark => 'A small flame',
    CompiiBody.shell => 'A smooth stone',
    CompiiBody.drop => 'A soft drop',
  };
}

/// The coat Compii is brushed in. Blue is the default: Compii lives in a dark
/// indigo room, and a cool coat is the one that reads as light falling on fur
/// rather than as a warm blob going muddy against a warm light.
enum CompiiCoat { blue, mint, lilac, rose, amber, cream }

extension CompiiCoatInfo on CompiiCoat {
  /// The mid tone. Everything else about the coat is derived from it.
  Color get base => switch (this) {
    CompiiCoat.blue => const Color(0xFF7FB4E8),
    CompiiCoat.mint => const Color(0xFF83E0BC),
    CompiiCoat.lilac => const Color(0xFFB7A6F2),
    CompiiCoat.rose => const Color(0xFFF2A2B4),
    CompiiCoat.amber => const Color(0xFFF5C179),
    CompiiCoat.cream => const Color(0xFFEEDDBE),
  };

  String get desc => switch (this) {
    CompiiCoat.blue => 'Blue',
    CompiiCoat.mint => 'Mint',
    CompiiCoat.lilac => 'Lilac',
    CompiiCoat.rose => 'Rose',
    CompiiCoat.amber => 'Amber',
    CompiiCoat.cream => 'Cream',
  };

  /// The picker swatch: the same three tones the fur is brushed with, so the
  /// chip is the coat and not a flat dot.
  List<Color> get chip => [
    Color.lerp(base, Colors.white, .52)!,
    base,
    Color.lerp(base, EmberPalette.ash, .62)!,
  ];
}

/// What Compii looks like, chosen in Settings and kept on this PC.
final compiiBody = ValueNotifier<CompiiBody>(CompiiBody.plush);
final compiiCoat = ValueNotifier<CompiiCoat>(CompiiCoat.blue);

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

/// The fixed materials. The coat comes from [CompiiCoat] and the state colour
/// from [core]; nothing in here is a body colour.
class EmberPalette {
  static const ash = Color(0xFF241D2A);
  static const deep = Color(0xFF120D16);
  static const room = Color(0xFF1C1322);

  /// The cool edge, so a warm coat never turns to jam against a warm light.
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

/// One coat resolved into the five tones the fur is brushed with. The state
/// colour tints the mid tones so the light shows *through* the coat instead of
/// sitting on it as a badge; the tips stay the coat's own, which is what keeps
/// six different coats from all looking like the same lamp.
class _Coat {
  const _Coat({
    required this.hue,
    required this.tip,
    required this.lit,
    required this.base,
    required this.shade,
    required this.dark,
  });

  /// The colour the coat was brushed in, before the state tinted it. The flame
  /// body needs it to stay recognisably the user's choice.
  final Color hue, tip, lit, base, shade, dark;

  static _Coat of(CompiiCoat coat, Color mood) => _Coat(
    hue: coat.base,
    tip: Color.lerp(coat.base, Colors.white, .88)!,
    lit: Color.lerp(coat.base, Colors.white, .52)!,
    base: Color.lerp(coat.base, mood, .13)!,
    shade: Color.lerp(Color.lerp(coat.base, EmberPalette.ash, .62)!, mood, .16)!,
    dark: Color.lerp(coat.base, EmberPalette.deep, .82)!,
  );

  /// A coat made of the state colour itself — the one body whose material *is*
  /// the light inside it. It runs a deeper ramp than the fur coats, because a
  /// flame is read through its value range rather than its hue: the idle colour
  /// is pale sand, and a flame the same colour as sand is a potato.
  ///
  /// The value ramp does the state's work and the chosen coat keeps the hue. The
  /// earlier version mixed the state into the mid tones, which turned a blue
  /// coat to grey mud on the body most people wear; now the coat owns the crown
  /// and the whole shaded side of the flame, and only the burn at its foot —
  /// [dark], which is what the occlusion and the undercoat are brushed with —
  /// belongs to the state.
  static _Coat flame(Color mood, Color hue) => _Coat(
    hue: hue,
    tip: Color.lerp(hue, Colors.white, .86)!,
    lit: Color.lerp(hue, Colors.white, .46)!,
    base: Color.lerp(Color.lerp(hue, EmberPalette.ash, .30)!, mood, .14)!,
    shade: Color.lerp(Color.lerp(hue, EmberPalette.deep, .55)!, mood, .12)!,
    dark: Color.lerp(mood, EmberPalette.deep, .74)!,
  );
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
    this.coat,
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

  /// Overrides [compiiCoat] for a one-off render.
  final CompiiCoat? coat;

  @override
  State<Ember> createState() => _EmberState();
}

class _EmberState extends State<Ember> with TickerProviderStateMixin {
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  /// A second clock on purpose 37 seconds long — not a multiple of the first.
  /// The eight-second cycle is the breath and has to stay regular, but anything
  /// hung off it blinks on the beat, and a creature that blinks on the beat is a
  /// looping GIF. Drift carries the blink and the slow lean-over, the two things
  /// that must never look scheduled.
  late final AnimationController drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 37),
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
    compiiCoat.addListener(_changed);
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
    compiiCoat.removeListener(_changed);
    clock.dispose();
    drift.dispose();
    blend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = !widget.animate || MediaQuery.of(context).disableAnimations;
    if (still) {
      clock.stop();
      drift.stop();
    } else {
      if (!clock.isAnimating) clock.repeat();
      if (!drift.isAnimating) drift.repeat();
    }
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([clock, drift, blend, if (widget.followPointer) pointer]),
        builder: (context, _) {
          final b = Curves.easeOutCubic.transform(blend.value).clamp(0.0, 1.0);
          final t = still ? widget.phase : clock.value;
          final s = still ? widget.phase : drift.value;
          final look = widget.followPointer ? _look(context) : null;
          return CustomPaint(
            size: Size.infinite,
            painter: widget.face
                ? EmberFacePainter(
                    body: widget.body ?? compiiBody.value,
                    coat: widget.coat ?? compiiCoat.value,
                    mood: widget.mood,
                    previous: previous,
                    blend: b,
                    jobs: widget.jobs,
                    t: t,
                    s: s,
                    still: still,
                    look: look,
                    level: widget.level,
                  )
                : EmberPainter(
                    body: widget.body ?? compiiBody.value,
                    coat: widget.coat ?? compiiCoat.value,
                    mood: widget.mood,
                    previous: previous,
                    blend: b,
                    jobs: widget.jobs,
                    t: t,
                    s: s,
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
///
/// The numbers are deliberately bigger than they look on paper. Half of these
/// characters are seen at 30-44 px in a row or a sidebar, where a brow that moves
/// a pixel is not a brow at all — so each mood is set so it still reads there,
/// then checked against the character sheet at every size.
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
    // Ready: nothing is happening, and that is fine. The only face without brows.
    Mood.idle => const _Rig(brow: 0, tilt: 0, eye: 1, mouth: .35, bob: .016, lean: 0),
    // Listening: wide and tipped toward the sound, brows up.
    Mood.listening => const _Rig(brow: .75, tilt: .2, eye: 1.3, mouth: .08, bob: .022, lean: -.06),
    // Thinking: eyes down and away, one brow up, weight on one side. Looking in.
    Mood.thinking => const _Rig(brow: .42, tilt: -.18, eye: .56, mouth: .0, bob: .008, lean: .09),
    // Working: narrowed and steady. Not unhappy — aimed, so the brows stay almost
    // flat. A lowered brow at hero size reads as annoyed, and annoyed is not a
    // thing a companion should look like while it is doing what you asked.
    Mood.acting => const _Rig(brow: -.08, tilt: -.26, eye: .62, mouth: .12, bob: .034, lean: 0),
    // Speaking: an open mouth sized by the voice.
    Mood.speaking => const _Rig(brow: .24, tilt: .06, eye: 1.05, mouth: 2, bob: .02, lean: 0),
    // Needs you: brows up and pulled together — the classic worried face, and the
    // only mood that leans back off whatever it is looking at.
    Mood.waiting => const _Rig(brow: .9, tilt: 1.05, eye: 1.28, mouth: -.5, bob: .014, lean: -.05),
    // Done: eyes closed into arcs and a big smile. The one happy face.
    Mood.happy => const _Rig(brow: .55, tilt: 0, eye: .05, mouth: .95, bob: .055, lean: 0),
    // Problem: brows down and in, mouth turned down, nothing else moving.
    Mood.problem => const _Rig(brow: -.85, tilt: -.95, eye: .56, mouth: -.6, bob: 0, lean: .03),
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
    required this.s,
    required this.still,
    required this.jobs,
    required this.level,
    required this.look,
    required this.detail,
    required this.unit,
    required this.coat,
    required this.color,
    required this.dim,
  });

  final CompiiBody body;
  final _Rig rig;
  final Mood mood;
  final double t;

  /// 0..1 around the slow 37-second cycle: blink and the long lean.
  final double s;
  final bool still;
  final int jobs;
  final double level;
  final Offset? look;

  /// 0 chip, 1 bar, 2 close-up. Detail adds and removes parts; it never blurs.
  final int detail;

  /// One device pixel in figure units, so a hairline stays a hairline at 18 px.
  final double unit;

  /// The fur the creature is brushed in.
  final _Coat coat;
  final Color color;
  final bool dim;

  double _px(double n) => math.max(unit * n, .004);

  /// Where the key light sits, in figure units. It slides as Compii looks at the
  /// cursor, which is what makes the body read as a volume turning in the room
  /// rather than a flat shape with a gradient painted on it.
  late final Offset key = Offset(
    -.13 + (look?.dx ?? 0) * .075,
    -.30 + (look?.dy ?? 0) * .055,
  );

  /// How each body carries itself: how fast it breathes, how far it drifts
  /// sideways, and how much of the rig's bob it actually takes. Five bodies on
  /// one beat are one body drawn five ways — the plush hops, the moth hovers,
  /// the flame gutters, the stone only settles, and the drop wobbles half a beat
  /// behind itself.
  late final ({int rate, double sway, double hop}) tempo = switch (body) {
    CompiiBody.plush => (rate: 1, sway: 1, hop: 1),
    CompiiBody.moth => (rate: 2, sway: .5, hop: 1.5),
    CompiiBody.spark => (rate: 3, sway: .8, hop: 1.25),
    CompiiBody.shell => (rate: 1, sway: .55, hop: .45),
    CompiiBody.drop => (rate: 2, sway: 1.5, hop: .9),
  };

  /// Sideways drift in figure units: the breath, the long lean on the slow
  /// cycle, and wherever the mood is throwing its weight.
  late final double sway = still
      ? rig.lean
      : math.sin(t * 2 * math.pi * tempo.rate) * .010 * tempo.sway +
            math.sin(s * 2 * math.pi) * .008 +
            rig.lean;

  /// The idle life in the body: a drift and a bob, the bob from the rig.
  late final Offset seat = Offset(
    sway,
    still ? 0 : math.sin(t * 4 * math.pi) * rig.bob * tempo.hop,
  );

  /// A few degrees, and the reason the drift is worth having at all: a body that
  /// slides sideways is a sticker, a body that tips is a weight on its feet.
  late final double rock = (sway - rig.lean) * 3.0 + rig.lean * .6;

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
    if (rock != 0) {
      // Pivoted at the feet, not at the middle.
      canvas.translate(0, .42);
      canvas.rotate(rock);
      canvas.translate(0, -.42);
    }
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

  /// A union of ovals, so the outline is the silhouette. Drawn as separate
  /// sub-paths, the fur would sprout along the seams where two lobes of the same
  /// body overlap instead of only around the edge of the creature.
  Path _blob(Iterable<Rect> ovals) => ovals
      .map((r) => Path()..addOval(r))
      .reduce((a, b) => Path.combine(PathOperation.union, a, b));

  /// The default: a big round head, a small soft body, two stubby feet. No ears,
  /// no wings, no shell — nothing that names a species and can therefore be wrong.
  void _plush(Canvas canvas) {
    final shape = _blob([
      Rect.fromCenter(center: const Offset(0, .185), width: .40, height: .34),
      Rect.fromCenter(center: const Offset(0, -.155), width: .56, height: .53),
      for (final s in const [-1.0, 1.0])
        Rect.fromCenter(center: Offset(s * .115, .345), width: .15, height: .085),
    ]);
    _furred(canvas, shape, nap: .036);
    if (dim || detail < 2) return;
    // The chin throws a shadow onto the chest. Without it the head sits *on* the
    // body rather than growing out of it.
    canvas.save();
    canvas.clipPath(shape);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.01, .022), width: .40, height: .11),
      _soft(coat.dark.withValues(alpha: .22), .030),
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
      ..cubicTo(.30 + beat, -.27, .40 + beat, -.04, .23, .19)
      ..cubicTo(.11, .30, -.11, .30, -.23, .19)
      ..cubicTo(-.40 - beat, -.04, -.30 - beat, -.27, 0, -.30)
      ..close();
    // A moth's wings are scaled, not bare: the edge is a fringe, and it is the
    // shortest fur on the creature.
    _furred(canvas, roof, nap: .010);
    if (!dim) {
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
        _soft(coat.shade.withValues(alpha: .34), .045),
      );
      if (detail >= 2) {
        // One soft crease where the two wings meet, and nothing else: straight
        // vein lines across the tent read as a ladder, not as a wing.
        canvas.drawLine(
          const Offset(.005, -.28),
          const Offset(.02, .30),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = _px(2.6)
            ..color = coat.shade.withValues(alpha: .22),
        );
      }
      canvas.restore();
    }
    // Abdomen, thorax, head: the thorax is the fattest thing about the creature.
    final body = _blob([
      Rect.fromCenter(center: const Offset(0, .20), width: .175, height: .28),
      Rect.fromCenter(center: const Offset(0, -.04), width: .26, height: .30),
      Rect.fromCenter(center: const Offset(0, -.235), width: .19, height: .17),
    ]);
    _furred(canvas, body, nap: .034);
    if (!dim && detail >= 1) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(.9)
        ..color = coat.dark.withValues(alpha: .34);
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
    final flame = _Coat.flame(color, coat.hue);
    final b = shape.getBounds();
    _furred(
      canvas,
      shape,
      nap: .012,
      mat: flame,
      // Lit from inside, from the base up — the opposite of the fur bodies.
      fill: _radial(b, const Offset(0, .22), [
        flame.tip.withValues(alpha: dim ? .32 : .96),
        flame.lit.withValues(alpha: dim ? .26 : .93),
        flame.base.withValues(alpha: dim ? .24 : .88),
        flame.shade.withValues(alpha: dim ? .20 : .76),
      ], const [0, .26, .60, 1]),
    );
    if (dim || detail < 1) return;
    // The hot core.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(.01, .18), width: .19, height: .27),
      _soft(flame.tip.withValues(alpha: .55), .055),
    );
  }

  /// A river stone: wider than it is tall with a settled base and one seam.
  /// Felted rather than furry — a short nap, so it stays the quiet one.
  void _shell(Canvas canvas) {
    final shape = Path()
      ..moveTo(-.31, .14)
      ..cubicTo(-.35, -.11, -.19, -.30, .02, -.30)
      ..cubicTo(.25, -.30, .37, -.11, .32, .13)
      ..cubicTo(.29, .25, .22, .29, .0, .29)
      ..cubicTo(-.22, .29, -.28, .25, -.31, .14)
      ..close();
    _furred(canvas, shape, nap: .009);
    if (dim) return;
    canvas.drawPath(
      Path()
        ..moveTo(-.26, -.06)
        ..quadraticBezierTo(-.02, -.16, .24, -.02),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.3)
        ..strokeCap = StrokeCap.round
        ..color = coat.dark.withValues(alpha: .28),
    );
  }

  /// A soft drop: plump and wider than it is tall, with a short neck at the top.
  /// It squashes as it settles, which drags the whole coat with it.
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
    _furred(canvas, shape, nap: .024);
  }

  /// Combs, not clubs: a moth's antennae are feathers swept back off the head.
  void _combs(Canvas canvas) {
    final shaft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _px(1.4)
      ..strokeCap = StrokeCap.round
      ..color = (dim ? coat.shade : coat.dark).withValues(alpha: dim ? .3 : .85);
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
        ..color = coat.shade.withValues(alpha: .62);
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
        Paint()..color = coat.tip.withValues(alpha: dim ? .20 : .92),
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
    final lift = rig.brow * .016;
    final inner = at + Offset(-s * .046, -.080 - lift - rig.tilt * .038);
    final outer = at + Offset(s * .052, -.078 - lift + rig.tilt * .018);
    canvas.drawLine(
      inner,
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(1.5)
        ..strokeCap = StrokeCap.round
        ..color = coat.shade.withValues(alpha: .7),
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

  /// Where the blinks sit around the 37-second drift cycle, and how long each one
  /// takes. Six at uneven gaps, the last two a pair — the double blink people
  /// actually do when they are tired or thinking — so nothing about resting looks
  /// scheduled. `.007` of a 37-second cycle is a quarter of a second, which is a
  /// blink; anything longer is a wince.
  static const _blinks = <double>[.055, .19, .365, .52, .70, .727, .885];

  double _blink() {
    if (rig.eye <= .06) return 0;
    if (still) return rig.eye;
    for (final c in _blinks) {
      final d = (s % 1 - c).abs();
      if (d >= .007) continue;
      final k = 1 - d / .007;
      return rig.eye * (1 - k * k * (3 - 2 * k));
    }
    return rig.eye;
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

  /// One material for every body: a dark undercoat, a lit volume, and a topcoat
  /// of hairs whose tips catch the key light. `nap` is the hair length in figure
  /// units; zero leaves the shape smooth.
  void _furred(Canvas canvas, Path body, {double nap = 0, _Coat? mat, Paint? fill}) {
    final m = mat ?? coat;
    final b = body.getBounds();
    // A coat of two hundred hairs on an 18 px chip is grey mud. At that size the
    // gradient alone carries the fur.
    final fuzzy = nap > 0 && detail >= 1;
    final len = nap * (detail == 2 ? 1 : .74);
    if (!dim && fuzzy) {
      _hairs(canvas, b, body, len * .8, m, under: true);
    }
    canvas.drawPath(body, fill ?? _skin(b, m));
    if (dim) return;
    _volume(canvas, body, b, m);
    if (fuzzy) _hairs(canvas, b, body, len, m, under: false);
  }

  /// The body's own fur: lit where the key light falls, cool and dark at the
  /// terminator, and never a flat colour.
  Paint _skin(Rect b, _Coat m) {
    if (dim) {
      return _radial(
        b,
        key,
        [const Color(0xFF3E3646).withValues(alpha: .95), EmberPalette.ash.withValues(alpha: .85)],
        const [0, 1],
      );
    }
    return _radial(b, key, [
      m.lit.withValues(alpha: .99),
      m.base.withValues(alpha: .99),
      m.shade.withValues(alpha: .96),
      // The terminator stops short of black: a body that goes to near-black at its
      // own edge reads as a silhouette, and the fur tips have nothing to sit on.
      Color.lerp(m.shade, m.dark, .45)!.withValues(alpha: .93),
    ], const [0, .46, .84, 1]);
  }

  /// The three things that sell a lit volume: sheen where the light lands,
  /// occlusion where the body sinks into the floor, and back-lit hair along the
  /// edge the light never reaches.
  void _volume(Canvas canvas, Path body, Rect b, _Coat m) {
    if (b.isEmpty) return;
    canvas.save();
    canvas.clipPath(body);
    canvas.drawOval(
      Rect.fromCenter(center: key, width: b.width * .50, height: b.height * .34),
      _soft(m.tip.withValues(alpha: .26), b.shortestSide * .13),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(b.center.dx + (key.dx - b.center.dx) * .18, b.bottom - b.height * .03),
        width: b.width * .84,
        height: b.height * .30,
      ),
      _soft(m.dark.withValues(alpha: .30), b.height * .10),
    );
    // The rim is the only cool thing on the creature: it is the room's own light
    // bouncing off the far side, and it is what separates one body from the dark.
    canvas.clipRect(
      Rect.fromLTWH(b.right - b.width * .34, b.bottom - b.height * .52, b.width * .36, b.height * .54),
    );
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _px(2.8)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, b.shortestSide * .022)
        ..color = EmberPalette.rim.withValues(alpha: .30),
    );
    canvas.restore();
  }

  /// Fur, in the two passes a real coat is drawn with: the undercoat starts
  /// inside the outline so the body swallows its roots, and the topcoat starts on
  /// the outline so only lit tips stick out. The silhouette is a fringe, not a line.
  ///
  /// Every hair leaves the skin and then bends, because a hair that runs straight
  /// out from the body is a spine. The hairs are batched into five tone-paths and
  /// drawn once each, so a coat costs five draws, not two hundred.
  void _hairs(Canvas canvas, Rect b, Path body, double len, _Coat m, {required bool under}) {
    final n = detail == 2 ? (under ? 120 : 96) : (under ? 44 : 34);
    final paints = [
      _hair(m.dark, under ? .58 : .30, under),
      _hair(m.shade, under ? .62 : .58, under),
      _hair(m.base, under ? .55 : .82, under),
      _hair(m.lit, under ? .38 : .95, under),
      _hair(m.tip, under ? .22 : 1, under),
    ];
    final strokes = List.generate(5, (_) => Path());
    final centre = b.center;
    final far = math.max(b.width, b.height) * .5 + len;
    final sway = still ? 0.0 : math.sin(t * 4 * math.pi) * .22 + level * .4;
    var i = 0;
    for (final metric in body.computeMetrics()) {
      if (metric.length == 0) continue;
      for (var k = 0; k < n; k++) {
        final u = (k + _noise(i * 3 + (under ? 11 : 5))) / n * metric.length;
        final tan = metric.getTangentForOffset(u);
        if (tan == null) continue;
        final at = tan.position;
        var out = Offset(-tan.vector.dy, tan.vector.dx);
        if (out.distance == 0) continue;
        out /= out.distance;
        final from = at - centre;
        if (from.dx * out.dx + from.dy * out.dy < 0) out = -out;
        final j1 = _noise(i * 7 + 3), j2 = _noise(i * 13 + 1), j3 = _noise(i * 29 + 7);
        final l = len * (.55 + j2 * .62);
        // The tip falls with gravity and scatters sideways; the sway is the body
        // moving underneath the coat.
        var dir = out * (.5 + j1 * .5) + Offset((j3 - .5) * 1.15 + sway, .42 + j1 * .4);
        if (dir.distance == 0) continue;
        dir /= dir.distance;
        final lit = (1 - ((at - key).distance / far)).clamp(0.0, 1.0);
        strokes[(lit * 4).round()]
          ..moveTo(at.dx - out.dx * l * (under ? .4 : .03), at.dy - out.dy * l * (under ? .4 : .03))
          ..quadraticBezierTo(
            at.dx + out.dx * l * .5,
            at.dy + out.dy * l * .5,
            at.dx + dir.dx * l,
            at.dy + dir.dy * l,
          );
        i++;
      }
    }
    for (var s = 0; s < 5; s++) {
      canvas.drawPath(strokes[s], paints[s]);
    }
  }

  Paint _hair(Color color, double alpha, bool under) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = _px(under ? 1.1 : .85)
    ..color = color.withValues(alpha: alpha);
}

/// A stable pseudo-random 0..1 for one hair. The same index always gives the
/// same number, so the coat does not boil as the body moves.
double _noise(int seed) {
  var x = seed * 0x1b873593;
  x = (x ^ (x >> 15)) * 0x2c1b3c6d;
  x = (x ^ (x >> 12)) * 0x297a2d39;
  return ((x ^ (x >> 15)) & 0xffff) / 0xffff;
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
    required this.coat,
    required this.mood,
    required this.previous,
    required this.blend,
    required this.jobs,
    required this.t,
    required this.still,
    required this.look,
    required this.level,
    this.reach,
    this.s = 0,
  });

  final CompiiBody body;
  final CompiiCoat coat;
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;

  /// Where the 37-second drift cycle is. See [_EmberState.drift].
  final double s;
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
    final look = this.look ?? Offset.zero;

    // The cast shadow slides the other way from the key light, so the creature is
    // standing in a room with one lamp rather than floating over a grey smudge.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centre.dx - span * .05 - look.dx * span * .03, centre.dy + span * .44),
        width: span * .46,
        height: span * .08,
      ),
      _soft(EmberPalette.deep.withValues(alpha: dim ? .12 : .38), span * .018),
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
      s: s,
      still: still,
      jobs: jobs,
      level: level,
      look: look,
      detail: f.detail,
      unit: f.unit,
      coat: _Coat.of(coat, color),
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
      old.coat != coat ||
      old.mood != mood ||
      old.previous != previous ||
      old.blend != blend ||
      old.jobs != jobs ||
      old.t != t ||
      old.s != s ||
      old.still != still ||
      old.look != look ||
      old.level != level ||
      old.reach != reach;
}

class EmberFacePainter extends CustomPainter {
  EmberFacePainter({
    required this.body,
    required this.coat,
    required this.mood,
    required this.previous,
    required this.blend,
    required this.jobs,
    required this.t,
    required this.still,
    required this.look,
    required this.level,
    this.s = 0,
  });

  final CompiiBody body;
  final CompiiCoat coat;
  final Mood mood;
  final Mood previous;
  final double blend;
  final int jobs;
  final double t;

  /// Where the 37-second drift cycle is. See [_EmberState.drift].
  final double s;
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
      s: s,
      still: still,
      jobs: jobs,
      level: level,
      look: look,
      detail: f.detail,
      unit: f.unit,
      coat: _Coat.of(coat, color),
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
      old.coat != coat ||
      old.mood != mood ||
      old.previous != previous ||
      old.blend != blend ||
      old.jobs != jobs ||
      old.t != t ||
      old.s != s ||
      old.still != still ||
      old.look != look ||
      old.level != level;
}
