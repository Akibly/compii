import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../art/halo.dart';
import '../art/photo_eyes.dart';
import '../console/character.dart' show Mood, compiiBody, compiiColor;
import 'glyphs.dart';
import 'tokens.dart';

/// Give Compii your own eyes: choose a photo of your face, slide one band over
/// your eyes, and watch Compii wear them before you keep it. Returns true when
/// the eyes were saved.
Future<bool> showEyePhotoPicker(BuildContext context) async =>
    await showDialog<bool>(context: context, builder: (_) => const _EyePhotoDialog()) ?? false;

/// Back to Compii's eyes of light; the copied photo is deleted too.
Future<void> clearEyePhoto() async {
  final p = await SharedPreferences.getInstance();
  final raw = p.getString('compii_eyes');
  await p.remove('compii_eyes');
  await applyPhotoEyes(null);
  if (raw == null) return;
  try {
    final path = (jsonDecode(raw) as Map)['path'] as String?;
    if (path != null && File(path).existsSync()) File(path).deleteSync();
  } on Object {
    // Already gone, or in use: nothing that matters to the user.
  }
}

/// The dialog already holding a photo, for tests and previews.
@visibleForTesting
Widget eyePhotoDialogWith(ui.Image image) => _EyePhotoDialog(initial: image);

class _EyePhotoDialog extends StatefulWidget {
  const _EyePhotoDialog({this.initial});
  final ui.Image? initial;

  @override
  State<_EyePhotoDialog> createState() => _EyePhotoDialogState();
}

class _EyePhotoDialogState extends State<_EyePhotoDialog> with SingleTickerProviderStateMixin {
  String? _path;
  late ui.Image? _image = widget.initial;
  String? _problem;
  bool _saving = false;

  /// The band over both eyes: its centre in 0..1 of the photo, and its width as
  /// a share of the photo's width. Its height follows the visor's proportions.
  Offset _centre = const Offset(.5, .42);
  double _width = .5;

