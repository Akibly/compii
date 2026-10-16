import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'preferences.dart';

const plum = Color(0xFF3A214D);
const lavender = Color(0xFFB794F6);
const ivory = Color(0xFFFFF9F3);

class Wisp extends StatefulWidget {
  const Wisp({
    super.key,
    required this.presentation,
    required this.expression,
    required this.animate,
    required this.floating,
  });
  final Presentation presentation;
  final WispExpression expression;
  final bool animate;
  final bool floating;
  @override
  State<Wisp> createState() => _WispState();
}

class _WispState extends State<Wisp> with SingleTickerProviderStateMixin {
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  Offset gaze = Offset.zero;
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant Wisp oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.animate) {
      if (!clock.isAnimating) clock.repeat();
    } else {
      clock.stop();
      clock.value = 0;
    }
  }

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Wisp, ${widget.expression.name}. ${widget.presentation == Presentation.face ? 'Face view' : 'Full-body view'}.',
    image: true,
    child: LayoutBuilder(
      builder: (context, bounds) => MouseRegion(
        onHover: (event) {
          if (!widget.animate) return;
          setState(
            () => gaze = Offset(
              (event.localPosition.dx / bounds.maxWidth - .5).clamp(-.5, .5),
              (event.localPosition.dy / bounds.maxHeight - .5).clamp(-.5, .5),
            ),
          );
        },
        onExit: (_) => setState(() => gaze = Offset.zero),
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: clock,
            builder: (_, _) => CustomPaint(
              painter: WispPainter(
                presentation: widget.presentation,
                expression: widget.expression,
                phase: clock.value,
                gaze: widget.animate ? gaze : Offset.zero,
                drift: widget.animate && widget.floating,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

class WispPainter extends CustomPainter {
  WispPainter({
    required this.presentation,
    required this.expression,
    required this.phase,
    required this.gaze,
    required this.drift,
  });
  final Presentation presentation;
  final WispExpression expression;
  final double phase;
  final Offset gaze;
  final bool drift;
  @override
  void paint(Canvas canvas, Size size) {
    final face = presentation == Presentation.face;
    final scale = face
        ? math.min(size.width / 310, size.height / 200)
        : math.min(size.width / 400, size.height / 430);
    final bob = drift && !face ? math.sin(phase * math.pi * 2) * 9 : 0.0;
    canvas.save();
    canvas.translate(
      size.width / 2,
      size.height / 2 + bob + (face ? 45 * scale : 0),
    );
    canvas.scale(scale);
    if (!face) {
      canvas.drawOval(
        const Rect.fromLTWH(-70, 151, 140, 16),
        Paint()
          ..color = const Color(0xFF13081E).withValues(alpha: .23)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
    }
    final body = Path()
      ..moveTo(-20, -164)
      ..cubicTo(-42, -180, -47, -166, -39, -146)
      ..cubicTo(-144, -137, -164, -46, -133, 20)
      ..cubicTo(-113, 63, -56, 77, -12, 84)
      ..cubicTo(58, 96, 24, 132, -19, 124)
      ..cubicTo(13, 166, 107, 136, 95, 88)
      ..cubicTo(88, 61, 66, 50, 81, 33)
      ..cubicTo(151, -22, 149, -111, 77, -140)
      ..cubicTo(36, -157, 7, -143, -20, -164)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF4E9FF),
            Color(0xFFD9BDFF),
            lavender,
            Color(0xFFEBD7FF),
          ],
          stops: [0, .4, .72, 1],
        ).createShader(const Rect.fromLTWH(-160, -180, 320, 340)),
    );
    final resting = expression == WispExpression.resting;
    final blink = phase > .91 && phase < .94;
    for (final side in [-1.0, 1.0]) {
      final eye = Offset(side * 56, -51 + (side > 0 ? 6 : 0));
      final stroke = Paint()
        ..color = plum
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      if (resting || blink) {
        canvas.drawArc(
          Rect.fromCenter(center: eye.translate(0, -12), width: 57, height: 38),
          .18,
          math.pi - .36,
          false,
          stroke,
        );
      } else {
        canvas.drawOval(
          Rect.fromCenter(center: eye, width: 74, height: 95),
          Paint()..color = const Color(0xFFFFFCFA),
        );
        final look = expression == WispExpression.thinking
            ? const Offset(-9, -12)
            : Offset(gaze.dx * 24, gaze.dy * 22);
        final pupil = eye + look + Offset(side * -2, 1);
        final pupilSize = expression == WispExpression.listening ? 43.0 : 39.0;
        canvas.drawOval(
          Rect.fromCenter(
            center: pupil,
            width: pupilSize,
            height: pupilSize * 1.28,
          ),
          Paint()..color = plum,
        );
        canvas.drawCircle(
          pupil.translate(-8, -12),
          8,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          pupil.translate(8, 9),
          3,
          Paint()..color = Colors.white.withValues(alpha: .85),
        );
      }
      final brow = Path()
        ..moveTo(eye.dx - 23, eye.dy - 62)
        ..quadraticBezierTo(
          eye.dx,
          eye.dy -
              73 -
              (expression == WispExpression.thinking && side < 0 ? 12 : 0),
          eye.dx + 19,
          eye.dy - 64,
        );
      canvas.drawPath(brow, stroke..strokeWidth = 3.5);
      canvas.drawOval(
        Rect.fromCenter(
          center: eye.translate(side * 15, 53),
          width: 25,
          height: 12,
        ),
        Paint()..color = const Color(0xFFF1ACCB).withValues(alpha: .35),
      );
    }
    final mouth = Paint()..color = plum;
    if (expression == WispExpression.explaining ||
        expression == WispExpression.listening) {
      canvas.drawOval(
        Rect.fromCenter(
          center: const Offset(0, 23),
          width: 18,
          height: expression == WispExpression.explaining
              ? 19 + math.sin(phase * math.pi * 12) * 4
              : 16,
        ),
        mouth,
      );
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(-9, 20)
          ..quadraticBezierTo(0, 29, 10, 20),
        mouth
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WispPainter old) =>
      old.phase != phase ||
      old.gaze != gaze ||
      old.presentation != presentation ||
      old.expression != expression ||
      old.drift != drift;
}
