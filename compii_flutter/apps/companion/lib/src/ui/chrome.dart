import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  const TitleBar({super.key, this.title, this.leading, this.actions = const [], this.center});
  final String? title;
  final Widget? leading;
  final List<Widget> actions;

  /// What the page puts in the bar itself, e.g. a chat's title, status and controls; the
  /// bar then draws a hairline under it, since it is the page's header too.
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bar = Container(
      height: 46,
      decoration: center == null ? null : BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
      child: Row(
        children: [
          const SizedBox(width: Space.l),
          ?leading,
          if (center != null)
            Expanded(child: center!)
          else ...[
            if (title != null)
              Flexible(
                child: Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: context.type.titleMedium?.copyWith(color: c.text)),
              ),
            const Spacer(),
          ],
          ...actions,
          if (customChrome) ...[const SizedBox(width: Space.s), const _CaptionButtons()] else const SizedBox(width: Space.m),
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
      child: Semantics(
        button: true,
        label: const ['Minimize', 'Maximize or restore', 'Close'][widget.kind],
        child: InkWell(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: context.motion(Motion.quick),
          curve: Motion.standard,
          width: 46,
          height: 46,
          color: _hover ? (close ? const Color(0xFFE5484D) : c.hover) : Colors.transparent,
          alignment: Alignment.center,
          child: CustomPaint(
            size: const Size(10, 10),
            painter: _CaptionPainter(widget.kind, _hover && close ? Colors.white : c.muted),
          ),
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
  'Clips' => G.clipboard,
  'Settings' => G.sliders,
  'Routines' => G.routine,
  'Updates' => G.bell,
  'Safety' => G.shield,
  'Skills' => G.skill,
  'Library' => G.box,
  'Knowledge' => G.search,
  'Research' => G.globe,
  'Team' => G.team,
  _ => G.memory,
};

/// A page: eyebrow glyph, big title, one-line description, then content.
///
/// The content arrives rather than appearing — each block a beat behind the one
/// above it, which is what makes a page change feel composed instead of cut.
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
    final gutter = Space.gutter(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, Space.xl, gutter, Space.huge),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Reveal(
              children: [
                AdaptiveRow(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GlyphTile(glyph: glyph, size: 46),
                    const SizedBox(width: Space.l),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: context.type.headlineMedium),
                          const SizedBox(height: Space.xs),
                          Text(subtitle, style: context.type.bodyMedium?.copyWith(color: c.muted, height: 1.45)),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[const SizedBox(width: Space.l), trailing!],
                  ],
                ),
                const SizedBox(height: Space.xl + 4),
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
    final wash = background ?? fg.withValues(alpha: c.dark ? .18 : .10);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: background == null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [wash, wash.withValues(alpha: (c.dark ? .18 : .10) * .55)],
              )
            : null,
        color: background,
        borderRadius: BorderRadius.circular(size * .3),
        border: Border.all(color: fg.withValues(alpha: c.dark ? .28 : .16)),
      ),
      alignment: Alignment.center,
      child: Glyph(glyph, size: size * .5, color: fg, duo: true),
    );
  }
}

