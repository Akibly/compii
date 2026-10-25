import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../art/halo.dart';
import '../console/character.dart' show Mood, moodLabel, pointer;
import 'color_chooser.dart';
import 'glyphs.dart';
import 'tokens.dart';

/// The shapes saved by earlier builds (the glass objects, then the furry
/// creatures), mapped onto the glass forms that took their place.
const _legacyShapes = <String, HaloForm>{
  'orb': HaloForm.orb,
  'gem': HaloForm.gem,
  'planet': HaloForm.tile,
  'gyro': HaloForm.pill,
  'capsule': HaloForm.tower,
  'comet': HaloForm.gem,
  'puff': HaloForm.orb,
  'tuft': HaloForm.tile,
  'mop': HaloForm.pill,
  'horn': HaloForm.gem,
  'wisp': HaloForm.gem,
  'bean': HaloForm.tower,
};

/// What is saved on a bot: `a3.<form>.<seed>`. Earlier `a1`/`a2` tokens still
/// parse. A token that is missing or unusable falls back to a look drawn from
/// the name, so a teammate looks the same every time even before anyone has
/// chosen one.
class AgentLook {
  const AgentLook(this.shape, this.seed);

  final HaloForm shape;
  final int seed;

  String encode() => 'a3.${shape.name}.$seed';

  static AgentLook parse(String raw, {String name = ''}) {
    final bits = raw.trim().split('.');
    if (bits.length == 3 && const {'a1', 'a2', 'a3'}.contains(bits.first)) {
      final shape = bits.first == 'a3' ? HaloForm.values.asNameMap()[bits[1]] : _legacyShapes[bits[1]];
      if (shape != null) {
        final seed = int.tryParse(bits[2])?.abs() ?? 0;
        return AgentLook(shape, (seed - 1) % 9973 + 1);
      }
    }
    return name.isEmpty ? const AgentLook(HaloForm.orb, 1) : forName(name);
  }

  /// A stable design for a name, used where no saved bot exists yet.
  static AgentLook forName(String name) {
    var h = 0x811c9dc5;
    for (final c in name.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    final shape = HaloForm.values[h.abs() % HaloForm.values.length];
    return AgentLook(shape, h.abs() % 9973 + 1);
  }
}

/// A teammate: a piece of black glass with eyes of light and a halo in its own
/// colour, wearing what it is doing. Lists keep them still; homes let them
/// breathe, blink and look at you.
class AgentFace extends StatefulWidget {
  const AgentFace({
    super.key,
    required this.color,
    required this.shape,
    this.seed = 1,
    this.size = 28,
    this.animate = false,
    this.ring = false,
    this.backgroundDisc = true,
    this.mood = Mood.idle,
    this.semanticLabel,
  });

  final Color color;
  final HaloForm shape;
  final int seed;
  final double size;
  final bool animate;
  final bool ring;

  /// What the teammate is doing, worn as an expression.
  final Mood mood;

  /// Lists, chips and the editor keep the soft disc; the picker shows the
  /// creature on its own.
  final bool backgroundDisc;
  final String? semanticLabel;

