import 'package:flutter/material.dart';

import '../art/halo.dart';
import 'tokens.dart';

/// Any colour, not a short list: a row of quick picks and, under "Any colour",
/// hue, richness and brightness sliders plus a hex field. Used for Compii's coat
/// and for every teammate's, so the two never drift apart.
class ColorChooser extends StatefulWidget {
  const ColorChooser({super.key, required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<ColorChooser> createState() => _ColorChooserState();
}

class _ColorChooserState extends State<ColorChooser> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);
  late bool _open = !haloSwatches.any((s) => s.toARGB32() == widget.color.toARGB32());
  late final _hex = TextEditingController(text: colorHex(widget.color));

  @override
  void didUpdateWidget(covariant ColorChooser old) {
    super.didUpdateWidget(old);
    if (old.color != widget.color && _hsv.toColor().toARGB32() != widget.color.toARGB32()) {
      _hsv = HSVColor.fromColor(widget.color);
      _hex.text = colorHex(widget.color);
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor v) {
    setState(() => _hsv = v);
    final c = v.toColor();
    _hex.text = colorHex(c);
    widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final now = widget.color.toARGB32();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final s in haloSwatches)
              _Dot(
                color: s,
                on: s.toARGB32() == now,
                label: 'Colour ${colorHex(s)}',
                onTap: () => _set(HSVColor.fromColor(s)),
              ),
            Semantics(
              button: true,
              toggled: _open,
              label: 'Any colour',
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                borderRadius: Shapes.pill,
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    borderRadius: Shapes.pill,
                    border: Border.all(color: _open ? c.accent : c.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(colors: [
                            Color(0xFFFF4D4D),
                            Color(0xFFFFD84D),
                            Color(0xFF4DFF88),
                            Color(0xFF4DD2FF),
                            Color(0xFF6B4DFF),
                            Color(0xFFFF4DD8),
                            Color(0xFFFF4D4D),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('Any colour', style: context.type.labelMedium),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_open) ...[
          const SizedBox(height: 12),
          _Track(
            label: 'Hue',
            value: _hsv.hue / 360,
            colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()],
            onChanged: (v) => _set(_hsv.withHue(v * 360)),
          ),
          _Track(
            label: 'Richness',
            value: _hsv.saturation,
            colors: [_hsv.withSaturation(0).toColor(), _hsv.withSaturation(1).toColor()],
            onChanged: (v) => _set(_hsv.withSaturation(v)),
          ),
          _Track(
            label: 'Brightness',
            value: _hsv.value,
            colors: [Colors.black, _hsv.withValue(1).toColor()],
            onChanged: (v) => _set(_hsv.withValue(v)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _hex,
              decoration: const InputDecoration(labelText: 'Hex', isDense: true, hintText: '#3F86FF'),
              onSubmitted: (raw) {
                final v = parseHex(raw);
                if (v != null) _set(HSVColor.fromColor(v));
              },
              onChanged: (raw) {
                final v = parseHex(raw);
                if (v != null && v.toARGB32() != widget.color.toARGB32()) {
                  setState(() => _hsv = HSVColor.fromColor(v));
                  widget.onChanged(v);
                }
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.on, required this.label, required this.onTap});
  final Color color;
  final bool on;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: context.motion(160),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-.35, -.4),
              colors: [Color.lerp(color, Colors.white, .45)!, color, Color.lerp(color, Colors.black, .45)!],
              stops: const [0, .55, 1],
            ),
            border: Border.all(color: on ? c.text : c.border, width: on ? 2.4 : 1),
          ),
        ),
      ),
    );
  }
}

/// A slider drawn over the gradient it chooses from, so the keyboard and the
/// screen reader get a real slider.
class _Track extends StatelessWidget {
  const _Track({required this.label, required this.value, required this.colors, required this.onChanged});
  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        SizedBox(width: 78, child: Text(label, style: context.type.labelMedium?.copyWith(color: c.muted))),
        Expanded(
          child: SizedBox(
            height: 34,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: Shapes.pill,
                      gradient: LinearGradient(colors: colors),
                      border: Border.all(color: c.border),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 12,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    overlayColor: c.accent.withValues(alpha: .16),
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 3),
                  ),
                  child: Slider(
                    value: value.clamp(0.0, 1.0),
                    label: label,
                    semanticFormatterCallback: (v) => '$label ${(v * 100).round()} percent',
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
