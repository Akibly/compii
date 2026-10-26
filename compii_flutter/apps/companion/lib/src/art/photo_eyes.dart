import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Your own eyes, worn by Compii — the idea behind Vision Pro's EyeSight. You
/// pick a photo of your face and mark your two eyes; Compii shows those two
/// pieces of the photo where its eyes of light would be, behind its glass, and
/// keeps them alive: the lids close to blink, the view shifts toward where it
/// is looking, they squint when happy and slant when worried.
///
/// The photo never leaves this PC: it is copied into the Compii folder in your
/// home folder and only read from there.
class PhotoEyes {
  const PhotoEyes({required this.image, required this.left, required this.right, required this.path});
  final ui.Image image;

  /// Each eye's square, in the image's own pixels: the eye on the left of the
  /// photo and the eye on the right.
  final Rect left, right;
  final String path;
}

/// Compii's own photo eyes, when the user has chosen some. Teammates never wear
/// them — the user's face is Compii's alone.
final compiiPhotoEyes = ValueNotifier<PhotoEyes?>(null);

/// Where a chosen photo is kept: beside the app's log in ~/Compii.
Directory photoEyesHome() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  return Directory('$home${Platform.pathSeparator}Compii');
}

/// What is saved in preferences: the photo's path and each eye as a circle in
/// 0..1 of the photo's width and height.
String encodePhotoEyes(String path, ({Offset c, double r}) left, ({Offset c, double r}) right) => jsonEncode({
  'v': 1,
  'path': path,
  'left': [left.c.dx, left.c.dy, left.r],
  'right': [right.c.dx, right.c.dy, right.r],
});

/// Decode a photo, shrinking a large one to 1600 px wide; a small one is kept
/// as it is.
Future<ui.Codec> decodeEyePhoto(List<int> bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes));
  return ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) => w > 1600 ? ui.TargetImageSize(width: 1600) : ui.TargetImageSize(),
  );
}

String? _loaded;

/// Load the saved eyes into [compiiPhotoEyes], or clear them. Cheap to call
/// again with the same value: the photo is decoded once.
Future<void> applyPhotoEyes(String? raw) async {
  if (raw == null || raw.isEmpty) {
    _loaded = null;
    compiiPhotoEyes.value = null;
    return;
  }
  if (raw == _loaded) return;
  _loaded = raw;
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final file = File('${m['path']}');
    if (!file.existsSync()) {
      compiiPhotoEyes.value = null;
      return;
    }
    final codec = await decodeEyePhoto(await file.readAsBytes());
    final image = (await codec.getNextFrame()).image;
    Rect eye(List<dynamic> v) {
      final x = (v[0] as num) * image.width, y = (v[1] as num) * image.height;
      final r = (v[2] as num) * image.width;
      return Rect.fromCircle(center: Offset(x.toDouble(), y.toDouble()), radius: r.toDouble());
    }

    if (_loaded != raw) return; // a newer choice arrived while this one decoded
    compiiPhotoEyes.value = PhotoEyes(
      image: image,
      left: eye(m['left'] as List),
      right: eye(m['right'] as List),
      path: file.path,
    );
  } on Object {
    // An unreadable photo leaves Compii with its eyes of light.
    compiiPhotoEyes.value = null;
  }
}

