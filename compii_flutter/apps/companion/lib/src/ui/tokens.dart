import 'package:flutter/material.dart';

/// Compii's design tokens.
///
/// The language is Apple's: neutral surfaces stacked in layers and separated by
/// hairlines rather than heavy borders, diffuse shadows, a tight typographic
/// scale, and motion that leaves quickly and settles slowly. Colour is spent
/// only on meaning — indigo = Compii, gold = needs you, coral = danger,
/// green = done, cyan = listening.
@immutable
class CompiiColors extends ThemeExtension<CompiiColors> {
  const CompiiColors({
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.sunken,
    required this.hover,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentSoft,
    required this.accentGlow,
    required this.onAccent,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.listen,
    required this.userBubble,
    required this.shadow,
    required this.hairline,
    required this.glass,
    required this.scrim,
    required this.dark,
  });

  final Color canvas; // window background: the deepest layer
  final Color surface; // sidebar, side panels
  final Color raised; // cards, composer, dialogs
  final Color sunken; // inputs, code, wells
  final Color hover; // hover / selected rows
  final Color border; // hairlines: a low-alpha white or black, never a hue
  final Color borderStrong; // inputs, outlined buttons
  final Color text; // ink
  final Color muted;
  final Color faint;
  final Color accent; // Compii indigo
  final Color accentSoft;
  final Color accentGlow; // halos, focus rings
  final Color onAccent;
  final Color success;
  final Color successSoft;
  final Color warning; // gold: needs you
  final Color warningSoft;
  final Color danger; // coral
  final Color dangerSoft;
  final Color listen; // cyan
  final Color userBubble;
  final Color shadow;

  /// The lit top edge of a raised surface: white in both themes, stronger at
  /// night, where it is the only thing that separates two dark layers.
  final Color hairline;

  /// Translucent chrome, for the layers that blur what is behind them.
  final Color glass;

  /// The barrier behind a sheet or dialog.
  final Color scrim;
  final bool dark;

  static const light = CompiiColors(
    canvas: Color(0xFFF5F5F7),
    surface: Color(0xFFEFEFF2),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF4F4F7),
    hover: Color(0xFFE7E7EC),
    border: Color(0x14000000),
    borderStrong: Color(0x29000000),
    text: Color(0xFF16151C),
    muted: Color(0xFF5A5963),
    faint: Color(0xFF717078),
    accent: Color(0xFF4B3FE0),
    accentSoft: Color(0xFFECE9FF),
    accentGlow: Color(0x334B3FE0),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF0F7A45),
    successSoft: Color(0xFFE4F4EA),
    warning: Color(0xFF8A5A00),
    warningSoft: Color(0xFFFFF1D6),
    danger: Color(0xFFC0342B),
    dangerSoft: Color(0xFFFCE8E6),
    listen: Color(0xFF0B7E8A),
    userBubble: Color(0xFF16151C),
    shadow: Color(0x14000000),
    hairline: Color(0x99FFFFFF),
    glass: Color(0xE8FAFAFC),
    scrim: Color(0x59000000),
    dark: false,
  );

  static const night = CompiiColors(
    canvas: Color(0xFF0A0910),
    surface: Color(0xFF121119),
    raised: Color(0xFF1A1926),
    sunken: Color(0xFF0C0B12),
    hover: Color(0xFF232234),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x2EFFFFFF),
    text: Color(0xFFF6F4FB),
    muted: Color(0xFFABA6BE),
    faint: Color(0xFF8B86A0),
    accent: Color(0xFF9A8CFF),
    accentSoft: Color(0xFF251F4D),
    accentGlow: Color(0x409A8CFF),
    onAccent: Color(0xFF0A0910),
    success: Color(0xFF4BD48C),
    successSoft: Color(0xFF123028),
    warning: Color(0xFFFFC24D),
    warningSoft: Color(0xFF33270F),
    danger: Color(0xFFFF7A70),
    dangerSoft: Color(0xFF3A1A1E),
    listen: Color(0xFF62D9E8),
    userBubble: Color(0xFF2A2456),
    shadow: Color(0x99000000),
    hairline: Color(0x1FFFFFFF),
    glass: Color(0xD9141320),
    scrim: Color(0xA6000000),
    dark: true,
  );

  /// Text on the user's own message bubble.
  Color get onBubble => dark ? text : const Color(0xFFF5F5F7);

  @override
  CompiiColors copyWith() => this;

  @override
  CompiiColors lerp(covariant CompiiColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return CompiiColors(
      canvas: l(canvas, other.canvas),
      surface: l(surface, other.surface),
      raised: l(raised, other.raised),
      sunken: l(sunken, other.sunken),
      hover: l(hover, other.hover),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      accentGlow: l(accentGlow, other.accentGlow),
      onAccent: l(onAccent, other.onAccent),
      success: l(success, other.success),
      successSoft: l(successSoft, other.successSoft),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
      danger: l(danger, other.danger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      listen: l(listen, other.listen),
      userBubble: l(userBubble, other.userBubble),
      shadow: l(shadow, other.shadow),
      hairline: l(hairline, other.hairline),
      glass: l(glass, other.glass),
      scrim: l(scrim, other.scrim),
      dark: t < .5 ? dark : other.dark,
    );
  }
}

