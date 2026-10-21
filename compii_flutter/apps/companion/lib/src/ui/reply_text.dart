import 'package:flutter/material.dart';

import 'tokens.dart';

/// The same words with the markers taken off, for the one line of type on the
/// stage's face, where rich rendering would not fit.
String plainMarkdown(String s) => s.replaceAllMapped(
  ReplyText._inline,
  (m) => m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? m.group(0)!,
);

/// Compii writes markdown, and showing it raw leaves the user reading asterisks.
/// This renders the slice of markdown Compii actually uses — bold, italics, inline
/// code, links, bullets, numbers, headings, quotes and code blocks — as real type.
class ReplyText extends StatelessWidget {
  const ReplyText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static final _heading = RegExp(r'^(#{1,4})\s+(.*)$');
  static final _bullet = RegExp(r'^[-*•]\s+(.*)$');
  static final _numbered = RegExp(r'^(\d{1,2})[.)]\s+(.*)$');
  static final _quote = RegExp(r'^>\s?(.*)$');
  static final _rule = RegExp(r'^-{3,}$|^\*{3,}$');
  static final _inline = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)');

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final base = style ?? context.type.bodyLarge ?? const TextStyle();
    final blocks = <Widget>[];
    final paragraph = <String>[];
    final lines = text.split('\n');

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
      } else if (_rule.hasMatch(t)) {
        flush();
        blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1, color: c.border)));
      } else if (_heading.firstMatch(t) case final m?) {
        flush();
        final level = m.group(1)!.length;
        final head = base.copyWith(fontWeight: FontWeight.w700, fontSize: (base.fontSize ?? 15) + [5, 3.5, 2, 1][level - 1]);
        blocks.add(Padding(
          padding: EdgeInsets.only(top: level == 1 ? 10 : 6),
          child: SelectableText.rich(TextSpan(children: _spans(m.group(2)!, head, c)), style: head),
        ));
      } else if (_bullet.firstMatch(t) case final m?) {
        flush();
        blocks.add(_row('•', m.group(1)!, base, c));
      } else if (_numbered.firstMatch(t) case final m?) {
        flush();
        blocks.add(_row('${m.group(1)}.', m.group(2)!, base, c, weight: FontWeight.w600));
      } else if (_quote.firstMatch(t) case final m?) {
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

  Widget _codeBlock(List<String> code, CompiiColors c) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 2),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: c.border),
    ),
    child: SelectableText(
      code.join('\n'),
      style: const TextStyle(fontFamily: 'Cascadia Mono', fontFamilyFallback: ['Consolas'], fontSize: 12.5, height: 1.45),
    ),
  );

  List<InlineSpan> _spans(String s, TextStyle base, CompiiColors c) {
    final out = <InlineSpan>[];
    var start = 0;
    for (final m in _inline.allMatches(s)) {
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
        out.add(TextSpan(text: m.group(4), style: TextStyle(color: c.accent)));
      }
      start = m.end;
    }
    if (start < s.length) out.add(TextSpan(text: s.substring(start)));
    return out;
  }
}
