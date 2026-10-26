import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../art/halo.dart';

export '../art/halo.dart' show HaloForm, HaloFormInfo;

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

/// Compii's body: one of the glass forms. The eyes and the moods are the same
/// in every one; the form is taste. The picker shows the shape and never a
/// name — [HaloFormInfo.desc] is for screen readers.
typedef CompiiBody = HaloForm;

/// What Compii looks like, chosen in Settings and kept on this PC. The colour is
/// any colour; blue is only where it starts.
final compiiBody = ValueNotifier<CompiiBody>(HaloForm.orb);
final compiiColor = ValueNotifier<Color>(haloBlue);

/// Coat names the earlier builds saved, so a returning user keeps their colour.
const _legacyCoats = <String, Color>{
  'blue': haloBlue,
  'mint': Color(0xFF3DD68C),
  'lilac': Color(0xFF7A6BFF),
  'rose': Color(0xFFFF6FAE),
  'amber': Color(0xFFFF9C3D),
  'cream': Color(0xFFEEE4D4),
};

/// Old body names, mapped to the creature closest in spirit.
const _legacyBodies = <String, HaloForm>{
  'plush': HaloForm.orb,
  'moth': HaloForm.gem,
  'spark': HaloForm.tile,
  'shell': HaloForm.tower,
  'drop': HaloForm.pill,
  'puff': HaloForm.orb,
  'tuft': HaloForm.tile,
  'mop': HaloForm.pill,
  'horn': HaloForm.gem,
  'wisp': HaloForm.gem,
  'bean': HaloForm.tower,
};

/// Reads the saved form and colour into [compiiBody] and [compiiColor]. Names
/// that no longer exist fall back to the defaults rather than throwing. The
/// island runs in its own process and calls this again to follow changes.
void restoreCompiiLook(SharedPreferences p) {
  final form = p.getString('compii_form');
  if (form != null) {
    compiiBody.value = HaloForm.values.asNameMap()[form] ?? _legacyBodies[form] ?? HaloForm.orb;
  }
  final coat = p.getString('compii_coat');
  if (coat != null) {
    compiiColor.value = parseHex(coat) ?? _legacyCoats[coat] ?? haloBlue;
  }
}

/// The island and the cursor overlay run as their own processes, so the form and
/// colour chosen in the main window reach them through the saved preferences:
/// read now and re-read every few seconds, which is cheap and keeps every
/// surface in the chosen colour.
void followCompiiLook({Duration every = const Duration(seconds: 4)}) {
  Future<void> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      restoreCompiiLook(p);
    } on Object {
      // Preferences unreadable: the default look stays.
    }
  }

  read();
  Timer.periodic(every, (_) => read());
}

/// Compii is a piece of black glass with two eyes of light and a halo, in a
/// form and colour you choose. The eyes carry *feeling*; the halo carries effort. The lights beside it carry *work* — one per
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

/// The fixed materials of the room. The coat comes from [compiiColor] and the
/// state colour from [core]; nothing in here is a body colour.
class EmberPalette {
  static const ash = Color(0xFF241D2A);
  static const deep = Color(0xFF120D16);
  static const room = Color(0xFF1C1322);

  /// Focus rings and the overlay frame — the product's indigo, not the creature's.
  static const frame = Color(0xFF6B5FFF);
  static const light = Color(0xFFFFF0D8);
  static const gold = Color(0xFFFFC86B);

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
    this.color,
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

  /// Overrides [compiiColor] for a one-off render.
  final Color? color;

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
  /// looping GIF. Drift carries the blink and the slow lean-over.
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

  /// The head follows the pointer with a little lag, like something with weight.
  Offset _look = Offset.zero;

  @override
  void initState() {
    super.initState();
    compiiBody.addListener(_changed);
    compiiColor.addListener(_changed);
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
    compiiColor.removeListener(_changed);
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
          final target = widget.followPointer ? (_target(context) ?? Offset.zero) : Offset.zero;
          _look = still ? target : Offset.lerp(_look, target, .18)!;
          final pose = HaloPose(
            mood: widget.mood,
            previous: previous,
            blend: b,
            t: still ? widget.phase : clock.value,
            s: still ? widget.phase : drift.value,
            still: still,
            look: _look,
            level: widget.level,
            jobs: widget.jobs,
            moodColor: Color.lerp(EmberPalette.core(previous), EmberPalette.core(widget.mood), b),
          );
          final body = widget.body ?? compiiBody.value;
          final color = widget.color ?? compiiColor.value;
          return CustomPaint(
            size: Size.infinite,
            painter: widget.face
                ? EmberFacePainter(body: body, color: color, pose: pose)
                : EmberPainter(body: body, color: color, pose: pose, reach: widget.reach),
          );
        },
      ),
    );
  }

  /// Direction from the character to the mouse, -1..1 on each axis.
  Offset? _target(BuildContext context) {
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

class EmberPainter extends CustomPainter {
  EmberPainter({required this.body, required this.color, required this.pose, this.reach});

  final CompiiBody body;
  final Color color;
  final HaloPose pose;
  final Offset? reach;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final centre = Offset(size.width / 2, size.height / 2 - s * .02);
    if (reach != null) _reach(canvas, centre, s);
    Halo.paint(canvas, centre: centre, span: s * .86, form: body, color: color, pose: pose);
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
      old.body != body || old.color != color || old.reach != reach || _changedPose(old.pose, pose);
}

bool _changedPose(HaloPose a, HaloPose b) =>
    a.mood != b.mood ||
    a.previous != b.previous ||
    a.blend != b.blend ||
    a.t != b.t ||
    a.s != b.s ||
    a.still != b.still ||
    a.look != b.look ||
    a.level != b.level ||
    a.jobs != b.jobs;

/// The close-up: Compii in its room, warmed by whatever it is doing.
class EmberFacePainter extends CustomPainter {
  EmberFacePainter({required this.body, required this.color, required this.pose});

  final CompiiBody body;
  final Color color;
  final HaloPose pose;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = pose.mood == Mood.offline;
    final light = pose.moodColor ?? EmberPalette.core(pose.mood);
    final u = size.shortestSide;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -.15),
          radius: 1.25,
          colors: [
            Color.lerp(EmberPalette.room, color, dim ? .03 : .16)!,
            const Color(0xFF0A0710),
            const Color(0xFF050308),
          ],
          stops: const [0, .62, 1],
        ).createShader(Offset.zero & size),
    );
    _dust(canvas, size, light, dim);
    Halo.paint(
      canvas,
      centre: Offset(size.width / 2, size.height * .47),
      span: u * .62,
      form: body,
      color: color,
      pose: pose,
    );
  }

  /// Dust in the light, so the close-up is a place and not an icon on a page.
  void _dust(Canvas canvas, Size size, Color color, bool dim) {
    if (dim) return;
    for (var i = 0; i < 26; i++) {
      final seed = (i * 97 % 89) / 89;
      final rise = pose.still ? seed : (pose.t * (.10 + seed * .16) + seed) % 1;
      final x = (i.isEven ? seed : 1 - seed) * size.width;
      final y = size.height * (1.05 - rise * 1.1);
      final r = size.shortestSide * (.0016 + .0022 * ((i * 31) % 7 / 7));
      canvas.drawCircle(
        Offset(x + math.sin(rise * 6 + i) * size.shortestSide * .012, y),
        r,
        Paint()..color = Color.lerp(color, EmberPalette.light, .5)!.withValues(alpha: .10 + .10 * (1 - rise)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant EmberFacePainter old) =>
      old.body != body || old.color != color || _changedPose(old.pose, pose);
}
