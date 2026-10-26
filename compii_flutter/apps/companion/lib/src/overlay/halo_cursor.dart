import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../art/halo.dart';
import '../console/character.dart' show Mood;

/// What the cursor companion's eyes wear for each of Core's buddy states.
Mood moodForBuddy(String state, {bool speaking = false}) => switch (state) {
  'listening' || 'dictating' => Mood.listening,
  'thinking' => Mood.thinking,
  'watching' => Mood.acting,
  'needs_you' || 'selected' => Mood.waiting,
  'answer' => speaking ? Mood.speaking : Mood.happy,
  'error' || 'setup' => Mood.problem,
  _ => Mood.idle,
};

/// Compii beside the cursor: a small black-glass capsule with its two eyes of
/// light — the island's face, in miniature. It is the only thing that rides
/// with the pointer, and it is quiet: no orbit, no comet, no spin. When Compii
/// is engaged a halo of its colour glows around the capsule's edge.
class CursorMarkPainter extends CustomPainter {
  CursorMarkPainter({
    required this.mood,
    required this.color,
    this.t = 0,
    this.fade = 1,
    this.engaged = false,
    this.level = 0,
    this.gaze = Offset.zero,
  });
  final Mood mood;
  final Color color;

  /// 0..1, the halo's orbit.
  final double t;
  final double fade;
  final bool engaged;
  final double level;
  final Offset gaze;

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;
    final w = size.width * .82;
    final h = w * .6;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: size.center(Offset.zero), width: w, height: h),
      Radius.circular(h / 2),
    );
    canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: fade));
    canvas.drawRRect(
      body.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: .35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    if (engaged) {
      canvas.drawRRect(
        body.inflate(1.5 + level * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 + level * 3
          ..shader = SweepGradient(
            colors: [color, const Color(0xFF2FD3FF), const Color(0xFFC06BFF), color],
            transform: GradientRotation(t * 2 * math.pi),
          ).createShader(body.outerRect)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5),
      );
    }
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E1F27), Color(0xFF07070A)],
        ).createShader(body.outerRect),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: engaged ? .26 : .16),
    );
    final eh = h * .5;
    paintHaloEyes(
      canvas,
      centre: body.center + Offset(gaze.dx * w * .06, gaze.dy * h * .06),
      gap: w * .16,
      w: eh * .42,
      h: eh,
      color: color,
      rig: EyeRig.of(mood),
      unit: 1,
      dim: mood == Mood.offline,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CursorMarkPainter o) =>
      o.mood != mood ||
      o.color != color ||
      o.t != t ||
      o.fade != fade ||
      o.engaged != engaged ||
      o.level != level ||
      o.gaze != gaze;
}

/// The halo around the pointer while Compii is listening or working: a soft ring
/// of light that swells with your voice. It says "I'm with you, here" without
/// covering a single pixel under the pointer.
class CursorRingPainter extends CustomPainter {
  CursorRingPainter({required this.color, required this.t, this.level = 0, this.fade = 1});
  final Color color;
  final double t;
  final double level;
  final double fade;

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;
    final c = size.center(Offset.zero);
    final r = 15 + level.clamp(0.0, 1.0) * 7 + math.sin(t * 2 * math.pi) * 1.2;
    final sweep = SweepGradient(
      colors: [color, const Color(0xFF2FD3FF), const Color(0xFFC06BFF), color],
      transform: GradientRotation(t * 2 * math.pi),
    ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..shader = sweep
        ..color = Colors.white.withValues(alpha: .5 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = sweep,
    );
  }

  @override
  bool shouldRepaint(covariant CursorRingPainter o) =>
      o.color != color || o.t != t || o.level != level || o.fade != fade;
}

/// Showing you something: the screen dims and the one thing that matters stays
/// lit, ringed in Compii's colour. Nothing else moves.
class SpotlightPainter extends CustomPainter {
  SpotlightPainter({required this.target, required this.color, required this.progress, this.fade = 1, this.pulse = 0});
  final Rect target;
  final Color color;

  /// 0..1 as the spotlight arrives.
  final double progress;
  final double fade;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final a = Curves.easeOutCubic.transform(progress.clamp(0.0, 1.0)) * fade;
    if (a <= 0) return;
    final hole = RRect.fromRectAndRadius(target.inflate(6), const Radius.circular(10));
    final dim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(hole),
    );
    canvas.drawPath(dim, Paint()..color = const Color(0xFF03040A).withValues(alpha: .5 * a));
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = color.withValues(alpha: (.35 + .2 * pulse) * a)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = color.withValues(alpha: a),
    );
  }

  @override
  bool shouldRepaint(covariant SpotlightPainter o) =>
      o.target != target || o.color != color || o.progress != progress || o.fade != fade || o.pulse != pulse;
}

/// The eyes on their own, for the header of a card: same rig, no capsule.
class CardEyes extends StatelessWidget {
  const CardEyes({super.key, required this.mood, required this.color, this.size = 16});
  final Mood mood;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size(size * 1.3, size),
      painter: _EyesPainter(mood, color),
    ),
  );
}

class _EyesPainter extends CustomPainter {
  _EyesPainter(this.mood, this.color);
  final Mood mood;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height * .95;
    paintHaloEyes(
      canvas,
      centre: size.center(Offset.zero),
      gap: size.width * .26,
      w: h * .42,
      h: h,
      color: color,
      rig: EyeRig.of(mood),
      unit: 1,
      dim: mood == Mood.offline,
    );
  }

  @override
  bool shouldRepaint(covariant _EyesPainter o) => o.mood != mood || o.color != color;
}
