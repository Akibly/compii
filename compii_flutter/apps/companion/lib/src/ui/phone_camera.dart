import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'glyphs.dart';
import 'tokens.dart';

/// What to ask about a photo. Each becomes a plain request with the photo
/// attached; Compii looks at it on the PC (look_at_photo) and answers in a chat.
enum PhotoAsk {
  what('What is this?', 'And anything worth knowing', G.eye),
  read('Read this', 'Every word, exactly as written', G.doc),
  translate('Translate this', 'Into English, keeping the layout', G.globe),
  document('Snap a document', 'A summary, and the text filed on your PC', G.file),
  summarise('Ask Compii about it', 'What it is, and a short summary', G.chat),
  save('Save it on the PC', 'Kept in Compii’s uploads folder', G.folder);

  const PhotoAsk(this.label, this.detail, this.glyph);
  final String label;
  final String detail;
  final GlyphData glyph;

  static const forPhotos = [what, read, translate, document];
  static const forFiles = [summarise, save];

  /// The request sent with the attachments, by their names.
  String request(List<String> names) {
    final these = names.length == 1 ? 'this photo from my phone (${names.first})' : 'these photos from my phone (${names.join(', ')})';
    return switch (this) {
      what => 'What is this? Look at $these and tell me briefly what it is and anything worth knowing.',
      read => 'Read $these and give me every word in it exactly, in reading order.',
      translate => 'Translate the words in $these into English, keeping the layout, and say which language it was in.',
      document => 'I snapped ${names.length == 1 ? 'this document' : 'these pages'} on my phone (${names.join(', ')}). '
          'Look at ${names.length == 1 ? 'it' : 'them'} with look_at_photo, tell me in two or three sentences what it is '
          'and anything I need to do (dates, amounts, deadlines), then save the full text as a Word document named after '
          'what it is, in a Scans folder in my Documents, and tell me where.',
      summarise => 'I sent ${names.length == 1 ? 'this file' : 'these files'} from my phone (${names.join(', ')}). '
          'Read ${names.length == 1 ? 'it' : 'them'} and tell me briefly what it is and anything worth knowing.',
      save => '',
    };
  }
}

/// The photo choices, as a sheet. `shared` is a photo or file already chosen
/// (from the share sheet); otherwise the camera opens after the choice, or the
/// gallery when "Use a photo you have" is picked.
Future<({PhotoAsk ask, bool gallery})?> choosePhotoAsk(BuildContext context, {required String pc, int shared = 0, bool photos = true}) {
  final options = photos ? [...PhotoAsk.forPhotos, if (shared > 0) PhotoAsk.save] : PhotoAsk.forFiles;
  return showModalBottomSheet<({PhotoAsk ask, bool gallery})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(shared > 0 ? 'Send to Compii' : 'Show Compii', style: context.type.titleLarge),
            const SizedBox(height: 2),
            Text(
              shared > 0
                  ? '${shared == 1 ? (photos ? 'A photo' : 'A file') : '$shared ${photos ? 'photos' : 'files'}'} from another app, to $pc'
                  : 'Take a photo; Compii looks at it on $pc',
              style: context.type.bodySmall?.copyWith(color: context.c.muted),
            ),
            const SizedBox(height: 10),
            for (final o in options)
              ListTile(
                leading: Glyph(o.glyph),
                title: Text(o.label),
                subtitle: Text(o.detail),
                onTap: () => Navigator.pop(context, (ask: o, gallery: false)),
              ),
            if (shared == 0) ...[
              const Divider(height: 18),
              ListTile(
                leading: const Glyph(G.image),
                title: const Text('Use a photo you have'),
                subtitle: const Text('Then pick what to ask'),
                onTap: () => Navigator.pop(context, (ask: PhotoAsk.what, gallery: true)),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// A photo from the camera or the gallery, sized for reading but not huge.
/// Null when you back out.
Future<String?> takePhoto({bool gallery = false}) async {
  final shot = await ImagePicker().pickImage(
    source: gallery ? ImageSource.gallery : ImageSource.camera,
    maxWidth: 2400,
    maxHeight: 2400,
    imageQuality: 85,
  );
  return shot?.path;
}

bool isPhotoPath(String path) => RegExp(r'\.(jpe?g|png|webp|bmp|gif|heic|heif)$', caseSensitive: false).hasMatch(path);
