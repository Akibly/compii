import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../console/character.dart' show Mood;
import 'halo.dart';

/// Compii's app icon: its black-glass orb with two eyes of light and the halo,
/// on a deep tile with continuous (superellipse) corners. Drawn, not scaled: a
/// 16 px taskbar icon gets bigger eyes and no fine glass detail, so it still
/// reads as a face; 1024 px gets everything.
class AppIconPainter extends CustomPainter {
  const AppIconPainter({this.color = haloBlue, this.margin = .0});

  final Color color;

  /// Transparent space around the tile, as a share of the size (macOS wants
  /// about 10% so the icon sits on the dock like its neighbours).
  final double margin;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final small = s <= 48;
    final inset = s * margin;
    final box = Rect.fromLTWH(inset, inset, s - inset * 2, s - inset * 2);
    final tile = _squircle(box);

    if (margin > 0) {
      canvas.drawPath(
        tile.shift(Offset(0, box.height * .012)),
        Paint()
          ..color = Colors.black.withValues(alpha: .35)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, box.width * .02),
      );
    }
    canvas.drawPath(
      tile,
      Paint()
        ..shader = ui.Gradient.radial(
          box.topCenter + Offset(0, box.height * .25),
          box.width * .9,
          [Color.lerp(const Color(0xFF101626), color, .1)!, const Color(0xFF07080D), const Color(0xFF030305)],
          const [0, .6, 1],
        ),
    );
    canvas.save();
    canvas.clipPath(tile);
    // The halo's light, washing the tile behind the orb.
    canvas.drawCircle(
      box.center + Offset(0, box.height * .03),
      box.width * .42,
      Paint()
        ..shader = ui.Gradient.radial(box.center, box.width * .42, [
          color.withValues(alpha: .28),
          color.withValues(alpha: 0),
        ]),
    );
    Halo.paint(
      canvas,
      centre: box.center + Offset(0, box.height * (small ? .0 : .02)),
      span: box.width * (small ? .98 : .74),
      form: HaloForm.orb,
      color: color,
      pose: HaloPose(mood: Mood.idle, still: true, moodColor: null, look: small ? Offset.zero : const Offset(0, .1)),
      shadow: false,
    );
    canvas.restore();
    if (!small) {
      // A hairline of light along the top edge: the tile is glass too.
      canvas.drawPath(
        tile,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, box.width * .004)
          ..shader = ui.Gradient.linear(box.topCenter, box.center, [
            Colors.white.withValues(alpha: .22),
            Colors.white.withValues(alpha: 0),
          ]),
      );
    }
  }

  static Path _squircle(Rect r) {
    const n = 5.0;
    final p = Path();
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps * 2 * math.pi;
      final c = math.cos(t), s = math.sin(t);
      final x = r.center.dx + r.width / 2 * c.sign * math.pow(c.abs(), 2 / n);
      final y = r.center.dy + r.height / 2 * s.sign * math.pow(s.abs(), 2 / n);
      i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
    }
    return p..close();
  }

  @override
  bool shouldRepaint(covariant AppIconPainter old) => old.color != color || old.margin != margin;
}
