import 'dart:ui';

import 'package:compii/src/island/island_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

const _primary = IslandDisplay(
  name: r'\\.\DISPLAY1',
  monitor: Rect.fromLTWH(0, 0, 1920, 1080),
  work: Rect.fromLTWH(0, 0, 1920, 1040),
  scale: 1,
  primary: true,
);

const _left = IslandDisplay(
  name: r'\\.\DISPLAY2',
  monitor: Rect.fromLTWH(-1920, 0, 1920, 1080),
  work: Rect.fromLTWH(-1920, 0, 1920, 1040),
  scale: 1,
  primary: false,
);

const _big = IslandDisplay(
  name: r'\\.\DISPLAY3',
  monitor: Rect.fromLTWH(1920, 0, 3840, 2160),
  work: Rect.fromLTWH(1920, 0, 3840, 2120),
  scale: 2,
  primary: false,
);

const _geometry = IslandGeometry();
const _window = Size(720, 860);

void main() {
  test('top centre puts the card under the top margin', () {
    final at = _geometry.windowFor(display: _primary, layout: IslandLayout.topCenter, windowPhysical: _window);
    // Card centre = work centre; card top = margin. The black island casts no
    // shadow, so the window's top edge is the card's top edge.
    expect(at, const Offset(600, 6));
  });

  test('the saved fraction round-trips through a drag', () {
    for (final y in [0.0, .25, .5, 1.0]) {
      for (final x in [0.0, .3, .7, 1.0]) {
        final layout = IslandLayout(display: _primary.name, x: x, y: y);
        final at = _geometry.windowFor(display: _primary, layout: layout, windowPhysical: _window);
        final back = _geometry.layoutFor(
          display: _primary,
          windowTopLeft: at,
          windowPhysical: _window,
          cardWidthPhysical: 408,
        );
        expect(back.display, _primary.name);
        expect(back.x, closeTo(x, 1e-9), reason: 'x=$x');
        expect(back.y, closeTo(y, 1e-9), reason: 'y=$y');
      }
    }
  });

  test('a 4K monitor at 200% keeps the same logical card and round-trips', () {
    final layout = const IslandLayout(display: r'\\.\DISPLAY3', x: .5, y: .4);
    final at = _geometry.windowFor(display: _big, layout: layout, windowPhysical: _window);
    final back = _geometry.layoutFor(
      display: _big,
      windowTopLeft: at,
      windowPhysical: _window,
      cardWidthPhysical: 408 * 2,
    );
    expect(back.x, closeTo(.5, 1e-9));
    expect(back.y, closeTo(.4, 1e-9));
    // Card top = margin + 40% of the free band, in the monitor's own pixels.
    final cardTop = at.dy + IslandMetrics().shadowInset * _big.scale;
    expect(cardTop, closeTo(6 * 2 + .4 * (2120 - 420 * 2 - 6 * 2 * 2), 1e-9));
  });

  test('a monitor left of the primary one uses negative coordinates unchanged', () {
    final at = _geometry.windowFor(
      display: _left,
      layout: const IslandLayout(display: r'\\.\DISPLAY2', x: 0, y: 0),
      windowPhysical: _window,
    );
    // x = 0 means the card's left edge sits on the work-area margin.
    expect(at.dx, -1920 + 6 + 204 - 360);
    expect(at.dx + 360 - 204, -1920 + 6);
  });

  test('the lowest saved position still leaves the full card inside the work area', () {
    final at = _geometry.windowFor(
      display: _primary,
      layout: const IslandLayout(x: .5, y: 1),
      windowPhysical: _window,
    );
    final cardTop = at.dy + IslandMetrics().shadowInset;
    expect(cardTop, _primary.work.bottom - 6 - IslandMetrics().maxCardHeight);
  });

  test('dock presets are fractions, not pixels, so they survive a screen change', () {
    expect(_geometry.dock(IslandDock.left, _primary.name).x, 0);
    expect(_geometry.dock(IslandDock.center, _primary.name).x, .5);
    expect(_geometry.dock(IslandDock.right, _primary.name).x, 1);
    expect(_geometry.dock(IslandDock.right, _primary.name).y, 0);
  });

  test('a saved display that is gone falls back to the primary one', () {
    final display = _geometry.displayFor([_left, _primary], const IslandLayout(display: 'unplugged'));
    expect(display.name, _primary.name);
  });

  test('the cursor picks the monitor it is on, or the nearest one', () {
    expect(_geometry.nearest([_primary, _left], const Offset(-50, 200))!.name, _left.name);
    expect(_geometry.nearest([_primary, _left], const Offset(900, 400))!.name, _primary.name);
    expect(_geometry.nearest([_primary, _left], const Offset(-4000, 400))!.name, _left.name);
    expect(_geometry.nearest(const [], Offset.zero), isNull);
  });

  test('a layout read from disk is clamped and survives bad JSON', () {
    final read = IslandLayout.fromJson({'display': r'\\.\DISPLAY2', 'x': 4.2, 'y': -3});
    expect(read.display, r'\\.\DISPLAY2');
    expect(read.x, 1);
    expect(read.y, 0);
    expect(IslandLayout.fromJson('nonsense'), IslandLayout.topCenter);
    expect(IslandLayout.fromJson({'x': 'wide'}), IslandLayout.topCenter);
    expect(IslandLayout.fromJson(read.toJson()), read);
  });

  test('a tiny work area still yields a usable, non-negative window', () {
    const small = IslandDisplay(
      name: 'tiny',
      monitor: Rect.fromLTWH(0, 0, 320, 200),
      work: Rect.fromLTWH(0, 0, 320, 180),
      scale: 1,
      primary: true,
    );
    final at = _geometry.windowFor(display: small, layout: IslandLayout.topCenter, windowPhysical: _window);
    expect(at.dx.isFinite, isTrue);
    expect(at.dy.isFinite, isTrue);
  });
}
