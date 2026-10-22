import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Compii's own icon set ("glyphs"), drawn for this app instead of a stock
/// icon font. One language throughout: a 24-unit grid, 1.7-unit rounded
/// strokes, generous corner radii, and an optional soft second tone that
/// fills the main shape when the glyph is active.
///
/// Each glyph is SVG-style path data in the 24 grid: `s` is stroked, `f` is
/// the soft fill (shown at 16% when [Glyph.duo] is on, or always for solid
/// details such as dots).
class GlyphData {
  const GlyphData(this.s, {this.f = const [], this.dots = const []});
  final List<String> s;
  final List<String> f;

  /// Small solid dots: (x, y, r).
  final List<(double, double, double)> dots;
}

class G {
  // ---- navigation ----
  static const home = GlyphData(['M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z'],
      f: ['M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z']);
  static const chat = GlyphData(['M5 5h14a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 19 17h-8l-4.5 3.5V17H5a1.5 1.5 0 0 1-1.5-1.5v-9A1.5 1.5 0 0 1 5 5z'],
      f: ['M5 5h14a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 19 17h-8l-4.5 3.5V17H5a1.5 1.5 0 0 1-1.5-1.5v-9A1.5 1.5 0 0 1 5 5z'],
      dots: [(8.5, 11, 1.1), (12, 11, 1.1), (15.5, 11, 1.1)]);
  static const team = GlyphData(['M9 4.5a3 3 0 1 1 0 6 3 3 0 0 1 0-6z',
      'M3.5 20v-1.5A4.5 4.5 0 0 1 8 14h2a4.5 4.5 0 0 1 4.5 4.5V20',
      'M15.5 5.2a3 3 0 0 1 0 5.6', 'M16.5 14h.5a4.5 4.5 0 0 1 4.5 4.5V20'],
      f: ['M9 4.5a3 3 0 1 1 0 6 3 3 0 0 1 0-6z']);
  static const bell = GlyphData(['M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z', 'M10 21h4'],
      f: ['M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z']);
  static const routine = GlyphData(['M4.5 7.5A2.5 2.5 0 0 1 7 5h10a2.5 2.5 0 0 1 2.5 2.5V17A2.5 2.5 0 0 1 17 19.5H7A2.5 2.5 0 0 1 4.5 17z', 'M4.5 9.5h15', 'M8.5 3v4', 'M15.5 3v4', 'M14.6 13.2a2.7 2.7 0 1 0 .3 2.6', 'M15 11.6v1.8h-1.8'],
      f: ['M4.5 7.5A2.5 2.5 0 0 1 7 5h10a2.5 2.5 0 0 1 2.5 2.5v2h-15z']);
  static const skill = GlyphData(['M12 4 2.5 8.5 12 13l9.5-4.5z', 'M6.5 10.5v4.2c0 1.6 2.5 3.3 5.5 3.3s5.5-1.7 5.5-3.3v-4.2', 'M21.5 8.5v5'],
      f: ['M12 4 2.5 8.5 12 13l9.5-4.5z']);
  static const memory = GlyphData(['M10 3.5l1.5 4 4 1.5-4 1.5-1.5 4-1.5-4-4-1.5 4-1.5z', 'M17.5 13l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z', 'M6 16.5l.6 1.4 1.4.6-1.4.6L6 20.5l-.6-1.4-1.4-.6 1.4-.6z'],
      f: ['M10 3.5l1.5 4 4 1.5-4 1.5-1.5 4-1.5-4-4-1.5 4-1.5z']);
  static const shield = GlyphData(['M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z'],
      f: ['M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z']);
  static const shieldCheck = GlyphData(['M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z', 'M9 12l2.2 2.2L15.2 10'],
      f: ['M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z']);
  static const shieldAlert = GlyphData(['M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z', 'M12 8.5v4'],
      f: ['M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z'], dots: [(12, 15.6, 1.05)]);
  static const sliders = GlyphData(['M4 7h9', 'M17 7h3', 'M4 17h3', 'M11 17h9', 'M15 4.5v5', 'M9 14.5v5']);
  static const phone = GlyphData(['M8 3h8a1.5 1.5 0 0 1 1.5 1.5v15A1.5 1.5 0 0 1 16 21H8a1.5 1.5 0 0 1-1.5-1.5v-15A1.5 1.5 0 0 1 8 3z', 'M10.5 18h3'],
      f: ['M8 3h8a1.5 1.5 0 0 1 1.5 1.5v15A1.5 1.5 0 0 1 16 21H8a1.5 1.5 0 0 1-1.5-1.5v-15A1.5 1.5 0 0 1 8 3z']);
  static const keyboard = GlyphData(['M4.5 6.5h15A1.5 1.5 0 0 1 21 8v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 16V8a1.5 1.5 0 0 1 1.5-1.5z', 'M8 14.5h8'],
      dots: [(7, 10, .9), (10.3, 10, .9), (13.7, 10, .9), (17, 10, .9)]);

