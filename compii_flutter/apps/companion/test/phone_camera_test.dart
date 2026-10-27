// Showing Compii a photo from the phone: the choices, and what each one asks.
import 'package:compii/src/ui/phone_camera.dart';
import 'package:compii/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each choice names the photo and asks for what it promises', () {
    expect(PhotoAsk.what.request(['IMG_1.jpg']), contains('this photo from my phone (IMG_1.jpg)'));
    expect(PhotoAsk.read.request(['a.jpg', 'b.jpg']), contains('these photos from my phone (a.jpg, b.jpg)'));
    final doc = PhotoAsk.document.request(['scan.jpg']);
    expect(doc, contains('look_at_photo'));
    expect(doc, contains('Scans folder in my Documents'));
    expect(PhotoAsk.summarise.request(['q3.pdf']), contains('this file from my phone (q3.pdf)'));
    expect(isPhotoPath('/cache/shared/IMG_1.JPG'), isTrue);
    expect(isPhotoPath('/cache/shared/q3.pdf'), isFalse);
  });

  Future<({PhotoAsk ask, bool gallery})?> open(WidgetTester tester, {int shared = 0, bool photos = true}) async {
    ({PhotoAsk ask, bool gallery})? got;
    await tester.pumpWidget(MaterialApp(
      theme: compiiTheme(Brightness.dark),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await choosePhotoAsk(context, pc: 'Desk', shared: shared, photos: photos),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return got;
  }

  testWidgets('the camera offers four questions and a photo you already have', (tester) async {
    await open(tester);
    for (final label in ['What is this?', 'Read this', 'Translate this', 'Snap a document', 'Use a photo you have']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Save it on the PC'), findsNothing);
  });

  testWidgets('a shared PDF gets file choices, not camera ones', (tester) async {
    await open(tester, shared: 1, photos: false);
    expect(find.text('A file from another app, to Desk'), findsOneWidget);
    expect(find.text('Ask Compii about it'), findsOneWidget);
    expect(find.text('Save it on the PC'), findsOneWidget);
    expect(find.text('What is this?'), findsNothing);
    expect(find.text('Use a photo you have'), findsNothing);
  });
}