  // The preview breathes through Compii's moods so you see the eyes alive.
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 8))
    ..repeat();
  static const _moods = [Mood.idle, Mood.listening, Mood.happy, Mood.thinking];

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image, dialogTitle: 'Choose a photo of your face');
      final path = picked.isEmpty ? null : picked.first.path;
      if (path == null) return;
      final codec = await decodeEyePhoto(await File(path).readAsBytes());
      final image = (await codec.getNextFrame()).image;
      if (!mounted) return;
      setState(() {
        _path = path;
        _image = image;
        _problem = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _problem = 'That photo couldn’t be opened: $e');
    }
  }

  Future<void> _camera() async {
    // Windows' own Camera app takes the picture; Compii never touches the camera.
    try {
      await Process.start('explorer.exe', ['microsoft.windows.camera:']);
      if (mounted) {
        setState(() => _problem = 'Look straight at the camera in good light, then choose the photo here. '
            'The Camera app saves to Pictures › Camera Roll.');
      }
    } on Object {
      if (mounted) setState(() => _problem = 'The Camera app didn’t open. Choose a photo you already have.');
    }
  }

  /// The band as the two eye circles the saved format keeps.
  /// Each eye sits a little in from its end of the band.
  (({Offset c, double r}), ({Offset c, double r})) get _eyes {
    final dx = _width * .28;
    return (
      (c: Offset(_centre.dx - dx, _centre.dy), r: _width * .2),
      (c: Offset(_centre.dx + dx, _centre.dy), r: _width * .2),
    );
  }

  PhotoEyes? get _preview {
    final img = _image;
    if (img == null) return null;
    final (l, r) = _eyes;
    Rect at(({Offset c, double r}) e) =>
        Rect.fromCircle(center: Offset(e.c.dx * img.width, e.c.dy * img.height), radius: e.r * img.width);
    return PhotoEyes(image: img, left: at(l), right: at(r), path: _path ?? '');
  }

  Future<void> _save() async {
    final path = _path;
    if (path == null) return;
    setState(() => _saving = true);
    try {
      final home = photoEyesHome()..createSync(recursive: true);
      final ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'png';
      final kept = '${home.path}${Platform.pathSeparator}my-eyes.$ext';
      await File(path).copy(kept);
      final (l, r) = _eyes;
      final raw = encodePhotoEyes(kept, l, r);
      final p = await SharedPreferences.getInstance();
      await p.setString('compii_eyes', raw);
      await applyPhotoEyes(raw);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _problem = 'Couldn’t keep the photo: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final img = _image;
    final photo = _preview;
    final preview = AnimatedBuilder(
      animation: _clock,
      builder: (context, _) {
        final slot = (_clock.value * _moods.length).floor() % _moods.length;
        return CustomPaint(
          painter: _PreviewPainter(
            form: compiiBody.value,
            color: compiiColor.value,
            photo: photo,
            mood: _moods[slot],
            t: _clock.value,
          ),
        );
      },
    );
    return Dialog(
      backgroundColor: const Color(0xFF0B0B0F),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your eyes, on Compii', style: context.type.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                'Like EyeSight: your eyes appear behind Compii’s glass, tinted in its colour. They blink, '
                'follow your pointer and change with its moods. The photo stays on this PC.',
                style: context.type.bodyMedium?.copyWith(color: c.muted),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth > 640;
                    final left = img == null
                        ? _Empty(onChoose: _choose, onCamera: Platform.isWindows ? _camera : null)
                        : _BandMarker(
                            image: img,
                            centre: _centre,
                            width: _width,
                            onMove: (v) => setState(() => _centre = v),
                            onResize: (v) => setState(() => _width = v),
                          );
                    final right = Container(
                      decoration: BoxDecoration(color: const Color(0xFF050507), borderRadius: BorderRadius.circular(20)),
                      child: Stack(
                        children: [
                          Positioned.fill(child: preview),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 14,
                            child: Text(
                              img == null ? 'Eyes of light, for now' : 'How Compii will look',
                              textAlign: TextAlign.center,
                              style: context.type.labelMedium?.copyWith(color: c.faint),
                            ),
                          ),
                        ],
                      ),
                    );
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 3, child: left),
                              const SizedBox(width: 18),
                              Expanded(flex: 2, child: right),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [Expanded(child: left), const SizedBox(height: 14), SizedBox(height: 200, child: right)],
                          );
                  },
                ),
              ),
              if (_problem != null) ...[
                const SizedBox(height: 12),
                Text(_problem!, style: context.type.bodySmall?.copyWith(color: c.warning)),
              ],
              if (img != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Glyph(G.hand, size: 15, color: c.faint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Drag the band over your eyes. Drag its edge to fit.',
                        style: context.type.labelMedium?.copyWith(color: c.faint),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  if (img != null) TextButton(onPressed: _choose, child: const Text('Another photo')),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF2F2F5), foregroundColor: const Color(0xFF0A0A0D)),
                    onPressed: img == null || _saving ? null : _save,
                    child: Text(_saving ? 'Keeping…' : 'Use my eyes'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Before a photo: what to do, and why it is safe.
class _Empty extends StatelessWidget {
  const _Empty({required this.onChoose, this.onCamera});
  final VoidCallback onChoose;
  final VoidCallback? onCamera;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111116),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Glyph(G.image, size: 34, color: c.faint),
          const SizedBox(height: 14),
          Text('A clear, front-facing photo', style: context.type.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Good light, eyes open, looking at the camera. Only the band across your eyes is used.',
            textAlign: TextAlign.center,
            style: context.type.bodySmall?.copyWith(color: c.muted),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF2F2F5), foregroundColor: const Color(0xFF0A0A0D)),
                onPressed: onChoose,
                child: const Text('Choose a photo'),
              ),
              if (onCamera != null) OutlinedButton(onPressed: onCamera, child: const Text('Take one with Camera')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The photo, dimmed everywhere except a visor-shaped band you slide over your
/// eyes; dragging the band's right edge resizes it.
class _BandMarker extends StatelessWidget {
  const _BandMarker({
    required this.image,
    required this.centre,
    required this.width,
    required this.onMove,
    required this.onResize,
  });
  final ui.Image image;
  final Offset centre;
  final double width;
  final ValueChanged<Offset> onMove;
  final ValueChanged<double> onResize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final scale = (box.maxWidth / image.width).clamp(0.0, box.maxHeight / image.height);
        final shown = Size(image.width * scale, image.height * scale);
        final origin = Offset((box.maxWidth - shown.width) / 2, (box.maxHeight - shown.height) / 2);
        final bw = width * shown.width;
        final band = Rect.fromCenter(
          center: origin + Offset(centre.dx * shown.width, centre.dy * shown.height),
          width: bw,
          height: bw * .36,
        );
        return Stack(
          children: [
            Positioned(
              left: origin.dx,
              top: origin.dy,
              width: shown.width,
              height: shown.height,
              child: ClipRRect(borderRadius: BorderRadius.circular(16), child: RawImage(image: image, fit: BoxFit.fill)),
            ),
            Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: _DimOutside(band: band, color: compiiColor.value))),
            ),
            Positioned.fromRect(
              rect: band,
              child: Semantics(
                label: 'Eye band. Drag it over your eyes.',
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: GestureDetector(
                    onPanUpdate: (u) => onMove(Offset(
                      (centre.dx + u.delta.dx / shown.width).clamp(0.0, 1.0),
                      (centre.dy + u.delta.dy / shown.height).clamp(0.0, 1.0),
                    )),
                  ),
                ),
              ),
            ),
            Positioned(
              left: band.right - 10,
              top: band.center.dy - 14,
              width: 20,
              height: 28,
              child: Semantics(
                label: 'Resize the eye band',
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: GestureDetector(
                    onPanUpdate: (u) => onResize((width + u.delta.dx * 2 / shown.width).clamp(.15, .95)),
                    child: Center(
                      child: Container(
                        width: 6,
                        height: 22,
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DimOutside extends CustomPainter {
  _DimOutside({required this.band, required this.color});
  final Rect band;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final visor = RRect.fromRectAndRadius(band, Radius.circular(band.height / 2));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(visor)),
      Paint()..color = const Color(0xA6000000),
    );
    canvas.drawRRect(
      visor,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = color.withValues(alpha: .5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      visor,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: .9),
    );
  }

  @override
  bool shouldRepaint(covariant _DimOutside o) => o.band != band || o.color != color;
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter({required this.form, required this.color, required this.photo, required this.mood, required this.t});
  final HaloForm form;
  final Color color;
  final PhotoEyes? photo;
  final Mood mood;
  final double t;

  @override
  void paint(Canvas canvas, Size size) => Halo.paint(
    canvas,
    centre: size.center(Offset.zero) - const Offset(0, 10),
    span: size.shortestSide * .78,
    form: form,
    color: color,
    pose: HaloPose(mood: mood, t: t, s: (t * 4.6) % 1, still: false),
    photo: photo,
    shadow: false,
  );

  @override
  bool shouldRepaint(covariant _PreviewPainter o) =>
      o.photo?.left != photo?.left || o.photo?.image != photo?.image || o.mood != mood || o.t != t || o.form != form;
}
