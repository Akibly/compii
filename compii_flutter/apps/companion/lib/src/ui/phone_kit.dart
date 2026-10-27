import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/core_client.dart';
import 'glyphs.dart';
import 'tokens.dart';

/// The phone's own pieces, in the Halo canvas's language: a near-black ground,
/// dark glass groups with a hairline edge, white ink, and colour only for state
/// (green done, amber needs you, blue working, red didn't finish).

// ---- words ------------------------------------------------------------------------------------

/// A conversation's title as a person would write it: what was asked, without
/// notes meant for the AI, file names in brackets or "Job from Compii:".
String chatTitle(String request) {
  var s = request.split(RegExp(r'\n\n\((Spoken|The user)')).first;
  s = s.replaceFirst(RegExp(r'^Job from [^:]{1,30}:\s*'), '');
  s = s.replaceAll(RegExp(r'\s*\((?:[^()]*\.(?:jpe?g|png|webp|pdf|docx?|xlsx?|csv))[^()]*\)'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // A photo asked about from the phone reads as what was asked of it.
  final photo = RegExp(r'^(What is this\?|Read|Translate|I snapped)', caseSensitive: false).firstMatch(s);
  if (photo != null && s.contains('photo')) {
    if (s.startsWith('What is this')) return 'What is this? (photo)';
    if (s.startsWith('Read')) return 'Read a photo';
    if (s.startsWith('Translate')) return 'Translate a photo';
    return 'A snapped document';
  }
  if (s.length <= 64) return s;
  final stop = s.indexOf(RegExp(r'[.?!](\s|$)'));
  if (stop > 12 && stop < 64) return s.substring(0, stop + 1);
  final cut = s.lastIndexOf(' ', 60);
  return '${s.substring(0, cut < 24 ? 60 : cut)}…';
}

/// "now", "4 min", "2 h", "Yesterday", "Mon", "12 Oct": short enough for a row's corner.
String shortWhen(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final today = DateTime(n.year, n.month, n.day);
  if (!t.isBefore(today)) return '${d.inHours} h';
  if (!t.isBefore(today.subtract(const Duration(days: 1)))) return 'Yesterday';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (d.inDays < 7) return days[t.weekday - 1];
  return '${t.day} ${months[t.month - 1]}';
}

/// When a conversation last moved: its newest event's time.
DateTime? lastMoved(TaskView t) {
  for (final e in t.events.reversed) {
    final at = e['at'];
    if (at is num && at > 0) return DateTime.fromMillisecondsSinceEpoch((at * 1000).round());
  }
  return null;
}

/// Where a conversation stands, in a word and a colour.
enum ChatState {
  needsYou('Needs you'),
  asking('Asking you'),
  working('Working'),
  failed('Didn’t finish'),
  done('Done');

  const ChatState(this.label);
  final String label;

  static ChatState of(TaskView t) => t.pendingApproval != null
      ? needsYou
      : t.pendingQuestion != null
          ? asking
          : t.active
              ? working
              : t.status == 'failed'
                  ? failed
                  : done;

  Color color(BuildContext context) {
    final c = context.c;
    return switch (this) {
      needsYou || asking => const Color(0xFFFFC58A),
      working => const Color(0xFF9CC4FF),
      failed => c.danger,
      done => const Color(0xFF7EE2AE),
    };
  }
}

// ---- pieces -----------------------------------------------------------------------------------

/// A small caption over a group, like the canvas's "Today" and "Ready for you".
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
        child: Row(
          children: [
            Expanded(child: Text(text, style: context.type.labelMedium?.copyWith(color: context.c.faint))),
            ?trailing,
          ],
        ),
      );
}

/// Rows on one piece of dark glass, divided by hairlines.
class HaloGroup extends StatelessWidget {
  const HaloGroup({super.key, required this.children, this.edge});
  final List<Widget> children;

  /// A coloured edge for a group that needs attention (amber for "needs you").
  final Color? edge;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: edge?.withValues(alpha: .45) ?? c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: 16, color: c.border),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One row in a group: a glyph, a title, an optional line under it, and what's on the right.
class HaloRow extends StatelessWidget {
  const HaloRow({
    super.key,
    required this.title,
    this.glyph,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.chevron = true,
  });
  final String title;
  final GlyphData? glyph;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ink = danger ? c.danger : c.text;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              if (glyph != null) ...[
                Glyph(glyph!, size: 20, color: danger ? c.danger : c.muted),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: context.type.bodyLarge?.copyWith(color: ink, fontWeight: FontWeight.w500)),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: context.type.bodySmall?.copyWith(color: c.faint)),
                    ],
                  ],
                ),
              ),
              ?trailing,
              if (trailing == null && chevron && onTap != null) Glyph(G.chevronRight, size: 16, color: c.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded chip of dark glass: the Talk tab's suggestions.
class HaloChip extends StatelessWidget {
  const HaloChip({super.key, required this.label, required this.onTap, this.glyph});
  final String label;
  final GlyphData? glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xCC0E0E12),
        shape: const StadiumBorder(side: BorderSide(color: Color(0x1FFFFFFF))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (glyph != null) ...[
                  Glyph(glyph!, size: 16, color: const Color(0xFFD8D8DF)),
                  const SizedBox(width: 8),
                ],
                Text(label, style: const TextStyle(color: Color(0xFFF5F5F7), fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
}

/// A button that acts only after it is held for a moment, for things that can't be
/// taken back from a phone in a pocket: deleting, paying. Lets go early and nothing happens.
class HoldButton extends StatefulWidget {
  const HoldButton({super.key, required this.label, required this.onHeld, this.color, this.hold = const Duration(milliseconds: 900)});
  /// The verb it confirms: "delete", "pay".
  final String label;
  final VoidCallback onHeld;
  final Color? color;
  final Duration hold;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(vsync: this, duration: widget.hold)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onHeld();
        _fill.value = 0;
      }
    });

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  void _start() {
    HapticFeedback.selectionClick();
    _fill.forward(from: 0);
  }

  void _cancel() {
    if (_fill.isAnimating) _fill.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.c.danger;
    return Semantics(
      button: true,
      label: 'Hold to ${widget.label}. Press and hold to confirm.',
      onTap: widget.onHeld, // screen readers confirm with a double tap
      child: GestureDetector(
        onTapDown: (_) => _start(),
        onTapUp: (_) => _cancel(),
        onTapCancel: _cancel,
        child: AnimatedBuilder(
          animation: _fill,
          builder: (context, _) => Container(
            height: 48,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: color.withValues(alpha: .18)),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                FractionallySizedBox(widthFactor: _fill.value, child: ColoredBox(color: color, child: const SizedBox.expand())),
                Center(
                  child: Text(
                    _fill.value > 0 ? 'Keep holding…' : 'Hold to ${widget.label}',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The phone's status and navigation bars: light icons on the night ground.
const phoneSystemUi = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Color(0xFF050507),
  systemNavigationBarIconBrightness: Brightness.light,
);
