import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../art/halo.dart';
import '../console/character.dart' show compiiColor;
import '../ui/tokens.dart';
import 'island_controller.dart';

/// Compii's eyes, living in the island. They are the same eyes the creature
/// wears — glossy, with an iris in Compii's own colour and reflections that
/// stay put — set straight into the black capsule.
///
/// They are alive without being busy: they follow the pointer anywhere on the
/// desktop, blink on an irregular clock, and wear whatever the island is
/// actually doing. Nothing here is decoration standing in for state:
/// listening dilates the pupils with the real microphone level, needing you
/// widens them and turns the iris amber, done closes them into happy arcs,
/// failure narrows them, and offline shuts them. With reduced motion they
/// neither blink nor wander; they only change with the state.
class IslandEyes extends StatefulWidget {
  const IslandEyes({super.key, required this.signal, this.size = 18, this.level = 0, this.listening = false});

  final IslandSignal signal;

  /// Height of the eyes; the pair is a little under twice as wide.
  final double size;

  /// Live microphone level 0..1, only meaningful while [listening].
  final double level;
  final bool listening;

  @override
  State<IslandEyes> createState() => _IslandEyesState();
}

class _IslandEyesState extends State<IslandEyes> with TickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
  );
  final _rnd = math.Random();
  Timer? _blinkTimer;
  Timer? _poll;
  Offset _gaze = Offset.zero;
  Offset _target = Offset.zero;
  Offset? _window;
  int _windowAge = 0;
  bool _tracking = true;
  bool _still = false;

  @override
  void initState() {
    super.initState();
    compiiColor.addListener(_repaint);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still == _still && (_poll != null || still)) return;
    _still = still;
    _blinkTimer?.cancel();
    _poll?.cancel();
    _poll = null;
    if (still) {
      _gaze = _target = Offset.zero;
      return;
    }
    _scheduleBlink();
    _poll = Timer.periodic(const Duration(milliseconds: 70), (_) => _follow());
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _scheduleBlink() {
    _blinkTimer = Timer(Duration(milliseconds: 2600 + _rnd.nextInt(4200)), () async {
      if (!mounted) return;
      await _blink.forward(from: 0);
      if (!mounted) return;
      await _blink.reverse();
      // Now and then a double blink, the way a living thing does.
      if (mounted && _rnd.nextDouble() < .22) {
        await _blink.forward(from: 0);
        if (mounted) await _blink.reverse();
      }
      if (mounted) _scheduleBlink();
    });
  }

  /// Where the pointer is on the desktop, relative to these eyes, smoothed so
  /// they glide rather than snap.
  Future<void> _follow() async {
    if (!_tracking || !mounted) return;
    try {
      if (_window == null || _windowAge++ > 30) {
        _window = await windowManager.getPosition();
        _windowAge = 0;
      }
      final cursor = await screenRetriever.getCursorScreenPoint();
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      final mid = _window! + box.localToGlobal(box.size.center(Offset.zero));
      final d = cursor - mid;
      _target = Offset((d.dx / 260).clamp(-1.0, 1.0), (d.dy / 180).clamp(-1.0, 1.0));
    } on Object {
      // No desktop to ask (tests, or a platform without the plugin): the eyes
      // simply look ahead.
      _tracking = false;
      _target = Offset.zero;
    }
    final next = Offset.lerp(_gaze, _target, .35)!;
    if ((next - _gaze).distance > .004 && mounted) setState(() => _gaze = next);
  }

  @override
  void dispose() {
    compiiColor.removeListener(_repaint);
    _blinkTimer?.cancel();
    _poll?.cancel();
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hc = MediaQuery.highContrastOf(context);
    return Semantics(
      label: 'Compii',
      image: true,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _blink,
          builder: (context, _) => TweenAnimationBuilder<double>(
            // Moods ease in rather than jump.
            tween: Tween(end: _openFor(widget.signal)),
            duration: context.motion(260),
            curve: Curves.easeOutCubic,
            builder: (context, open, _) => CustomPaint(
              size: Size(widget.size * 1.9, widget.size),
              painter: _EyesPainter(
                iris: _irisFor(c, widget.signal),
                open: open * (1 - Curves.easeIn.transform(_blink.value)),
                joy: widget.signal == IslandSignal.done ? 1 : 0,
                gaze: widget.signal == IslandSignal.working && _gaze.distance < .15
                    // At work and not being watched: eyes on the task, down and
                    // to the side, the same glance the creature makes.
                    ? const Offset(.5, .45)
                    : _gaze,
                pupil: widget.listening ? 1.05 + widget.level.clamp(0.0, 1.0) * .35 : _pupilFor(widget.signal),
                tilt: switch (widget.signal) {
                  IslandSignal.needsYou => .7,
                  IslandSignal.failed => -.7,
                  _ => 0,
                },
                highContrast: hc,
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _openFor(IslandSignal s) => switch (s) {
    IslandSignal.offline => 0,
    IslandSignal.failed => .6,
    IslandSignal.working => .82,
    IslandSignal.needsYou || IslandSignal.listening => 1.15,
    _ => widget.listening ? 1.15 : 1,
  };

  double _pupilFor(IslandSignal s) => switch (s) {
    IslandSignal.needsYou => 1.25,
    IslandSignal.working => .85,
    IslandSignal.failed => .75,
    _ => 1,
  };

  Color _irisFor(CompiiColors c, IslandSignal s) => switch (s) {
    IslandSignal.needsYou => c.warning,
    IslandSignal.failed => c.danger,
    IslandSignal.listening => Color.lerp(compiiColor.value, c.listen, .5)!,
    IslandSignal.offline => c.faint,
    _ => _bright(compiiColor.value),
  };

  /// The coat colour, lifted so it glows against the black capsule.
  Color _bright(Color base) {
    final hsl = HSLColor.fromColor(base);
    return hsl.withLightness(hsl.lightness.clamp(.55, .7)).withSaturation(math.max(hsl.saturation, .55)).toColor();
  }
}

class _EyesPainter extends CustomPainter {
  _EyesPainter({
    required this.iris,
    required this.open,
    required this.joy,
    required this.gaze,
    required this.pupil,
    required this.tilt,
    required this.highContrast,
  });
  final Color iris;
  final double open, joy, pupil, tilt;
  final Offset gaze;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    // The same eyes of light Compii wears, set straight into the black capsule.
    final h = size.height * .9;
    paintHaloEyes(
      canvas,
      centre: size.center(Offset.zero) + Offset(gaze.dx * size.width * .08, gaze.dy * h * .12),
      gap: size.width * .2,
      w: h * .42,
      h: h,
      color: highContrast ? Colors.white : iris,
      rig: EyeRig(open: open, wide: pupil, tilt: tilt, joy: joy),
      unit: 1,
      dim: open < .05,
    );
  }

  @override
  bool shouldRepaint(covariant _EyesPainter old) =>
      old.iris != iris ||
      old.open != open ||
      old.joy != joy ||
      old.gaze != gaze ||
      old.pupil != pupil ||
      old.tilt != tilt ||
      old.highContrast != highContrast;
}
