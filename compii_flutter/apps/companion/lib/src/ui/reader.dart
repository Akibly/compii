import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glyphs.dart';
import 'reply_text.dart';
import 'tokens.dart';

/// Open a long answer in a calm, full-width reader instead of a cut-off line.
/// The text is the exact same markdown as the thread, so nothing is lost
/// between what Compii said and what you read.
Future<void> showAnswerReader(
  BuildContext context, {
  required String text,
  String title = 'Compii',
  String? subtitle,
}) =>
    showDialog<void>(
      context: context,
      useSafeArea: true,
      barrierColor: Colors.black.withValues(alpha: .46),
      builder: (_) => AnswerReader(text: text, title: title, subtitle: subtitle),
    );

/// A comfortable reading surface: 66-ish characters per line, generous
/// leading, selectable text, and the full answer always in one place.
class AnswerReader extends StatelessWidget {
  const AnswerReader({super.key, required this.text, this.title = 'Compii', this.subtitle});
  final String text;
  final String title;
  final String? subtitle;

  int get _words => text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

  String get _detail {
    final words = _words;
    final minutes = math.max(1, (words / 200).ceil());
    final chars = text.trim().length;
    return '$words words · $chars characters · about $minutes min';
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Copied the full answer'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(780.0, screen.width - 48);
    final height = math.min(820.0, screen.height - 64);
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r20, side: BorderSide(color: c.border)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Glyph(G.doc, size: 20, color: c.accent, duo: true),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.type.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(subtitle ?? _detail, style: context.type.labelMedium?.copyWith(color: c.faint)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy all',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _copy(context),
                    icon: const Glyph(G.copy, size: 17),
                  ),
                  IconButton(
                    tooltip: 'Close (Esc)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Glyph(G.close, size: 18),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: Scrollbar(
                radius: const Radius.circular(8),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 32),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 660),
                      child: ReplyText(
                        text,
                        style: context.type.bodyLarge?.copyWith(fontSize: 16.5, height: 1.62),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