/// A small capitalised label above a group: "TEAM", "RECENT", "PLAN".
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color, this.trailing});
  final String text;
  final Color? color;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.type.labelSmall?.copyWith(color: color ?? context.c.faint)),
      ),
      ?trailing,
    ],
  );
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
    padding: EdgeInsets.only(top: top, bottom: Space.m),
    child: AdaptiveRow(
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
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color, this.borderColor, this.radius = Shapes.r18});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final BorderRadius radius;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: Shapes.panel(context.c, radius: radius, color: color, borderColor: borderColor),
    child: child,
  );
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
    borderRadius: Shapes.r18,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: AdaptiveRow(
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

/// The keyboard half of a control that draws itself. One tab stop, Enter or
/// Space activates it, and the ring is the theme's own accent — so nothing a
/// mouse can reach is out of reach for a keyboard or a screen reader. The child
/// keeps its own look and its own pointer handling.
///
/// [minTarget] floors the height only: a wide-enough control sets its own width,
/// and forcing a narrow one wider would draw the ring around empty space.
class Keyable extends StatelessWidget {
  const Keyable({
    super.key,
    required this.child,
    required this.onTap,
    this.label,
    this.selected,
    this.radius = Shapes.pill,
    this.minTarget = 44,
  });
  final Widget child;
  final VoidCallback? onTap;
  final String? label;

  /// Only for controls that really toggle — a nav row, a day chip. Left null on
  /// a plain button, so a screen reader isn't told "not selected" about
  /// something that was never a choice.
  final bool? selected;
  final BorderRadius radius;
  final double minTarget;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final live = onTap != null;
    return Focus(
      canRequestFocus: live,
      skipTraversal: !live,
      onKeyEvent: (node, event) {
        if (!live) return KeyEventResult.ignored;
        if (event is! KeyDownEvent && event is! KeyUpEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key != LogicalKeyboardKey.enter &&
            key != LogicalKeyboardKey.numpadEnter &&
            key != LogicalKeyboardKey.space) {
          return KeyEventResult.ignored;
        }
        if (event is KeyUpEvent) onTap!();
        return KeyEventResult.handled;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: selected,
            enabled: live,
            label: label,
            onTap: live ? () => onTap!() : null,
            child: Stack(
              children: [
                ConstrainedBox(constraints: BoxConstraints(minHeight: minTarget), child: child),
                if (focused)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: c.accent, width: 2),
                          borderRadius: radius,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A blurred translucent layer — the material Apple puts behind anything that
/// floats over content, so what is underneath stays legible as *behind*.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.sigma = 26, this.color, this.radius = Shapes.r24, this.border = true});
  final Widget child;
  final double sigma;
  final Color? color;
  final BorderRadius radius;
  final bool border;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? c.glass,
            borderRadius: radius,
            border: border ? Border.all(color: c.hairline) : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Content that arrives instead of appearing: a short fade and rise, each child
/// a beat behind the one above. Runs once when the page mounts and stays out of
/// the way of people who asked Windows for no animation.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.children, this.rise = 10, this.gap = 45, this.duration = Motion.base});
  final List<Widget> children;
  final double rise;
  final int gap;
  final int duration;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  AnimationController? _a;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_a != null || context.still || widget.children.length < 2) return;
    final span = widget.duration + widget.gap * (widget.children.length - 1);
    _a = AnimationController(vsync: this, duration: Duration(milliseconds: span))..forward();
  }

  @override
  void dispose() {
    _a?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    if (a == null) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.children);
    final span = a.duration!.inMilliseconds;
    return AnimatedBuilder(
      animation: a,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, w) in widget.children.indexed)
            Builder(builder: (context) {
              final start = i * widget.gap / span;
              final t = Motion.out.transform(((a.value - start) * span / widget.duration).clamp(0.0, 1.0));
              return Opacity(
                opacity: t,
                child: Transform.translate(offset: Offset(0, widget.rise * (1 - t)), child: w),
              );
            }),
        ],
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final ink = soft ? color : Colors.white;
    final mark = glyph != null
        ? Glyph(glyph!, size: 13, color: ink, weight: 2)
        : Container(width: 6, height: 6, decoration: BoxDecoration(color: ink, shape: BoxShape.circle));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: soft ? color.withValues(alpha: context.c.dark ? .16 : .11) : color,
        borderRadius: Shapes.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pulse ? _Breathing(color: ink, child: mark) : mark,
          const SizedBox(width: 5),
          Text(text, style: TextStyle(color: ink, fontSize: 11.5, fontWeight: FontWeight.w600, fontFamily: kText, letterSpacing: .15)),
        ],
      ),
    );
  }
}

/// A slow breathe on a "still working" mark: proof of life without a spinner.
class _Breathing extends StatefulWidget {
  const _Breathing({required this.child, required this.color});
  final Widget child;
  final Color color;
  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: Motion.breathe));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Nothing listens to a frozen breathe, so don't pay a vsync callback for it.
    if (context.still) {
      if (_a.isAnimating) _a.stop();
    } else if (!_a.isAnimating) {
      _a.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (context.still) return widget.child;
    return AnimatedBuilder(
      animation: _a,
      builder: (context, child) {
        final t = Motion.inOut.transform(_a.value);
        return Opacity(opacity: .55 + .45 * t, child: Transform.scale(scale: .9 + .18 * t, child: child));
      },
      child: widget.child,
    );
  }
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.sunken,
              borderRadius: Shapes.r6,
              border: Border.all(color: c.border),
              boxShadow: [BoxShadow(color: c.border.withValues(alpha: .9), offset: const Offset(0, 1))],
            ),
            child: Text(k, style: TextStyle(fontSize: 11, color: c.muted, fontWeight: FontWeight.w600, fontFamily: kText)),
          ),
        ],
      ],
    );
  }
}

/// Quiet placeholders while a page's first data is on its way. A light sweeps
/// across them so the wait reads as work in progress rather than a dead screen;
/// it stops for people who asked Windows for reduced motion.
class SkeletonCards extends StatefulWidget {
  const SkeletonCards({super.key, this.rows = 3});
  final int rows;

