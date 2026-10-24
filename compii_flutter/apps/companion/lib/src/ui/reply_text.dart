import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glyphs.dart';
import 'tokens.dart';

/// The same words with the markers taken off, for the one line of type on the
/// stage's face, where rich rendering would not fit.
String plainMarkdown(String s) => s.replaceAllMapped(
  ReplyText._inline,
  (m) => m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? m.group(0)!,
);

/// What a link in Compii's own prose does when tapped. Every surface reaches the
/// outside world through Core, the same way the sources under an answer do.
typedef OpenLink = void Function(String url);

/// Compii writes markdown, and showing it raw leaves the user reading asterisks.
/// This renders the slice of markdown Compii actually uses — bold, italics, inline
/// code, links, bullets, numbers, headings, quotes and code blocks — as real type.
///
/// With an [onOpen], a link opens like the sources below the answer do; without one
/// the word is still set apart, just not clickable.
class ReplyText extends StatefulWidget {
  const ReplyText(this.text, {super.key, this.style, this.onOpen});

  final String text;
  final TextStyle? style;
  final OpenLink? onOpen;

  static final _heading = RegExp(r'^(#{1,4})\s+(.*)$');
  static final _bullet = RegExp(r'^[-*•]\s+(.*)$');
  static final _numbered = RegExp(r'^(\d{1,2})[.)]\s+(.*)$');
  static final _quote = RegExp(r'^>\s?(.*)$');
  static final _rule = RegExp(r'^-{3,}$|^\*{3,}$');
  static final _inline = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)');

  @override
  State<ReplyText> createState() => _ReplyTextState();
}

class _ReplyTextState extends State<ReplyText> {
  // One gesture per address, kept for the life of this widget: an answer streams in
  // word by word and a link must not be torn down while the pointer is on it.
  final _links = <String, TapGestureRecognizer>{};

  TapGestureRecognizer _recognizer(String url) => _links.putIfAbsent(
    url,
        () => TapGestureRecognizer()..onTap = () => widget.onOpen?.call(url),
  );

  @override
  void dispose() {
    for (final r in _links.values) {
      r.dispose();
    }
    _links.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final base = widget.style ?? context.type.bodyLarge ?? const TextStyle();
    final blocks = <Widget>[];
    final paragraph = <String>[];
    final lines = widget.text.split('\n');

    void flush() {
      if (paragraph.isEmpty) return;
      blocks.add(SelectableText.rich(TextSpan(children: _spans(paragraph.join('\n'), base, c)), style: base));
      paragraph.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty) {
        flush();
      } else if (t.startsWith('```')) {
        flush();
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          code.add(lines[i]);
          i++;
        }
        blocks.add(_codeBlock(code, c));
      } else if (ReplyText._rule.hasMatch(t)) {
        flush();
        blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1, color: c.border)));
      } else if (ReplyText._heading.firstMatch(t) case final m?) {
        flush();
        final level = m.group(1)!.length;
        final head = base.copyWith(fontWeight: FontWeight.w700, fontSize: (base.fontSize ?? 15) + [5, 3.5, 2, 1][level - 1]);
        blocks.add(Padding(
          padding: EdgeInsets.only(top: level == 1 ? 10 : 6),
          child: SelectableText.rich(TextSpan(children: _spans(m.group(2)!, head, c)), style: head),
        ));
      } else if (ReplyText._bullet.firstMatch(t) case final m?) {
        flush();
        blocks.add(_row('•', m.group(1)!, base, c));
      } else if (ReplyText._numbered.firstMatch(t) case final m?) {
        flush();
        blocks.add(_row('${m.group(1)}.', m.group(2)!, base, c, weight: FontWeight.w600));
      } else if (ReplyText._quote.firstMatch(t) case final m?) {
        flush();
        blocks.add(Container(
          margin: const EdgeInsets.only(left: 2, top: 2),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.borderStrong, width: 2))),
          child: SelectableText.rich(
            TextSpan(children: _spans(m.group(1)!, base, c)),
            style: base.copyWith(color: c.muted, fontStyle: FontStyle.italic),
          ),
        ));
      } else {
        paragraph.add(t);
      }
    }
    flush();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < blocks.length; i++) ...[if (i > 0) const SizedBox(height: 5), blocks[i]],
    ]);
  }

  Widget _row(String mark, String body, TextStyle base, CompiiColors c, {FontWeight? weight}) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 16, child: Text(mark, style: base.copyWith(color: c.muted, fontWeight: weight))),
        const SizedBox(width: 4),
        Expanded(child: SelectableText.rich(TextSpan(children: _spans(body, base, c)), style: base)),
      ],
    ),
  );

  /// A block of code the user can take away whole, not retype from the screen.
  Widget _codeBlock(List<String> code, CompiiColors c) {
    final text = code.join('\n');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: Shapes.r10,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            text,
            style: const TextStyle(fontFamily: 'Cascadia Mono', fontFamilyFallback: ['Consolas'], fontSize: 12.5, height: 1.45),
          ),
          if (text.trim().isNotEmpty)
            Align(alignment: Alignment.centerRight, child: _CopyCode(text: text)),
        ],
      ),
    );
  }

  List<InlineSpan> _spans(String s, TextStyle base, CompiiColors c) {
    final out = <InlineSpan>[];
    var start = 0;
    for (final m in ReplyText._inline.allMatches(s)) {
      if (m.start > start) out.add(TextSpan(text: s.substring(start, m.start)));
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        out.add(TextSpan(text: m.group(2), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else if (m.group(3) != null) {
        out.add(TextSpan(
          text: m.group(3),
          style: TextStyle(
            fontFamily: 'Cascadia Mono',
            fontFamilyFallback: const ['Consolas'],
            fontSize: (base.fontSize ?? 15) - 1.5,
            color: c.muted,
          ),
        ));
      } else {
        final url = m.group(5)!;
        final open = widget.onOpen;
        out.add(TextSpan(
          text: m.group(4),
          style: TextStyle(
            color: c.accent,
            decoration: open == null ? null : TextDecoration.underline,
            decorationColor: c.accent.withValues(alpha: .55),
          ),
          recognizer: open == null ? null : _recognizer(url),
          mouseCursor: open == null ? null : SystemMouseCursors.click,
        ));
      }
      start = m.end;
    }
    if (start < s.length) out.add(TextSpan(text: s.substring(start)));
    return out;
  }
}

/// The little control under a block of code: it takes the words exactly as Compii
/// wrote them, then says it has, for two seconds.
class _CopyCode extends StatefulWidget {
  const _CopyCode({required this.text});
  final String text;

  @override
  State<_CopyCode> createState() => _CopyCodeState();
}

class _CopyCodeState extends State<_CopyCode> {
  Timer? _revert;
  bool _done = false;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _done = true);
    _revert?.cancel();
    _revert = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _done = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TextButton.icon(
      key: const Key('copy-code'),
      onPressed: _copy,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
        foregroundColor: _done ? c.accent : c.muted,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Glyph(_done ? G.check : G.copy, size: 13),
      label: Text(_done ? 'Copied' : 'Copy code', style: context.type.labelSmall),
    );
  }
}
