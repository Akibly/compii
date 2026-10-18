import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'glyphs.dart';
import 'tokens.dart';

/// Compii's own window chrome and the small building blocks every page uses.

/// Whether we draw our own title bar (the desktop app; not tests or phones).
bool get customChrome => !_testing && Platform.isWindows;
bool get _testing => Platform.environment.containsKey('FLUTTER_TEST');

/// The strip across the top of the content area: drag to move, double-click
/// to maximise, and Compii-drawn minimise / maximise / close buttons.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, this.title, this.leading, this.actions = const []});
  final String? title;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bar = SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 18),
          ?leading,
          if (title != null)
            Flexible(
              child: Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: context.type.titleMedium?.copyWith(color: c.text)),
            ),
          const Spacer(),
          ...actions,
          if (customChrome) ...[const SizedBox(width: 8), const _CaptionButtons()] else const SizedBox(width: 12),
        ],
      ),
    );
    if (!customChrome) return bar;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async => await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize(),
      child: bar,
    );
  }
}

/// A drag handle for the sidebar's top edge (so the whole top of the window moves it).
class DragStrip extends StatelessWidget {
  const DragStrip({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => !customChrome
      ? child
      : GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowManager.startDragging(),
          onDoubleTap: () async => await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize(),
          child: child,
        );
}

class _CaptionButtons extends StatelessWidget {
  const _CaptionButtons();
  @override
  Widget build(BuildContext context) => Row(
    children: [
      _Caption(kind: 0, onTap: windowManager.minimize),
      _Caption(kind: 1, onTap: () async => await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize()),
      _Caption(kind: 2, onTap: windowManager.close),
    ],
  );
}

class _Caption extends StatefulWidget {
  const _Caption({required this.kind, required this.onTap});
  final int kind; // 0 minimise, 1 maximise, 2 close
  final VoidCallback onTap;
  @override
  State<_Caption> createState() => _CaptionState();
}

class _CaptionState extends State<_Caption> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final close = widget.kind == 2;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 44,
          color: _hover ? (close ? const Color(0xFFE5484D) : c.hover) : Colors.transparent,
          alignment: Alignment.center,
          child: CustomPaint(
            size: const Size(10, 10),
            painter: _CaptionPainter(widget.kind, _hover && close ? Colors.white : c.muted),
          ),
        ),
      ),
    );
  }
}

class _CaptionPainter extends CustomPainter {
  _CaptionPainter(this.kind, this.color);
  final int kind;
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    switch (kind) {
      case 0:
        canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), p);
      case 1:
        canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(2)), p);
      default:
        canvas.drawLine(Offset.zero, Offset(s.width, s.height), p);
        canvas.drawLine(Offset(s.width, 0), Offset(0, s.height), p);
    }
  }

  @override
  bool shouldRepaint(_CaptionPainter o) => o.color != color;
}

// ---- building blocks ----------------------------------------------------------

/// The glyph that heads each page.
GlyphData pageGlyph(String title) => switch (title) {
  'Memory' => G.memory,
  'Settings' => G.sliders,
  'Routines' => G.routine,
  'Updates' => G.bell,
  'Safety' => G.shield,
  'Skills' => G.skill,
  _ => G.memory,
};

/// A page: eyebrow glyph, big title, one-line description, then content.
class PageScaffold extends StatelessWidget {
  const PageScaffold({super.key, required this.glyph, required this.title, required this.subtitle, required this.children, this.trailing, this.maxWidth = 760});
  final GlyphData glyph;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? trailing;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.fromLTRB(36, 20, 36, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GlyphTile(glyph: glyph, size: 44),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: context.type.headlineMedium),
                          const SizedBox(height: 4),
                          Text(subtitle, style: context.type.bodyMedium?.copyWith(color: c.muted)),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[const SizedBox(width: 16), trailing!],
                  ],
                ),
                const SizedBox(height: 28),
                ...children,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A rounded tile with a soft accent wash and a duo-tone glyph.