  // ---- actions ----
  static const plus = GlyphData(['M12 5v14', 'M5 12h14']);
  static const more = GlyphData([], dots: [(6.5, 12, 1.35), (12, 12, 1.35), (17.5, 12, 1.35)]);
  static const menu = GlyphData(['M4 7h16', 'M4 12h16', 'M4 17h16']);
  static const clip = GlyphData(['M9 12.5 15.6 5.9a3 3 0 0 1 4.2 4.2l-8 8a4.5 4.5 0 0 1-6.4-6.4l8-8']);
  static const close = GlyphData(['M6.5 6.5l11 11', 'M17.5 6.5l-11 11']);
  static const check = GlyphData(['M5 12.5l4.5 4.5L19 7.5']);
  static const checkCircle = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M8.2 12.2l2.6 2.6 5-5'],
      f: ['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z']);
  static const alert = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M12 8v4.5'],
      f: ['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z'], dots: [(12, 15.8, 1.05)]);
  static const info = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M12 11v5'],
      f: ['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z'], dots: [(12, 8, 1.05)]);
  static const warning = GlyphData(['M10.7 4.6a1.5 1.5 0 0 1 2.6 0l7.6 13.2a1.5 1.5 0 0 1-1.3 2.2H4.4a1.5 1.5 0 0 1-1.3-2.2z', 'M12 9.5v4'],
      f: ['M10.7 4.6a1.5 1.5 0 0 1 2.6 0l7.6 13.2a1.5 1.5 0 0 1-1.3 2.2H4.4a1.5 1.5 0 0 1-1.3-2.2z'], dots: [(12, 16.6, 1.05)]);
  static const block = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M6 6l12 12']);
  static const trash = GlyphData(['M4.5 7h15', 'M9.5 7V5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v2', 'M6.5 7l.8 11.6A1.5 1.5 0 0 0 8.8 20h6.4a1.5 1.5 0 0 0 1.5-1.4L17.5 7', 'M10.3 11v5', 'M13.7 11v5'],
      f: ['M6.5 7l.8 11.6A1.5 1.5 0 0 0 8.8 20h6.4a1.5 1.5 0 0 0 1.5-1.4L17.5 7z']);
  static const edit = GlyphData(['M15.5 4.5l4 4L9 19H5v-4z', 'M13 7l4 4'], f: ['M15.5 4.5l4 4L9 19H5v-4z']);
  static const copy = GlyphData(['M8.5 8.5h9A1.5 1.5 0 0 1 19 10v9.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 7 19.5V10a1.5 1.5 0 0 1 1.5-1.5z', 'M15.5 8.5V5A1.5 1.5 0 0 0 14 3.5H5A1.5 1.5 0 0 0 3.5 5v9A1.5 1.5 0 0 0 5 15.5h2'],
      f: ['M8.5 8.5h9A1.5 1.5 0 0 1 19 10v9.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 7 19.5V10a1.5 1.5 0 0 1 1.5-1.5z']);
  static const undo = GlyphData(['M9 7.5 5 11.5l4 4', 'M5 11.5h9.5a4.5 4.5 0 0 1 0 9H11']);
  static const external = GlyphData(['M13.5 4.5H19.5v6', 'M19.5 4.5l-8 8', 'M17 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-10A1.5 1.5 0 0 1 4 18.5v-10A1.5 1.5 0 0 1 5.5 7H10']);
  static const expand = GlyphData(['M6.5 9.5 12 15l5.5-5.5']);
  static const collapse = GlyphData(['M6.5 14.5 12 9l5.5 5.5']);
  static const chevronRight = GlyphData(['M9.5 6.5 15 12l-5.5 5.5']);
  static const arrowUp = GlyphData(['M12 19V5.5', 'M6 11.5l6-6 6 6']);
  static const download = GlyphData(['M12 4v11', 'M7 10.5l5 5 5-5', 'M5 19.5h14']);
  static const sync = GlyphData(['M19 8.5A7.5 7.5 0 0 0 5.5 9', 'M19 4.5v4h-4', 'M5 15.5A7.5 7.5 0 0 0 18.5 15', 'M5 19.5v-4h4']);
  static const play = GlyphData(['M8 5.5v13l10.5-6.5z'], f: ['M8 5.5v13l10.5-6.5z']);
  static const stop = GlyphData(['M7.5 6h9A1.5 1.5 0 0 1 18 7.5v9a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 16.5v-9A1.5 1.5 0 0 1 7.5 6z'],
      f: ['M7.5 6h9A1.5 1.5 0 0 1 18 7.5v9a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 16.5v-9A1.5 1.5 0 0 1 7.5 6z']);
  static const power = GlyphData(['M12 3.5v8', 'M7.2 6.3a7.5 7.5 0 1 0 9.6 0']);
  static const bolt = GlyphData(['M13.5 3 5.5 13.5H12L10.5 21l8-10.5H12z'], f: ['M13.5 3 5.5 13.5H12L10.5 21l8-10.5H12z']);
  static const wand = GlyphData(['M5 19 15.5 8.5', 'M13.5 6.5l2-2 4 4-2 2', 'M6 5v3', 'M4.5 6.5h3', 'M18.5 14.5v3', 'M17 16h3'],
      f: ['M13.5 6.5l2-2 4 4-2 2z']);
  static const send = GlyphData(['M4 11.5 20 4l-6 16-3-6.5z', 'M11 13.5 20 4'], f: ['M4 11.5 20 4l-6 16-3-6.5z']);
  static const eye = GlyphData(['M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z', 'M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6z'],
      f: ['M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6z']);
  static const eyeOff = GlyphData(['M4 4l16 16', 'M9.9 6a9.6 9.6 0 0 1 2.1-.5c6 0 9.5 6.5 9.5 6.5a16 16 0 0 1-2.6 3.4', 'M6.3 7.6C3.9 9.4 2.5 12 2.5 12S6 18.5 12 18.5c1.6 0 3-.5 4.2-1.1', 'M9.9 10a3 3 0 0 0 4.1 4.1']);

  // ---- things ----
  static const folder = GlyphData(['M3.5 7A1.5 1.5 0 0 1 5 5.5h4.2l2 2.2H19A1.5 1.5 0 0 1 20.5 9.2v8.3A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z'],
      f: ['M3.5 7A1.5 1.5 0 0 1 5 5.5h4.2l2 2.2H19A1.5 1.5 0 0 1 20.5 9.2v8.3A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z']);
  static const file = GlyphData(['M6.5 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 16.5 20.5h-10A1.5 1.5 0 0 1 5 19V5a1.5 1.5 0 0 1 1.5-1.5z', 'M13.5 3.5V8H18'],
      f: ['M6.5 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 16.5 20.5h-10A1.5 1.5 0 0 1 5 19V5a1.5 1.5 0 0 1 1.5-1.5z']);
  static const doc = GlyphData(['M6.5 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 16.5 20.5h-10A1.5 1.5 0 0 1 5 19V5a1.5 1.5 0 0 1 1.5-1.5z', 'M13.5 3.5V8H18', 'M8.5 12.5h6', 'M8.5 16h6'],
      f: ['M6.5 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 16.5 20.5h-10A1.5 1.5 0 0 1 5 19V5a1.5 1.5 0 0 1 1.5-1.5z']);
  static const sheet = GlyphData(['M5 4.5h14A1.5 1.5 0 0 1 20.5 6v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5z', 'M3.5 9.5h17', 'M3.5 14.5h17', 'M9.5 9.5v10'],
      f: ['M5 4.5h14A1.5 1.5 0 0 1 20.5 6v3.5h-17V6A1.5 1.5 0 0 1 5 4.5z']);
  static const image = GlyphData(['M5 4.5h14A1.5 1.5 0 0 1 20.5 6v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5z', 'M3.5 16.5 9 11l5 5 2.5-2.5 4 4'],
      f: ['M3.5 16.5 9 11l5 5 2.5-2.5 4 4V18a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18z'], dots: [(15.5, 8.5, 1.4)]);
  static const mail = GlyphData(['M5 5.5h14A1.5 1.5 0 0 1 20.5 7v10a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 17V7A1.5 1.5 0 0 1 5 5.5z', 'M4 7l8 6 8-6'],
      f: ['M5 5.5h14A1.5 1.5 0 0 1 20.5 7v10a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 17V7A1.5 1.5 0 0 1 5 5.5z']);
  static const receipt = GlyphData(['M6 3.5h12v17l-2.5-1.5-2 1.5-1.5-1.2-1.5 1.2-2-1.5L6 20.5z', 'M9 8.5h6', 'M9 12h6', 'M9 15.5h3.5'],
      f: ['M6 3.5h12v17l-2.5-1.5-2 1.5-1.5-1.2-1.5 1.2-2-1.5L6 20.5z']);
  static const money = GlyphData(['M4.5 6.5h15A1.5 1.5 0 0 1 21 8v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 16V8a1.5 1.5 0 0 1 1.5-1.5z', 'M12 9.5a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5z'],
      f: ['M4.5 6.5h15A1.5 1.5 0 0 1 21 8v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 16V8a1.5 1.5 0 0 1 1.5-1.5z'], dots: [(6.5, 12, .9), (17.5, 12, .9)]);
  static const lock = GlyphData(['M6.5 10.5h11A1.5 1.5 0 0 1 19 12v7a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 19v-7a1.5 1.5 0 0 1 1.5-1.5z', 'M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5'],
      f: ['M6.5 10.5h11A1.5 1.5 0 0 1 19 12v7a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 19v-7a1.5 1.5 0 0 1 1.5-1.5z'], dots: [(12, 15.5, 1.2)]);
  static const key = GlyphData(['M8.5 6a4 4 0 1 1 0 8 4 4 0 0 1 0-8z', 'M12.2 11.5 20 11.5', 'M17 11.5v3', 'M19.8 11.5v2.2'], f: ['M8.5 6a4 4 0 1 1 0 8 4 4 0 0 1 0-8z']);
  static const password = GlyphData(['M4.5 6.5h15A1.5 1.5 0 0 1 21 8v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 16V8a1.5 1.5 0 0 1 1.5-1.5z'],
      dots: [(7.5, 12, 1.2), (12, 12, 1.2), (16.5, 12, 1.2)]);
  static const box = GlyphData(['M12 3.5l7.5 4v9L12 20.5l-7.5-4v-9z', 'M4.5 7.5 12 11.5l7.5-4', 'M12 11.5v9'], f: ['M12 3.5l7.5 4L12 11.5 4.5 7.5z']);
  static const clock = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M12 7.5V12l3 2'], f: ['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z']);
  static const globe = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M3.5 12h17', 'M12 3.5c2.3 2.3 3.5 5.2 3.5 8.5s-1.2 6.2-3.5 8.5c-2.3-2.3-3.5-5.2-3.5-8.5S9.7 5.8 12 3.5z'],
      f: ['M12 3.5c2.3 2.3 3.5 5.2 3.5 8.5s-1.2 6.2-3.5 8.5c-2.3-2.3-3.5-5.2-3.5-8.5S9.7 5.8 12 3.5z']);
  static const search = GlyphData(['M10.5 4a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13z', 'M15.3 15.3 20 20'], f: ['M10.5 4a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13z']);
  static const monitor = GlyphData(['M4.5 4.5h15A1.5 1.5 0 0 1 21 6v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 15V6a1.5 1.5 0 0 1 1.5-1.5z', 'M9 20h6', 'M12 16.5V20'],
      f: ['M4.5 4.5h15A1.5 1.5 0 0 1 21 6v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 15V6a1.5 1.5 0 0 1 1.5-1.5z']);
  static const cloud = GlyphData(['M7.5 18.5a4.5 4.5 0 0 1-.6-9 6 6 0 0 1 11.4 1.5 3.75 3.75 0 0 1-.8 7.5z'], f: ['M7.5 18.5a4.5 4.5 0 0 1-.6-9 6 6 0 0 1 11.4 1.5 3.75 3.75 0 0 1-.8 7.5z']);
  static const sun = GlyphData(['M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8z', 'M12 2.5v2', 'M12 19.5v2', 'M2.5 12h2', 'M19.5 12h2', 'M5.3 5.3l1.4 1.4', 'M17.3 17.3l1.4 1.4', 'M5.3 18.7l1.4-1.4', 'M17.3 6.7l1.4-1.4'],
      f: ['M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8z']);
  static const contrast = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M12 3.5v17'], f: ['M12 3.5a8.5 8.5 0 0 1 0 17z']);
  static const coin = GlyphData(['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z', 'M14.5 9.2c-.5-.8-1.4-1.2-2.5-1.2-1.4 0-2.5.8-2.5 2s1.1 1.6 2.5 2 2.5.8 2.5 2-1.1 2-2.5 2c-1.1 0-2-.4-2.5-1.2', 'M12 6.5V8', 'M12 16v1.5'],
      f: ['M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17z']);
  static const broom = GlyphData(['M19.5 4.5 13 11', 'M9.5 10.5l4 4', 'M9.5 10.5c-2.5 0-4.5 1.5-5 4.5l-.5 4.5 3-1.5 1.5 1.5 1.5-2 1.5 1.5c2-1.5 3-3.5 2-4.5'],
      f: ['M9.5 10.5c-2.5 0-4.5 1.5-5 4.5l-.5 4.5 3-1.5 1.5 1.5 1.5-2 1.5 1.5c2-1.5 3-3.5 2-4.5z']);
  static const flag = GlyphData(['M5.5 21V4', 'M5.5 4.5h11l-2 4 2 4h-11'], f: ['M5.5 4.5h11l-2 4 2 4h-11z']);
  static const flask = GlyphData(['M9.5 3.5h5', 'M10 3.5v5.5L4.8 18a1.7 1.7 0 0 0 1.5 2.5h11.4a1.7 1.7 0 0 0 1.5-2.5L14 9V3.5', 'M7 14.5h10'],
      f: ['M7 14.5h10l2.2 3.5a1.7 1.7 0 0 1-1.5 2.5H6.3a1.7 1.7 0 0 1-1.5-2.5z']);
  static const hand = GlyphData(['M8 12.5V6a1.5 1.5 0 0 1 3 0v5', 'M11 11V4.5a1.5 1.5 0 0 1 3 0V11', 'M14 11V5.5a1.5 1.5 0 0 1 3 0V13', 'M17 9.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-1a6 6 0 0 1-5-2.7L4.5 14.6a1.5 1.5 0 0 1 2.4-1.8L8 14'],
      f: ['M8 12.5V6a1.5 1.5 0 0 1 3 0V4.5a1.5 1.5 0 0 1 3 0v1a1.5 1.5 0 0 1 3 0v4a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-7 7h-1a6 6 0 0 1-5-2.7L4.5 14.6a1.5 1.5 0 0 1 2.4-1.8L8 14z']);
  static const note = GlyphData(['M6.5 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 16.5 20.5h-10A1.5 1.5 0 0 1 5 19V5a1.5 1.5 0 0 1 1.5-1.5z', 'M11.5 11v6', 'M8.5 14h6'],
      f: ['M6.5 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 16.5 20.5h-10A1.5 1.5 0 0 1 5 19V5a1.5 1.5 0 0 1 1.5-1.5z']);
  static const bookmark = GlyphData(['M7 3.5h10A1.5 1.5 0 0 1 18.5 5v15.5L12 16.5l-6.5 4V5A1.5 1.5 0 0 1 7 3.5z'], f: ['M7 3.5h10A1.5 1.5 0 0 1 18.5 5v15.5L12 16.5l-6.5 4V5A1.5 1.5 0 0 1 7 3.5z']);
  static const clipboard = GlyphData(['M8.5 4.5h7A1.5 1.5 0 0 1 17 6v14a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 7 20V6a1.5 1.5 0 0 1 1.5-1.5z', 'M9.5 3.5h5a1 1 0 0 1 1 1V6h-7V4.5a1 1 0 0 1 1-1z', 'M9.5 10.5h5', 'M9.5 14h5'],
      f: ['M8.5 4.5h7A1.5 1.5 0 0 1 17 6v14a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 7 20V6a1.5 1.5 0 0 1 1.5-1.5z']);
  static const pip = GlyphData(['M4.5 5h15A1.5 1.5 0 0 1 21 6.5v11a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-11A1.5 1.5 0 0 1 4.5 5z', 'M12.5 11.5h5.5v4.5h-5.5z'], f: ['M12.5 11.5h5.5v4.5h-5.5z']);

  // ---- voice ----
  static const mic = GlyphData(['M12 3.5a3 3 0 0 1 3 3V12a3 3 0 0 1-6 0V6.5a3 3 0 0 1 3-3z', 'M5.5 11.5a6.5 6.5 0 0 0 13 0', 'M12 18v3'],
      f: ['M12 3.5a3 3 0 0 1 3 3V12a3 3 0 0 1-6 0V6.5a3 3 0 0 1 3-3z']);
  static const wave = GlyphData(['M4 10v4', 'M8 6.5v11', 'M12 4v16', 'M16 7.5v9', 'M20 10.5v3']);
  static const speaker = GlyphData(['M4 9.5h3.5L12 5.5v13l-4.5-4H4z', 'M15.5 9a4 4 0 0 1 0 6', 'M18 6.5a7.5 7.5 0 0 1 0 11'], f: ['M4 9.5h3.5L12 5.5v13l-4.5-4H4z']);
  static const ear = GlyphData(['M7 9a5 5 0 0 1 10 0c0 3-2.5 3.8-2.5 6.5a3 3 0 0 1-5.5 1.7', 'M10 9a2 2 0 0 1 4 0c0 1.3-1.2 1.6-1.6 2.6']);
  static const speakingHead = GlyphData(['M9.5 4.5a5 5 0 0 1 5 5c0 1.4-.5 2.2-.5 3l1.3 2.5h-1.8v2.5a1.5 1.5 0 0 1-1.5 1.5H10v1.5', 'M5 20v-3.5C3.8 15.4 3.5 14 3.5 12.5a6 6 0 0 1 6-8', 'M18 8.5a4 4 0 0 1 0 5', 'M20.3 6.5a7 7 0 0 1 0 9']);

  // ---- misc ----
  static const dot = GlyphData([], dots: [(12, 12, 4.5)]);

  /// Every glyph by name (for the glyph sheet).
  static const all = {
    'home': home,
    'chat': chat,
    'bell': bell,
    'routine': routine,
    'skill': skill,
    'memory': memory,
    'shield': shield,
    'shieldCheck': shieldCheck,
    'shieldAlert': shieldAlert,
    'sliders': sliders,
    'phone': phone,
    'keyboard': keyboard,
    'plus': plus,
    'more': more,
    'menu': menu,
    'clip': clip,
    'close': close,
    'check': check,
    'checkCircle': checkCircle,
    'alert': alert,
    'info': info,
    'warning': warning,
    'block': block,
    'trash': trash,
    'edit': edit,
    'copy': copy,
    'undo': undo,
    'external': external,
    'expand': expand,
    'collapse': collapse,
    'chevronRight': chevronRight,
    'arrowUp': arrowUp,
    'download': download,
    'sync': sync,
    'play': play,
    'stop': stop,
    'power': power,
    'bolt': bolt,
    'wand': wand,
    'send': send,
    'eye': eye,
    'eyeOff': eyeOff,
    'folder': folder,
    'file': file,
    'doc': doc,
    'sheet': sheet,
    'image': image,
    'mail': mail,
    'receipt': receipt,
    'money': money,
    'lock': lock,
    'key': key,
    'password': password,
    'box': box,
    'clock': clock,
    'globe': globe,
    'search': search,
    'monitor': monitor,
    'cloud': cloud,
    'sun': sun,
    'contrast': contrast,
    'coin': coin,
    'broom': broom,
    'flag': flag,
    'flask': flask,
    'hand': hand,
    'note': note,
    'bookmark': bookmark,
    'clipboard': clipboard,
    'pip': pip,
    'mic': mic,
    'wave': wave,
    'speaker': speaker,
    'ear': ear,
    'speakingHead': speakingHead,
    'dot': dot,
  };
}

