// Compii wearing the user's own eyes: saved, loaded back, and still alive in
// every mood. With --dart-define=CAPTURE=true it saves a sheet for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:compii/src/art/halo.dart';
import 'package:compii/src/art/photo_eyes.dart';
import 'package:compii/src/console/character.dart' show Mood;
import 'package:compii/src/ui/eye_photo.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in face: skin, two eyes with an iris and a pupil.
Future<ui.Image> _face() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 400, 300), Paint()..color = const Color(0xFFD9A07E));
  for (final x in const [140.0, 260.0]) {
    c.drawOval(Rect.fromCenter(center: Offset(x, 130), width: 70, height: 38), Paint()..color = Colors.white);
    c.drawCircle(Offset(x, 130), 16, Paint()..color = const Color(0xFF5A3A22));
    c.drawCircle(Offset(x, 130), 7, Paint()..color = Colors.black);
    c.drawCircle(Offset(x - 5, 124), 3, Paint()..color = Colors.white);
  }
  return rec.endRecording().toImage(400, 300);
}

class _Sheet extends CustomPainter {
  _Sheet(this.photo);
  final PhotoEyes photo;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF050507));
    final moods = Mood.values;
    // One large, to judge the band up close.
    Halo.paint(canvas, centre: const Offset(1340, 150), span: 280, form: HaloForm.orb, color: haloBlue,
        pose: const HaloPose(mood: Mood.idle), photo: photo);
    for (final (i, m) in moods.indexed) {
      Halo.paint(
        canvas,
        centre: Offset(70 + i * 130.0, 80),
        span: 120,
        form: HaloForm.values[i % HaloForm.values.length],
        color: haloBlue,
        pose: HaloPose(mood: m, look: i.isEven ? const Offset(.8, 0) : const Offset(-.8, -.3)),
        photo: photo,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

void main() {
  tearDown(() => applyPhotoEyes(null));

  testWidgets('the chosen eyes are saved, loaded back from disk, and cleared', (tester) async {
    final dir = Directory.systemTemp.createTempSync('compii_eyes');
    addTearDown(() => dir.deleteSync(recursive: true));
    final face = await tester.runAsync(_face);
    final png = await tester.runAsync(() => face!.toByteData(format: ui.ImageByteFormat.png));
    final file = File('${dir.path}/face.png')..writeAsBytesSync(png!.buffer.asUint8List());

    final raw = encodePhotoEyes(
      file.path,
      (c: const Offset(.35, .433), r: .1),
      (c: const Offset(.65, .433), r: .1),
    );
    await tester.runAsync(() => applyPhotoEyes(raw));
    final eyes = compiiPhotoEyes.value;
    expect(eyes, isNotNull);
    expect(eyes!.left.center.dx, closeTo(140, 1));
    expect(eyes.right.center.dx, closeTo(260, 1));
    expect(eyes.left.width, closeTo(80, 1), reason: 'the ring is a fraction of the photo’s width');

    await tester.runAsync(() => applyPhotoEyes(null));
    expect(compiiPhotoEyes.value, isNull, reason: 'back to the eyes of light');
  });

  testWidgets('a missing photo leaves Compii with its eyes of light', (tester) async {
    await tester.runAsync(
      () => applyPhotoEyes(encodePhotoEyes(r'C:\nowhere\gone.png', (c: Offset.zero, r: .1), (c: Offset.zero, r: .1))),
    );
    expect(compiiPhotoEyes.value, isNull);
  });

  testWidgets('photo eyes paint in every mood and form', (tester) async {
    final face = (await tester.runAsync(_face))!;
    final photo = PhotoEyes(
      image: face,
      left: Rect.fromCircle(center: const Offset(140, 130), radius: 40),
      right: Rect.fromCircle(center: const Offset(260, 130), radius: 40),
      path: '',
    );
    tester.view.physicalSize = const Size(1500, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: CustomPaint(size: const Size(1500, 300), painter: _Sheet(photo))),
    );
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews/halo')..createSync(recursive: true);
      await tester.runAsync(() => File('${out.path}/photo-eyes.png').writeAsBytes(bytes!.buffer.asUint8List()));
    }
  });

  testWidgets('the setup shows the photo with one band to slide, and Compii wearing it', (tester) async {
    final face = (await tester.runAsync(_face))!;
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.dark),
      home: RepaintBoundary(key: key, child: Scaffold(backgroundColor: Colors.black, body: eyePhotoDialogWith(face))),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Your eyes, on Compii'), findsOneWidget);
    expect(find.text('Use my eyes'), findsOneWidget);
    expect(find.bySemanticsLabel('Eye band. Drag it over your eyes.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
      final out = Directory('../../../docs/compii/build-previews/halo')..createSync(recursive: true);
      await tester.runAsync(() => File('${out.path}/eyes-setup.png').writeAsBytes(bytes!.buffer.asUint8List()));
    }
    await tester.pumpWidget(const SizedBox());
  });
}