/// The EyeSight band: both of your eyes as one strip across Compii's glass, the
/// way Vision Pro shows them — never two cut-outs pasted on. It is graded into
/// Compii's colour (shadows go deep, highlights go pale), feathered at every
/// edge so it has no outline, seen through fine horizontal ribbing like a
/// lenticular layer, and dimmer than the glass around it.
///
/// The rig still drives it: soft lids come down from the top to blink and to
/// narrow, a smile lifts the lower edge, a tilt slants the lids, the gaze pans
/// the photo, and while Compii is busy a moving glow of its colour drifts over
/// the band the way EyeSight's glow does when you are immersed.
void paintEyeBand(
  Canvas canvas, {
  required Offset centre,
  required double width,
  required double height,
  required PhotoEyes photo,
  required Color color,
  double open = 1,
  double joy = 0,
  double tilt = 0,
  double busy = 0,
  double t = 0,
  Offset gaze = Offset.zero,
  double unit = 0,
}) {
  final band = Rect.fromCenter(center: centre, width: width, height: height);
  // The photo strip: both eyes and a little brow and cheek, matched to the band.
  final eyes = photo.left.expandToInclude(photo.right);
  final sw = eyes.width * 1.18;
  final sh = math.min(photo.image.height.toDouble(), sw * height / width);
  final pan = Offset(-gaze.dx.clamp(-1.0, 1.0) * sw * .05, -gaze.dy.clamp(-1.0, 1.0) * sh * .08);
  var src = Rect.fromCenter(center: eyes.center + pan, width: sw, height: sh);
  src = src.shift(Offset(
    src.left < 0 ? -src.left : (src.right > photo.image.width ? photo.image.width - src.right : 0),
    src.top < 0 ? -src.top : (src.bottom > photo.image.height ? photo.image.height - src.bottom : 0),
  ));

  // The glow the band sits in.
  canvas.drawOval(
    band.inflate(height * .25),
    Paint()
      ..color = color.withValues(alpha: .22 + .18 * busy)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(height * .5, unit * 4)),
  );

  canvas.saveLayer(band.inflate(2), Paint());
  // Graded into Compii's colour: luminance mapped from a deep shade of it to a
  // pale tint, with a little of the real colour left in.
  final deep = Color.lerp(color, Colors.black, .78)!;
  final pale = Color.lerp(color, Colors.white, .82)!;
  double ch(Color c, int i) => switch (i) { 0 => c.r, 1 => c.g, _ => c.b } * 255;
  List<double> row(int i) {
    final d = ch(deep, i), p = ch(pale, i) - ch(deep, i);
    const keep = .28;
    final lum = [.2126 * (1 - keep), .7152 * (1 - keep), .0722 * (1 - keep)];
    final self = [0.0, 0.0, 0.0]..[i] = keep;
    return [
      lum[0] * p / 255 + self[0],
      lum[1] * p / 255 + self[1],
      lum[2] * p / 255 + self[2],
      0,
      d * (1 - keep),
    ];
  }

  canvas.drawImageRect(
    photo.image,
    src,
    band,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.matrix([...row(0), ...row(1), ...row(2), 0, 0, 0, 1, 0]),
  );
  // Busy: a slow glow of the colour drifting across, eyes still faintly there.
  if (busy > 0) {
    final x = band.left + band.width * ((t * 1.7) % 1);
    canvas.drawRect(
      band,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = ui.Gradient.radial(Offset(x, band.center.dy), band.width * .45, [
          Color.lerp(color, Colors.white, .3)!.withValues(alpha: .55 * busy),
          color.withValues(alpha: 0),
        ]),
    );
  }
  // Lenticular ribbing: fine horizontal lines, the texture of looking through.
  final step = math.max(unit * 2, height / 26);
  final rib = Paint()..color = Colors.black.withValues(alpha: .16);
  for (var y = band.top; y < band.bottom; y += step) {
    canvas.drawRect(Rect.fromLTWH(band.left, y, band.width, step * .45), rib);
  }
  // Lids: soft dark from the top as the eyes close or narrow, slanted by tilt.
  final cover = (1 - open.clamp(0.0, 1.0));
  if (cover > .01 || tilt.abs() > .05) {
    final lid = band.top + band.height * (cover * .9 + .02);
    final slope = tilt.clamp(-1.0, 1.0) * band.height * .22;
    final lidPath = Path()
      ..moveTo(band.left - 1, band.top - 1)
      ..lineTo(band.right + 1, band.top - 1)
      ..lineTo(band.right + 1, lid - slope)
      ..lineTo(band.center.dx, lid + slope.abs() * .4)
      ..lineTo(band.left - 1, lid - slope)
      ..close();
    canvas.drawPath(
      lidPath,
      Paint()
        ..color = const Color(0xF007070B)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(height * .08, unit * 1.5)),
    );
  }
  // A smile lifts the lower edge into a soft arc.
  if (joy > .05) {
    final lift = Path()
      ..moveTo(band.left - 1, band.bottom + 1)
      ..quadraticBezierTo(band.center.dx, band.bottom - band.height * .9 * joy, band.right + 1, band.bottom + 1)
      ..close();
    canvas.drawPath(
      lift,
      Paint()
        ..color = const Color(0xF007070B)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(height * .1, unit * 1.5)),
    );
  }
  // Feather every edge with one oval falloff — a visor's shape, no outline
  // anywhere — so the band melts into the glass instead of sitting on it.
  final sy = band.height / band.width;
  canvas.drawRect(
    band.inflate(2),
    Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = ui.Gradient.radial(
        band.center,
        band.width * .5,
        [const Color(0xE6000000), const Color(0xB3000000), const Color(0x00000000)],
        const [0, .5, 1],
        TileMode.clamp,
        Float64List.fromList([1, 0, 0, 0, 0, sy, 0, 0, 0, 0, 1, 0, 0, band.center.dy * (1 - sy), 0, 1]),
      ),
  );
  canvas.restore();
}