/// Draws a [GlyphData]. Use like [Icon]: `Glyph(G.home, size: 20)`.
class Glyph extends StatelessWidget {
  const Glyph(this.data, {super.key, this.size, this.color, this.duo = false, this.duoColor, this.weight = 1.7});
  final GlyphData data;
  final double? size;
  final Color? color;

  /// Fill the main shape with a soft second tone (selected / active states).
  final bool duo;
  final Color? duoColor;
  final double weight;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? IconTheme.of(context).color ?? DefaultTextStyle.of(context).style.color ?? Colors.black;
    final side = size ?? IconTheme.of(context).size ?? 20;
    return SizedBox.square(
      dimension: side,
      child: CustomPaint(painter: _GlyphPainter(data, ink, duo ? (duoColor ?? ink).withValues(alpha: .18) : null, weight)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.data, this.ink, this.tone, this.weight);
  final GlyphData data;
  final Color ink;
  final Color? tone;
  final double weight;

  static final Map<String, Path> _cache = {};

  static Path path(String d) => _cache.putIfAbsent(d, () => parseSvgPath(d));

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    canvas.save();
    canvas.scale(k);
    if (tone != null) {
      final fill = Paint()..color = tone!;
      for (final d in data.f) {
        canvas.drawPath(path(d), fill);
      }
    }
    // Strokes stay crisp at small sizes: never thinner than ~1.25 px.
    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(weight, 1.25 / k)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final d in data.s) {
      canvas.drawPath(path(d), stroke);
    }
    final dot = Paint()..color = ink;
    for (final (x, y, r) in data.dots) {
      canvas.drawCircle(Offset(x, y), r, dot);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.data != data || old.ink != ink || old.tone != tone || old.weight != weight;
}

/// A small SVG path-data parser (M L H V C S Q T A Z, absolute and relative).
Path parseSvgPath(String d) {
  final path = Path();
  final tokens = RegExp(r'[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?').allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = 'M';
  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
  double? cx2, cy2; // last control point for S/T
  bool isCmd(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double n() => double.parse(tokens[i++]);
  bool flag() {
    // Arc flags may be packed ("01"), but our data never packs them.
    return n() != 0;
  }

  while (i < tokens.length) {
    if (isCmd(tokens[i])) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase();
    switch (cmd.toUpperCase()) {
      case 'M':
        x = (rel ? x : 0) + n();
        y = (rel ? y : 0) + n();
        path.moveTo(x, y);
        sx = x;
        sy = y;
        cmd = rel ? 'l' : 'L';
        cx2 = null;
      case 'L':
        x = (rel ? x : 0) + n();
        y = (rel ? y : 0) + n();
        path.lineTo(x, y);
        cx2 = null;
      case 'H':
        x = (rel ? x : 0) + n();
        path.lineTo(x, y);
        cx2 = null;
      case 'V':
        y = (rel ? y : 0) + n();
        path.lineTo(x, y);
        cx2 = null;
      case 'C':
        final x1 = (rel ? x : 0) + n(), y1 = (rel ? y : 0) + n();
        final x2 = (rel ? x : 0) + n(), y2 = (rel ? y : 0) + n();
        final ex = (rel ? x : 0) + n(), ey = (rel ? y : 0) + n();
        path.cubicTo(x1, y1, x2, y2, ex, ey);
        cx2 = x2;
        cy2 = y2;
        x = ex;
        y = ey;
      case 'S':
        final px = cx2, py = cy2;
        final x1 = px == null ? x : 2 * x - px, y1 = py == null ? y : 2 * y - py;
        final x2 = (rel ? x : 0) + n(), y2 = (rel ? y : 0) + n();
        final ex = (rel ? x : 0) + n(), ey = (rel ? y : 0) + n();
        path.cubicTo(x1, y1, x2, y2, ex, ey);
        cx2 = x2;
        cy2 = y2;
        x = ex;
        y = ey;
      case 'Q':
        final x1 = (rel ? x : 0) + n(), y1 = (rel ? y : 0) + n();
        final ex = (rel ? x : 0) + n(), ey = (rel ? y : 0) + n();
        path.quadraticBezierTo(x1, y1, ex, ey);
        cx2 = x1;
        cy2 = y1;
        x = ex;
        y = ey;
      case 'T':
        final px = cx2, py = cy2;
        final x1 = px == null ? x : 2 * x - px, y1 = py == null ? y : 2 * y - py;
        final ex = (rel ? x : 0) + n(), ey = (rel ? y : 0) + n();
        path.quadraticBezierTo(x1, y1, ex, ey);
        cx2 = x1;
        cy2 = y1;
        x = ex;
        y = ey;
      case 'A':
        final rx = n(), ry = n(), rot = n();
        final large = flag(), sweep = flag();
        final ex = (rel ? x : 0) + n(), ey = (rel ? y : 0) + n();
        path.arcToPoint(Offset(ex, ey), radius: Radius.elliptical(rx, ry), rotation: rot, largeArc: large, clockwise: sweep);
        x = ex;
        y = ey;
        cx2 = null;
      case 'Z':
        path.close();
        x = sx;
        y = sy;
        cx2 = null;
      default:
        i++;
    }
  }
  return path;
}
