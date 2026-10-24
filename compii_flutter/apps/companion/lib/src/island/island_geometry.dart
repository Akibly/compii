import 'dart:math' as math;
import 'dart:ui';

/// A monitor as Windows reports it: physical pixels, its work area, and the
/// scaling that turns logical Flutter pixels into those physical ones.
class IslandDisplay {
  const IslandDisplay({
    required this.name,
    required this.monitor,
    required this.work,
    required this.scale,
    required this.primary,
  });

  final String name;
  final Rect monitor;
  final Rect work;
  final double scale;
  final bool primary;

  factory IslandDisplay.fromMap(Map<Object?, Object?> map) {
    double n(String key, [double fallback = 0]) =>
        (map[key] as num?)?.toDouble() ?? fallback;
    return IslandDisplay(
      name: '${map['name'] ?? ''}',
      monitor: Rect.fromLTWH(n('x'), n('y'), n('width'), n('height')),
      work: Rect.fromLTWH(
        n('work_x', n('x')),
        n('work_y', n('y')),
        n('work_width', n('width')),
        n('work_height', n('height')),
      ),
      scale: math.max(.5, n('scale', 1)),
      primary: map['primary'] == true,
    );
  }

  Size get physicalSize => monitor.size;
}

/// Where the island lives, remembered across restarts and screen changes.
///
/// `x` is the centre of the card across the work area (0 = the left edge the
/// card may reach, 1 = the right edge); `y` is the top of the card down the
/// band it may move in (0 = the top margin, 1 = as low as a full card still
/// fits). Keeping fractions instead of pixels is what makes a saved island
/// still valid after a resolution change, a dock or a sleep.
class IslandLayout {
  const IslandLayout({this.display = '', this.x = .5, this.y = 0});

  final String display;
  final double x;
  final double y;

  static const topCenter = IslandLayout();

  IslandLayout copyWith({String? display, double? x, double? y}) =>
      IslandLayout(
        display: display ?? this.display,
        x: x ?? this.x,
        y: y ?? this.y,
      );

  Map<String, Object?> toJson() => {'display': display, 'x': x, 'y': y};

  factory IslandLayout.fromJson(Object? json) {
    if (json is! Map) return topCenter;
    double n(String key, double fallback) {
      final raw = json[key];
      if (raw is! num) return fallback;
      return raw.toDouble().clamp(0.0, 1.0).toDouble();
    }

    return IslandLayout(
      display: '${json['display'] ?? ''}',
      x: n('x', .5),
      y: n('y', 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IslandLayout &&
      other.display == display &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(display, x, y);
}

/// The card sizes the window has to keep on screen. Logical pixels: each
/// display scales them by its own DPI, so the same island looks the same size
/// on a laptop panel and a 4K monitor.
class IslandMetrics {
  const IslandMetrics({
    this.maxCardWidth = 408,
    this.maxCardHeight = 420,
    this.margin = 6,
    this.shadowInset = 0,
  });

  final double maxCardWidth;
  final double maxCardHeight;
  final double margin;

  /// Empty space kept above the card. The island has no shadow, so this is 0;
  /// it stays for the geometry that positions the window around it.
  final double shadowInset;
}

/// Pure window placement maths for the island. All returned offsets are
/// physical virtual-desktop pixels, the same coordinates the native window
/// uses, so mixed DPI and monitors left of the primary need no conversion.
class IslandGeometry {
  const IslandGeometry([this.metrics = const IslandMetrics()]);

  final IslandMetrics metrics;

  IslandDisplay displayFor(List<IslandDisplay> displays, IslandLayout layout) {
    if (displays.isEmpty) {
      return const IslandDisplay(
        name: 'primary',
        monitor: Rect.fromLTWH(0, 0, 1920, 1080),
        work: Rect.fromLTWH(0, 0, 1920, 1040),
        scale: 1,
        primary: true,
      );
    }
    for (final d in displays) {
      if (d.name == layout.display) return d;
    }
    for (final d in displays) {
      if (d.primary) return d;
    }
    return displays.first;
  }

  /// Where the window's top-left goes so the card's centre and top land on
  /// the saved fraction. The window is much wider and taller than the card,
  /// so parts of it may sit off-screen; only the card is ever visible.
  Offset windowFor({
    required IslandDisplay display,
    required IslandLayout layout,
    required Size windowPhysical,
  }) {
    final scale = display.scale;
    final work = display.work;
    final margin = metrics.margin * scale;
    final cardW = math.min(
      metrics.maxCardWidth * scale,
      math.max(1, work.width - 2 * margin),
    );
    final cardH = math.min(
      metrics.maxCardHeight * scale,
      math.max(1, work.height - 2 * margin),
    );
    final band = math.max(0.0, work.height - cardH - 2 * margin);

    final minX = work.left + cardW / 2 + margin;
    final maxX = work.right - cardW / 2 - margin;
    final centerX = maxX >= minX
        ? minX + layout.x.clamp(0.0, 1.0).toDouble() * (maxX - minX)
        : work.center.dx;
    final top = work.top + margin + layout.y.clamp(0.0, 1.0).toDouble() * band;
    // The card sits [shadowInset] below the window's top edge, so the window
    // itself starts higher than the card's visible top.
    return Offset(
      centerX - windowPhysical.width / 2,
      top - metrics.shadowInset * scale,
    );
  }

  /// The inverse of [windowFor], used when a drag ends: turn where the card
  /// actually is into a fraction that survives a resolution change.
  IslandLayout layoutFor({
    required IslandDisplay display,
    required Offset windowTopLeft,
    required Size windowPhysical,
    required double cardWidthPhysical,
  }) {
    final scale = display.scale;
    final work = display.work;
    final margin = metrics.margin * scale;
    final cardW = math.min(
      metrics.maxCardWidth * scale,
      math.max(1, work.width - 2 * margin),
    );
    final cardH = math.min(
      metrics.maxCardHeight * scale,
      math.max(1, work.height - 2 * margin),
    );
    final band = math.max(0.0, work.height - cardH - 2 * margin);

    final centerX = windowTopLeft.dx + windowPhysical.width / 2;
    final minX = work.left + cardW / 2 + margin;
    final maxX = work.right - cardW / 2 - margin;
    final x = maxX > minX
        ? ((centerX - minX) / (maxX - minX)).clamp(0.0, 1.0).toDouble()
        : .5;
    final cardTop = windowTopLeft.dy + metrics.shadowInset * scale;
    final y = band > 0
        ? ((cardTop - work.top - margin) / band).clamp(0.0, 1.0).toDouble()
        : 0.0;
    return IslandLayout(display: display.name, x: x, y: y);
  }

  /// A dock preset for the island's context menu.
  IslandLayout dock(IslandDock dock, String display) => IslandLayout(
    display: display,
    x: switch (dock) {
      IslandDock.left => 0,
      IslandDock.center => .5,
      IslandDock.right => 1,
    },
    y: 0,
  );

  /// The display whose monitor contains [point], or the nearest one.
  IslandDisplay? nearest(List<IslandDisplay> displays, Offset point) {
    IslandDisplay? best;
    var bestDistance = double.infinity;
    for (final d in displays) {
      if (d.monitor.contains(point)) return d;
      final dx = point.dx - d.monitor.center.dx;
      final dy = point.dy - d.monitor.center.dy;
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = d;
      }
    }
    return best;
  }
}

enum IslandDock { left, center, right }
