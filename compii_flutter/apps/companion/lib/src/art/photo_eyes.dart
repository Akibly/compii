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

/// One photo eye, drawn into [dest] inside [clip]: the photo, panned toward
/// [gaze], under a faint wash of Compii's colour and a glass sheen, with a soft
/// bloom of the colour around it so it still reads as Compii.
void paintPhotoEye(
  Canvas canvas, {
  required Path clip,
  required Rect dest,
  required ui.Image image,
  required Rect source,
  required Color tint,
  Offset gaze = Offset.zero,
  double unit = 0,
}) {
  canvas.drawPath(
    clip,
    Paint()
      ..color = tint.withValues(alpha: .7)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(dest.width * .18, unit * 2)),
  );
  // Match the photo's crop to the eye's shape, then pan it: moving the window
  // the other way makes the iris travel toward where Compii looks.
  final aspect = dest.height / math.max(dest.width, 1e-6);
  final sw = source.width;
  final sh = math.min(source.height, sw * aspect);
  final pan = Offset(-gaze.dx.clamp(-1.0, 1.0) * sw * .14, -gaze.dy.clamp(-1.0, 1.0) * sh * .12);
  var src = Rect.fromCenter(center: source.center + pan, width: sw, height: sh);
  src = src.shift(
    Offset(
      src.left < 0 ? -src.left : (src.right > image.width ? image.width - src.right : 0),
      src.top < 0 ? -src.top : (src.bottom > image.height ? image.height - src.bottom : 0),
    ),
  );
  canvas.save();
  canvas.clipPath(clip);
  canvas.drawImageRect(image, src, dest, Paint()..filterQuality = FilterQuality.medium);
  canvas.drawRect(dest, Paint()..color = tint.withValues(alpha: .12));
  canvas.drawRect(
    dest,
    Paint()
      ..shader = ui.Gradient.linear(dest.topCenter, dest.center, [
        Colors.white.withValues(alpha: .18),
        Colors.white.withValues(alpha: 0),
      ]),
  );
  canvas.restore();
  canvas.drawPath(
    clip,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(unit, dest.height * .035)
      ..color = Color.lerp(tint, Colors.white, .5)!.withValues(alpha: .55),
  );
}