class GlyphTile extends StatelessWidget {
  const GlyphTile({super.key, required this.glyph, this.size = 36, this.color, this.background});
  final GlyphData glyph;
  final double size;
  final Color? color;
  final Color? background;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = color ?? c.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? fg.withValues(alpha: c.dark ? .16 : .10),
        borderRadius: BorderRadius.circular(size * .3),
        border: Border.all(color: fg.withValues(alpha: .18)),
      ),
      alignment: Alignment.center,
      child: Glyph(glyph, size: size * .5, color: fg, duo: true),
    );
  }
}

/// A section heading inside a page.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing, this.top = 8});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final double top;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.type.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: context.type.bodySmall),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// The standard card.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color, this.borderColor});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.raised,
        borderRadius: Shapes.r16,
        border: Border.all(color: borderColor ?? c.border),
        boxShadow: Shapes.card(c),
      ),
      child: child,
    );
  }
}

/// Rows inside a [Panel], separated by hairlines.
class PanelRows extends StatelessWidget {
  const PanelRows({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Panel(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        for (final (i, w) in children.indexed) ...[
          if (i > 0) Divider(height: 1, indent: 18, endIndent: 18, color: context.c.border),
          w,
        ],
      ],
    ),
  );
}

/// A settings-style row: glyph tile, title, description, control.
class OptionRow extends StatelessWidget {
  const OptionRow({super.key, required this.glyph, required this.title, this.subtitle, this.trailing, this.color, this.onTap});
  final GlyphData glyph;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: Shapes.r16,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          GlyphTile(glyph: glyph, size: 34, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.type.titleSmall),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: context.type.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 14), trailing!],
        ],
      ),
    ),
  );
}

/// A small status pill: dot or glyph + text.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.color, this.glyph, this.soft = true, this.pulse = false});
  final String text;
  final Color color;
  final GlyphData? glyph;
  final bool soft;
  final bool pulse;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
    decoration: BoxDecoration(
      color: soft ? color.withValues(alpha: context.c.dark ? .16 : .11) : color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (glyph != null)
          Glyph(glyph!, size: 13, color: soft ? color : Colors.white, weight: 2)
        else
          Container(width: 6, height: 6, decoration: BoxDecoration(color: soft ? color : Colors.white, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(color: soft ? color : Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700, fontFamily: kText, letterSpacing: .1)),
      ],
    ),
  );
}

/// A keyboard shortcut chip: Ctrl · N.
class Kbd extends StatelessWidget {
  const Kbd(this.keys, {super.key});
  final String keys;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, k) in keys.split('+').map((k) => k.trim()).indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: c.raised,
              borderRadius: Shapes.r6,
              border: Border.all(color: c.border),
              boxShadow: [BoxShadow(color: c.borderStrong, offset: const Offset(0, 1.5))],
            ),
            child: Text(k, style: TextStyle(fontSize: 11, color: c.muted, fontWeight: FontWeight.w600, fontFamily: kText)),
          ),
        ],
      ],
    );
  }
}

/// Friendly empty state with a glyph.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.glyph, required this.title, required this.body, this.action});
  final GlyphData glyph;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
    child: Column(
      children: [
        GlyphTile(glyph: glyph, size: 52),
        const SizedBox(height: 14),
        Text(title, style: context.type.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(body, style: context.type.bodyMedium?.copyWith(color: context.c.muted), textAlign: TextAlign.center),
        ),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}

/// A soft radial glow behind the character.
class Aura extends StatelessWidget {
  const Aura({super.key, required this.child, this.size = 260, this.color});
  final Widget child;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final glow = color ?? c.accent;
    return SizedBox(
      width: size,
      height: size * .78,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                glow.withValues(alpha: c.dark ? .28 : .16),
                glow.withValues(alpha: c.dark ? .08 : .05),
                glow.withValues(alpha: 0),
              ], stops: const [0, .45, 1]),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