extension CompiiTheme on BuildContext {
  CompiiColors get c => Theme.of(this).extension<CompiiColors>()!;
  TextTheme get type => Theme.of(this).textTheme;

  /// Every duration in the app comes through here, so the one Windows setting
  /// "show animations" turns them all off at once.
  Duration motion(int milliseconds) =>
      MediaQuery.disableAnimationsOf(this) ? Duration.zero : Duration(milliseconds: milliseconds);

  /// Whether this person asked Windows to turn animations off: decorative
  /// movement stops, but state changes stay instant rather than broken.
  bool get still => MediaQuery.maybeOf(this)?.disableAnimations ?? false;
}

/// How motion feels. Curves are the part people notice without being able to
/// name: things leave fast and arrive slowly, and nothing ends on a hard stop.
class Motion {
  Motion._();

  /// Arriving: most of the distance in the first third, then a long settle.
  static const Curve out = Cubic(.16, 1, .3, 1);

  /// Leaving: accelerate away, so the exit never looks like it drags.
  static const Curve exit = Cubic(.4, 0, 1, 1);

  /// Everyday ease, for colour, border and size changes.
  static const Curve standard = Cubic(.25, .1, .25, 1);

  /// Symmetric movement, for something that grows from its own middle.
  static const Curve inOut = Cubic(.65, 0, .35, 1);

  /// A small overshoot, for things answering a finger or a click.
  static const Curve spring = Cubic(.34, 1.32, .64, 1);

  static const int tap = 90; // press feedback
  static const int quick = 150; // hover, colour, a row lighting up
  static const int base = 240; // panels, reveals, most widget transitions
  static const int page = 340; // one page becoming another
  static const int slow = 520; // sheets, big layout changes
  static const int breathe = 1600; // ambient loops: the skeleton shimmer, a pulse
}

/// The spacing scale. Four points per step, so anything lined up against
/// anything else shares a rhythm instead of a pile of one-off numbers.
class Space {
  Space._();

  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;

  /// Page margin: tight on a phone, generous on a desk — and tight on a desk
  /// too once the system is drawing big text, so the content keeps its width.
  static double gutter(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 700 || MediaQuery.textScalerOf(context).scale(1) >= 1.4) return l;
    return 40;
  }
}

/// Shared shapes and elevation.
class Shapes {
  static const r6 = BorderRadius.all(Radius.circular(6));
  static const r8 = BorderRadius.all(Radius.circular(8));
  static const r10 = BorderRadius.all(Radius.circular(10));
  static const r12 = BorderRadius.all(Radius.circular(12));
  static const r14 = BorderRadius.all(Radius.circular(14));
  static const r16 = BorderRadius.all(Radius.circular(16));
  static const r18 = BorderRadius.all(Radius.circular(18));
  static const r20 = BorderRadius.all(Radius.circular(20));
  static const r24 = BorderRadius.all(Radius.circular(24));
  static const r28 = BorderRadius.all(Radius.circular(28));
  static const pill = BorderRadius.all(Radius.circular(999));

  /// Radius for a control of a given height: Apple keeps the corner at roughly
  /// a third of the height, so small things look small and large ones look soft.
  static BorderRadius forHeight(double height) => BorderRadius.all(Radius.circular((height * .32).clamp(6.0, 22.0)));

  /// A card at rest: two diffuse shadows in light, a whisper at night, where a
  /// shadow would only muddy an already dark surface.
  static List<BoxShadow> card(CompiiColors c) => c.dark
      ? [BoxShadow(color: const Color(0x40000000), blurRadius: 18, offset: const Offset(0, 6))]
      : [
          BoxShadow(color: c.shadow.withValues(alpha: .5), blurRadius: 1.5, offset: const Offset(0, 1)),
          BoxShadow(color: c.shadow.withValues(alpha: .8), blurRadius: 18, offset: const Offset(0, 8)),
        ];