  @override
  State<AgentFace> createState() => _AgentFaceState();
}

class _AgentFaceState extends State<AgentFace> with TickerProviderStateMixin {
  late final AnimationController clock = AnimationController(vsync: this, duration: const Duration(seconds: 8));
  late final AnimationController drift = AnimationController(vsync: this, duration: const Duration(seconds: 31));
  Offset _look = Offset.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AgentFace old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) _sync();
  }

  void _sync() {
    final still = !widget.animate || MediaQuery.of(context).disableAnimations;
    if (still) {
      clock.stop();
      drift.stop();
    } else {
      if (!clock.isAnimating) clock.repeat();
      if (!drift.isAnimating) drift.repeat();
    }
  }

  @override
  void dispose() {
    clock.dispose();
    drift.dispose();
    super.dispose();
  }

  Offset _target() {
    final p = pointer.value;
    final box = context.findRenderObject();
    if (p == null || box is! RenderBox || !box.hasSize || !box.attached) return Offset.zero;
    final d = p - box.localToGlobal(box.size.center(Offset.zero));
    final reach = math.max(box.size.shortestSide * 3, 120.0);
    return Offset((d.dx / reach).clamp(-1.0, 1.0), (d.dy / reach).clamp(-1.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final face = AnimatedBuilder(
      animation: Listenable.merge([clock, drift]),
      builder: (context, _) {
        final still = !widget.animate || MediaQuery.of(context).disableAnimations;
        if (!still) _look = Offset.lerp(_look, _target(), .15)!;
        return CustomPaint(
          painter: HaloPainter(
            form: widget.shape,
            color: color,
            seed: widget.seed,
            scale: widget.backgroundDisc ? .78 : .9,
            pose: HaloPose(
              mood: widget.mood,
              t: still ? .18 : clock.value,
              s: still ? .3 : drift.value,
              still: still,
              look: still ? Offset.zero : _look,
            ),
          ),
        );
      },
    );
    return Semantics(
      label: widget.semanticLabel ?? '${widget.shape.desc}, ${moodLabel(widget.mood)}',
      image: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: widget.backgroundDisc
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-.35, -.45),
                      radius: .95,
                      colors: [color.withValues(alpha: .18), color.withValues(alpha: .07)],
                    ),
                    border: Border.all(
                      color: color.withValues(alpha: widget.ring ? .85 : .28),
                      width: widget.ring ? 1.5 : 1,
                    ),
                  ),
                  child: face,
                )
              : face,
        ),
      ),
    );
  }
}

/// Lets the user choose a teammate's creature and its colour. Every creature is
/// drawn live in the colour being chosen; none of them carries a name.
Future<({AgentLook look, Color color})?> showAgentPicker(
  BuildContext context, {
  required Color color,
  required AgentLook look,
}) =>
    showDialog<({AgentLook look, Color color})>(
      context: context,
      builder: (_) => _AgentPicker(color: color, look: look),
    );

class _AgentPicker extends StatefulWidget {
  const _AgentPicker({required this.color, required this.look});
  final Color color;
  final AgentLook look;

  @override
  State<_AgentPicker> createState() => _AgentPickerState();
}

class _AgentPickerState extends State<_AgentPicker> {
  late HaloForm _shape = widget.look.shape;
  late int _seed = widget.look.seed;
  late Color _color = widget.color;

  void _surprise() => setState(() {
    final r = math.Random();
    _seed = r.nextInt(9973) + 1;
    _shape = HaloForm.values[r.nextInt(HaloForm.values.length)];
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      title: const Text('Choose a character'),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 640),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(40),
                        gradient: RadialGradient(colors: [_color.withValues(alpha: .18), Colors.transparent]),
                      ),
                      child: AgentFace(
                        color: _color,
                        shape: _shape,
                        seed: _seed,
                        size: 132,
                        animate: true,
                        backgroundDisc: false,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Drawn live: its eyes follow your pointer and blink, its halo shows how hard it is '
                            'working, and its eyes show how it is doing.',
                            style: context.type.bodySmall?.copyWith(color: c.muted),
                          ),
                          const SizedBox(height: 10),
                          FilledButton.tonalIcon(
                            onPressed: _surprise,
                            icon: const Glyph(G.wand, size: 16),
                            label: const Text('Surprise me'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final shape in HaloForm.values)
                      _ShapeButton(
                        shape: shape,
                        color: _color,
                        seed: _seed,
                        selected: _shape == shape,
                        onTap: () => setState(() => _shape = shape),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('COLOUR', style: context.type.labelSmall),
                const SizedBox(height: 8),
                ColorChooser(color: _color, onChanged: (v) => setState(() => _color = v)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (look: AgentLook(_shape, _seed), color: _color)),
          child: const Text('Use this character'),
        ),
      ],
    );
  }
}

class _ShapeButton extends StatelessWidget {
  const _ShapeButton({
    required this.shape,
    required this.color,
    required this.seed,
    required this.selected,
    required this.onTap,
  });
  final HaloForm shape;
  final Color color;
  final int seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: selected,
      label: shape.desc,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 88,
          height: 88,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: selected ? c.accentSoft : Colors.transparent,
            border: Border.all(color: selected ? c.accent : c.border, width: selected ? 1.6 : 1),
          ),
          child: ExcludeSemantics(
            child: AgentFace(color: color, shape: shape, seed: seed, size: 76, backgroundDisc: false),
          ),
        ),
      ),
    );
  }
}
