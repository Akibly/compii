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

/// Give Compii your own eyes: choose a photo of your face, drag the two rings
/// onto your eyes, and see Compii wear them before you keep it. Returns true
/// when the eyes were saved.
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
    final path = RegExp(r'"path":"([^"]+)"').firstMatch(raw)?.group(1)?.replaceAll(r'\\', '\\');
    if (path != null && File(path).existsSync()) File(path).deleteSync();
  } on Object {
    // Already gone, or in use: nothing that matters to the user.
  }
}

class _EyePhotoDialog extends StatefulWidget {
  const _EyePhotoDialog();

  @override
  State<_EyePhotoDialog> createState() => _EyePhotoDialogState();
}

class _EyePhotoDialogState extends State<_EyePhotoDialog> {
  String? _path;
  ui.Image? _image;
  String? _problem;
  bool _saving = false;

  // Each eye as a circle in 0..1 of the photo's width (radius) and size.
  Offset _left = const Offset(.38, .42);
  Offset _right = const Offset(.62, .42);
  double _r = .07;

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
        setState(
          () => _problem =
              'Take a photo looking at the camera, then choose it here — '
              'the Camera app saves to Pictures › Camera Roll.',
        );
      }
    } on Object {
      if (mounted) setState(() => _problem = 'The Camera app didn’t open. Choose a photo you already have.');
    }
  }

  ({Offset c, double r}) _eye(Offset at) => (c: at, r: _r);

  PhotoEyes? get _preview {
    final img = _image;
    if (img == null) return null;
    Rect r(Offset at) => Rect.fromCircle(center: Offset(at.dx * img.width, at.dy * img.height), radius: _r * img.width);
    return PhotoEyes(image: img, left: r(_left), right: r(_right), path: _path ?? '');
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
      final raw = encodePhotoEyes(kept, _eye(_left), _eye(_right));
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
    return AlertDialog(
      title: const Text('Give Compii your eyes'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Compii wears your eyes behind its glass: they still blink, look at your pointer and show its '
                'moods. The photo stays on this PC, in your Compii folder, and is never sent anywhere.',
                style: context.type.bodySmall?.copyWith(color: c.muted),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _choose,
                    icon: const Glyph(G.image, size: 16),
                    label: Text(img == null ? 'Choose a photo' : 'Choose another'),
                  ),
                  if (Platform.isWindows)
                    OutlinedButton.icon(
                      onPressed: _camera,
                      icon: const Glyph(G.eye, size: 16),
                      label: const Text('Take one with Camera'),
                    ),
                ],
              ),
              if (_problem != null) ...[
                const SizedBox(height: 10),
                Text(_problem!, style: context.type.bodySmall?.copyWith(color: c.warning)),
              ],
              if (img != null) ...[
                const SizedBox(height: 16),
                Text('Drag the two rings onto your eyes', style: context.type.labelLarge),
                const SizedBox(height: 8),
                _Marker(
                  image: img,
                  left: _left,
                  right: _right,
                  r: _r,
                  onLeft: (v) => setState(() => _left = v),
                  onRight: (v) => setState(() => _right = v),
                ),
                Row(
                  children: [
                    Text('Ring size', style: context.type.labelMedium?.copyWith(color: c.muted)),
                    Expanded(
                      child: Slider(
                        value: _r,
                        min: .02,
                        max: .2,
                        label: 'Ring size',
                        onChanged: (v) => setState(() => _r = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('How Compii will look', style: context.type.labelLarge),
                const SizedBox(height: 8),
                Container(
                  height: 150,
                  decoration: BoxDecoration(color: const Color(0xFF050507), borderRadius: BorderRadius.circular(16)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final m in const [Mood.idle, Mood.listening, Mood.happy, Mood.waiting])
                        SizedBox.square(
                          dimension: 120,
                          child: CustomPaint(
                            painter: _PreviewPainter(
                              form: compiiBody.value,
                              color: compiiColor.value,
                              photo: _preview!,
                              mood: m,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: img == null || _saving ? null : _save,
          child: Text(_saving ? 'Keeping…' : 'Use my eyes'),
        ),
      ],
    );
  }
}

/// The photo with two draggable rings; positions are in 0..1 of the photo.
class _Marker extends StatelessWidget {
  const _Marker({
    required this.image,
    required this.left,
    required this.right,
    required this.r,
    required this.onLeft,
    required this.onRight,
  });
  final ui.Image image;
  final Offset left, right;
  final double r;
  final ValueChanged<Offset> onLeft, onRight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = (w * image.height / image.width).clamp(120.0, 420.0);
        final scale = h / image.height;
        final shown = Size(image.width * scale, h);
        final ox = (w - shown.width) / 2;
        Widget ring(Offset at, String label, ValueChanged<Offset> moved) {
          final d = r * shown.width * 2;
          return Positioned(
            left: ox + at.dx * shown.width - d / 2,
            top: at.dy * shown.height - d / 2,
            child: Semantics(
              label: '$label ring, drag onto your eye',
              child: GestureDetector(
                onPanUpdate: (u) => moved(
                  Offset(
                    (at.dx + u.delta.dx / shown.width).clamp(0.0, 1.0),
                    (at.dy + u.delta.dy / shown.height).clamp(0.0, 1.0),
                  ),
                ),
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Container(
                    width: d,
                    height: d,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [BoxShadow(color: compiiColor.value.withValues(alpha: .8), blurRadius: 10)],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return SizedBox(
          width: w,
          height: h,
          child: Stack(
            children: [
              Positioned(
                left: ox,
                top: 0,
                width: shown.width,
                height: shown.height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RawImage(image: image, fit: BoxFit.fill),
                ),
              ),
              ring(left, 'Left', onLeft),
              ring(right, 'Right', onRight),
            ],
          ),
        );
      },
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter({required this.form, required this.color, required this.photo, required this.mood});
  final HaloForm form;
  final Color color;
  final PhotoEyes photo;
  final Mood mood;

  @override
  void paint(Canvas canvas, Size size) => Halo.paint(
    canvas,
    centre: size.center(Offset.zero),
    span: size.shortestSide * .9,
    form: form,
    color: color,
    pose: HaloPose(mood: mood),
    photo: photo,
    shadow: false,
  );

  @override
  bool shouldRepaint(covariant _PreviewPainter o) =>
      o.photo.left != photo.left || o.photo.right != photo.right || o.photo.image != photo.image || o.mood != mood;
}