  @override
  State<SkeletonCards> createState() => _SkeletonCardsState();
}

class _SkeletonCardsState extends State<SkeletonCards> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep =
      AnimationController(vsync: this, duration: const Duration(milliseconds: Motion.breathe));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The sweep is not drawn when the platform asks for quiet, so don't run it.
    if (context.still) {
      if (_sweep.isAnimating) _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = context.still;
    return AnimatedBuilder(
      animation: _sweep,
      builder: (context, _) => Column(
        children: [
          for (var i = 0; i < widget.rows; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == widget.rows - 1 ? 0 : Space.m),
              child: Opacity(
                opacity: still ? .6 : 1,
                child: Panel(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      _Bone(width: 34, height: 34, radius: 11, sweep: still ? null : _sweep.value, phase: i * .06),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Bone(width: 180 + (i.isEven ? 60 : 0), height: 11, sweep: still ? null : _sweep.value, phase: i * .06 + .04),
                            const SizedBox(height: 9),
                            _Bone(width: double.infinity, height: 9, sweep: still ? null : _sweep.value, phase: i * .06 + .08),
                            const SizedBox(height: 6),
                            FractionallySizedBox(
                              widthFactor: .62,
                              child: _Bone(width: double.infinity, height: 9, sweep: still ? null : _sweep.value, phase: i * .06 + .12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bone extends StatelessWidget {
  const _Bone({required this.width, required this.height, this.radius = 5, this.sweep, this.phase = 0});

  final double width;
  final double height;
  final double radius;

  /// 0..1 position of the light crossing the card; null paints a flat bone.
  final double? sweep;
  final double phase;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final base = c.hover;
    final s = sweep;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: s == null ? base : null,
        gradient: s == null
            ? null
            : LinearGradient(
                colors: [base, base, Color.lerp(base, c.raised, c.dark ? .85 : .8)!, base, base],
                stops: [
                  0,
                  ((s + phase) % 1 * 1.6 - .5).clamp(0.0, 1.0),
                  ((s + phase) % 1 * 1.6 - .3).clamp(0.0, 1.0),
                  ((s + phase) % 1 * 1.6 - .1).clamp(0.0, 1.0),
                  1,
                ],
              ),
      ),
    );
  }
}

/// Friendly empty state with a glyph.
class EmptyState extends StatelessWidget {  const EmptyState({super.key, required this.glyph, required this.title, required this.body, this.action});
  final GlyphData glyph;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.xl + 4),
    child: Column(
      children: [
        GlyphTile(glyph: glyph, size: 56),
        const SizedBox(height: Space.l),
        Text(title, style: context.type.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(body, style: context.type.bodyMedium?.copyWith(color: context.c.muted), textAlign: TextAlign.center),
        ),
        if (action != null) ...[const SizedBox(height: Space.l + 2), action!],
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
                glow.withValues(alpha: c.dark ? .26 : .14),
                glow.withValues(alpha: c.dark ? .09 : .05),
                glow.withValues(alpha: c.dark ? .03 : .02),
                glow.withValues(alpha: 0),
              ], stops: const [0, .4, .68, 1]),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Keeps actions reachable when a row cannot comfortably fit scaled text.
class AdaptiveRow extends StatelessWidget {
  const AdaptiveRow({super.key, required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.mainAxisSize = MainAxisSize.max, this.breakpoint = 540});
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisAlignment mainAxisAlignment;
  final MainAxisSize mainAxisSize;
  final double breakpoint;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    if (box.maxWidth >= breakpoint * MediaQuery.textScalerOf(context).scale(1)) {
      return Row(crossAxisAlignment: crossAxisAlignment,
        mainAxisAlignment: mainAxisAlignment, mainAxisSize: mainAxisSize, children: children);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, children: [
        for (final child in children)
          if (child is! Spacer)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: child is Flexible ? child.child : child),
      ]);
  });
}

/// A control whose own label can outgrow the row it sits in at enlarged text —
/// a dropdown of voice names, say. The width is capped and the words scroll,
/// instead of pushing the rest of the row off the window.
class ScrollCapped extends StatelessWidget {
  const ScrollCapped({super.key, this.maxWidth = 220, required this.child});
  final double maxWidth;
  final Widget child;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: child),
  );
}

/// A failed refresh never replaces successful content with an empty state.
class LoadFailure extends StatelessWidget {
  const LoadFailure({super.key, required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.m),
    child: Panel(radius: Shapes.r14, child: AdaptiveRow(children: [
      Expanded(child: Text('Could not refresh this page. Try again.',
        style: context.type.bodyMedium?.copyWith(color: context.c.danger))),
      OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
    ])),
  );
}