  /// A card under the pointer.
  static List<BoxShadow> lift(CompiiColors c) => c.dark
      ? [BoxShadow(color: const Color(0x59000000), blurRadius: 26, offset: const Offset(0, 10))]
      : [
          BoxShadow(color: c.shadow.withValues(alpha: .6), blurRadius: 2, offset: const Offset(0, 1)),
          BoxShadow(color: c.shadow.withValues(alpha: 1), blurRadius: 28, offset: const Offset(0, 14)),
        ];

  /// Floating things: composer, dialogs, toasts.
  static List<BoxShadow> float(CompiiColors c) => [
        BoxShadow(color: c.shadow.withValues(alpha: c.dark ? .8 : .6), blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(
            color: c.shadow.withValues(alpha: c.dark ? .9 : 1), blurRadius: 44, offset: const Offset(0, 18)),
      ];

  static BoxDecoration panel(CompiiColors c, {BorderRadius radius = r18, Color? color, Color? borderColor}) =>
      BoxDecoration(
        color: color ?? c.raised,
        borderRadius: radius,
        border: Border.all(color: borderColor ?? c.border),
        boxShadow: card(c),
      );
}

const kText = 'Segoe UI Variable Text';
const kDisplay = 'Segoe UI Variable Display';
const kFallback = ['Segoe UI Variable Text', 'Segoe UI', 'Roboto'];

ThemeData compiiTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? CompiiColors.night : CompiiColors.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: kText,
    fontFamilyFallback: kFallback,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.raised,
      onSurface: c.text,
      surfaceTint: Colors.transparent,
      error: c.danger,
      outline: c.borderStrong,
      outlineVariant: c.border,
    ),
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    dividerColor: c.border,
    // No ripples: Apple's feedback is a soft tint under the pointer and a hair
    // of movement under the finger, not a wave from the click point.
    splashFactory: NoSplash.splashFactory,
    hoverColor: c.hover.withValues(alpha: .7),
    highlightColor: c.hover.withValues(alpha: .9),
    focusColor: c.accentGlow,
    visualDensity: VisualDensity.standard,
    extensions: [c],
  );
  TextStyle d(TextStyle? s, double size, FontWeight w, {double ls = -.2, Color? color, double height = 1.2}) =>
      (s ?? const TextStyle()).copyWith(
        fontFamily: kDisplay,
        fontFamilyFallback: kFallback,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        color: color ?? c.text,
        height: height,
      );
  final t = base.textTheme;
  const label = TextStyle(
      fontFamily: kText, fontFamilyFallback: kFallback, fontWeight: FontWeight.w600, fontSize: 13.5, letterSpacing: 0);
  final buttonShape = RoundedRectangleBorder(borderRadius: Shapes.r10);

  return base.copyWith(
    textTheme: t.copyWith(
      displaySmall: d(t.displaySmall, 32, FontWeight.w700, ls: -1, height: 1.12),
      headlineMedium: d(t.headlineMedium, 26, FontWeight.w700, ls: -.7),
      headlineSmall: d(t.headlineSmall, 20, FontWeight.w600, ls: -.4),
      titleLarge: d(t.titleLarge, 17, FontWeight.w600, ls: -.25),
      titleMedium: d(t.titleMedium, 15, FontWeight.w600, ls: -.1),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: c.text, fontSize: 13.5, letterSpacing: -.05),
      bodyLarge: t.bodyLarge?.copyWith(color: c.text, fontSize: 15.5, height: 1.55, letterSpacing: -.1),
      bodyMedium: t.bodyMedium?.copyWith(color: c.text, fontSize: 14, height: 1.5, letterSpacing: -.05),
      bodySmall: t.bodySmall?.copyWith(color: c.muted, fontSize: 12.5, height: 1.45),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5, color: c.text),
      labelMedium: t.labelMedium?.copyWith(color: c.muted, fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: t.labelSmall?.copyWith(color: c.faint, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5),
    ),
    iconTheme: IconThemeData(color: c.muted, size: 20),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? c.hover
            : s.contains(WidgetState.hovered)
                ? Color.lerp(c.accent, c.text, .12)
                : c.accent),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.faint : c.onAccent),
        overlayColor: WidgetStateProperty.resolveWith(
            (s) => c.onAccent.withValues(alpha: s.contains(WidgetState.focused) ? .2 : .08)),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
            ? BorderSide(color: c.onAccent.withValues(alpha: .85), width: 2)
            : BorderSide.none),
        minimumSize: const WidgetStatePropertyAll(Size(44, 40)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
        shape: WidgetStatePropertyAll(buttonShape),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: const WidgetStatePropertyAll(label),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
            ? c.accentSoft
            : s.contains(WidgetState.hovered)
                ? c.hover.withValues(alpha: .7)
                : c.raised),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? c.faint
            : s.contains(WidgetState.focused)
                ? c.accent
                : c.text),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(
            color: s.contains(WidgetState.focused) ? c.accent : c.borderStrong,
            width: s.contains(WidgetState.focused) ? 1.6 : 1)),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: const WidgetStatePropertyAll(Size(44, 40)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: const WidgetStatePropertyAll(label),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused) ? c.accent : s.contains(WidgetState.hovered) ? c.text : c.muted),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
            ? c.accentSoft
            : s.contains(WidgetState.hovered)
                ? c.hover.withValues(alpha: .7)
                : Colors.transparent),
        side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? BorderSide(color: c.accent, width: 1.4) : BorderSide.none),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Shapes.r10)),
        textStyle: WidgetStatePropertyAll(label.copyWith(fontSize: 13)),
        iconSize: const WidgetStatePropertyAll(17),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused) ? c.accent : s.contains(WidgetState.hovered) ? c.text : c.muted),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
            ? c.accentSoft
            : s.contains(WidgetState.hovered)
                ? c.hover.withValues(alpha: .8)
                : Colors.transparent),
        overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? c.accentGlow : Colors.transparent),
        side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? BorderSide(color: c.accent, width: 1.4) : BorderSide.none),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Shapes.r10)),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.sunken,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: TextStyle(color: c.muted, fontSize: 13.5),
      floatingLabelStyle: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600),
      hintStyle: TextStyle(color: c.faint),
      helperStyle: TextStyle(color: c.faint, fontSize: 12),
      border: OutlineInputBorder(borderRadius: Shapes.r10, borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: Shapes.r10, borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(borderRadius: Shapes.r10, borderSide: BorderSide(color: c.accent, width: 1.6)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : c.faint),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.hover),
      trackOutlineColor:
          WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong),
      trackOutlineWidth: const WidgetStatePropertyAll(1.2),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      overlayColor: WidgetStatePropertyAll(c.accentGlow),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.raised : c.sunken),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.text : c.muted),
        side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(color: s.contains(WidgetState.focused) ? c.accent : c.border)),
        overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? c.accentGlow : Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Shapes.r10)),
        textStyle: WidgetStatePropertyAll(label.copyWith(fontSize: 13)),
        visualDensity: const VisualDensity(vertical: -1),
      ),
      selectedIcon: const SizedBox.shrink(),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.raised,
      selectedColor: c.accentSoft,
      side: BorderSide(color: c.border),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r10),
      labelStyle: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w500, fontFamily: kText),
      secondaryLabelStyle: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: kText),
      checkmarkColor: c.accent,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      iconTheme: IconThemeData(color: c.muted, size: 16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r24, side: BorderSide(color: c.border)),
      titleTextStyle: d(null, 20, FontWeight.w700, ls: -.4),
      contentTextStyle: TextStyle(color: c.muted, fontSize: 14, height: 1.5),
      elevation: 0,
      shadowColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r18, side: BorderSide(color: c.border)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      textColor: c.text,
      titleTextStyle: TextStyle(fontFamily: kText, color: c.text, fontSize: 14, fontWeight: FontWeight.w600),
      subtitleTextStyle: TextStyle(fontFamily: kText, color: c.muted, fontSize: 12.5),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r12),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(5),
      radius: const Radius.circular(5),
      thumbColor: WidgetStatePropertyAll(c.borderStrong.withValues(alpha: .9)),
      thumbVisibility: const WidgetStatePropertyAll(false),
      interactive: true,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.hover,
      circularTrackColor: Colors.transparent,
      strokeCap: StrokeCap.round,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r14, side: BorderSide(color: c.border)),
      textStyle: TextStyle(color: c.text, fontSize: 13.5, fontFamily: kText),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.dark ? c.hover : c.text, borderRadius: Shapes.r8),
      textStyle: TextStyle(color: c.dark ? c.text : c.canvas, fontSize: 12, fontFamily: kText),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.dark ? c.hover : c.text,
      contentTextStyle: TextStyle(color: c.dark ? c.text : c.canvas, fontFamily: kText, fontSize: 13.5),
      actionTextColor: c.dark ? c.accent : const Color(0xFFB9B2FF),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r14),
      width: 460,
      elevation: 8,
    ),
    timePickerTheme: TimePickerThemeData(backgroundColor: c.raised, shape: RoundedRectangleBorder(borderRadius: Shapes.r24)),
  );
}
