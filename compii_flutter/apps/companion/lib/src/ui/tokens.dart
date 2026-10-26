import 'package:flutter/material.dart';

/// Compii's design tokens (v5, docs/compii/design-v5-workspace.md; night follows the Halo
/// canvas the user approved: a near-black ground, white ink, one blue halo accent).
///
/// A workspace, not a toy: neutral greys with no hue in them, surfaces told
/// apart by a step of lightness and a hairline instead of a shadow, dense
/// type, small radii. Colour is spent only on meaning: blue = Compii acting,
/// amber = needs you, red = failed or dangerous, green = done, cyan =
/// listening. Primary buttons are ink on canvas, so the accent stays rare.
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
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFF7F7F8),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF2F2F3),
    hover: Color(0xFFEEEEF0),
    border: Color(0x14000000),
    borderStrong: Color(0x24000000),
    text: Color(0xFF18181B),
    muted: Color(0xFF5B5B63),
    faint: Color(0xFF76767E),
    accent: Color(0xFF2563EB),
    accentSoft: Color(0xFFEAF1FE),
    accentGlow: Color(0x332563EB),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF15803D),
    successSoft: Color(0xFFE8F5EC),
    warning: Color(0xFF9A4A06),
    warningSoft: Color(0xFFFDF1E3),
    danger: Color(0xFFDC2626),
    dangerSoft: Color(0xFFFDECEC),
    listen: Color(0xFF0E7490),
    userBubble: Color(0xFFF2F2F3),
    shadow: Color(0x10000000),
    hairline: Color(0x00FFFFFF),
    glass: Color(0xF2FFFFFF),
    scrim: Color(0x4D000000),
    dark: false,
  );

  static const night = CompiiColors(
    canvas: Color(0xFF050507),
    surface: Color(0xFF09090C),
    raised: Color(0xFF0E0E12),
    sunken: Color(0xFF0B0B0F),
    hover: Color(0xFF15151B),
    border: Color(0x0FFFFFFF),
    borderStrong: Color(0x24FFFFFF),
    text: Color(0xFFF5F5F7),
    muted: Color(0xFFA9A9B3),
    faint: Color(0xFF8E8E99),
    accent: Color(0xFF3D8BFF),
    accentSoft: Color(0xFF0F1B33),
    accentGlow: Color(0x403D8BFF),
    onAccent: Color(0xFF050507),
    success: Color(0xFF3BE08F),
    successSoft: Color(0xFF0C2419),
    warning: Color(0xFFFF9B3D),
    warningSoft: Color(0xFF2A1A0B),
    danger: Color(0xFFFF5A4E),
    dangerSoft: Color(0xFF2C1110),
    listen: Color(0xFF2FD3FF),
    userBubble: Color(0xFF111116),
    shadow: Color(0x80000000),
    hairline: Color(0x0FFFFFFF),
    glass: Color(0xF00E0E12),
    scrim: Color(0x99000000),
    dark: true,
  );

  /// Text on the user's own message bubble.
  Color get onBubble => text;

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
  static BorderRadius forHeight(double height) => BorderRadius.all(Radius.circular((height * .22).clamp(5.0, 12.0)));

  /// A card at rest: two diffuse shadows in light, a whisper at night, where a
  /// shadow would only muddy an already dark surface.
  static List<BoxShadow> card(CompiiColors c) => const [];

  /// A card under the pointer.
  static List<BoxShadow> lift(CompiiColors c) =>
      [BoxShadow(color: c.shadow.withValues(alpha: c.dark ? .5 : .6), blurRadius: 12, offset: const Offset(0, 4))];

  /// Floating things: composer, dialogs, toasts.
  static List<BoxShadow> float(CompiiColors c) => [
        BoxShadow(color: c.shadow.withValues(alpha: c.dark ? .9 : 1), blurRadius: 24, offset: const Offset(0, 8)),
      ];

  static BoxDecoration panel(CompiiColors c, {BorderRadius radius = r10, Color? color, Color? borderColor}) =>
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
      fontFamily: kText, fontFamilyFallback: kFallback, fontWeight: FontWeight.w500, fontSize: 13, letterSpacing: 0);
  final buttonShape = RoundedRectangleBorder(borderRadius: Shapes.r6);

  return base.copyWith(
    textTheme: t.copyWith(
      displaySmall: d(t.displaySmall, 26, FontWeight.w600, ls: -.6, height: 1.15),
      headlineMedium: d(t.headlineMedium, 22, FontWeight.w600, ls: -.4),
      headlineSmall: d(t.headlineSmall, 18, FontWeight.w600, ls: -.3),
      titleLarge: d(t.titleLarge, 16, FontWeight.w600, ls: -.2),
      titleMedium: d(t.titleMedium, 14, FontWeight.w600, ls: -.1),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w500, color: c.text, fontSize: 13, letterSpacing: 0),
      bodyLarge: t.bodyLarge?.copyWith(color: c.text, fontSize: 14.5, height: 1.6, letterSpacing: 0),
      bodyMedium: t.bodyMedium?.copyWith(color: c.text, fontSize: 13.5, height: 1.5, letterSpacing: 0),
      bodySmall: t.bodySmall?.copyWith(color: c.muted, fontSize: 12, height: 1.45),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: 13, color: c.text),
      labelMedium: t.labelMedium?.copyWith(color: c.muted, fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: t.labelSmall?.copyWith(color: c.faint, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: .3),
    ),
    iconTheme: IconThemeData(color: c.muted, size: 20),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? c.hover
            : s.contains(WidgetState.hovered)
                ? Color.lerp(c.text, c.canvas, .14)
                : c.text),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.faint : c.canvas),
        overlayColor: WidgetStateProperty.resolveWith(
            (s) => c.canvas.withValues(alpha: s.contains(WidgetState.focused) ? .16 : .06)),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
            ? BorderSide(color: c.accent, width: 2)
            : BorderSide.none),
        minimumSize: const WidgetStatePropertyAll(Size(40, 34)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
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
        minimumSize: const WidgetStatePropertyAll(Size(40, 34)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
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
        minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Shapes.r6)),
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
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Shapes.r6)),
        iconSize: const WidgetStatePropertyAll(17),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.sunken,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: TextStyle(color: c.muted, fontSize: 13.5),
      floatingLabelStyle: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600),
      hintStyle: TextStyle(color: c.faint),
      helperStyle: TextStyle(color: c.faint, fontSize: 12),
      border: OutlineInputBorder(borderRadius: Shapes.r6, borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(borderRadius: Shapes.r6, borderSide: BorderSide(color: c.borderStrong)),
      focusedBorder: OutlineInputBorder(borderRadius: Shapes.r6, borderSide: BorderSide(color: c.accent, width: 1.4)),
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
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: Shapes.r6)),
        textStyle: WidgetStatePropertyAll(label.copyWith(fontSize: 13)),
        visualDensity: const VisualDensity(vertical: -1),
      ),
      selectedIcon: const SizedBox.shrink(),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.raised,
      selectedColor: c.accentSoft,
      side: BorderSide(color: c.border),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r6),
      labelStyle: TextStyle(color: c.text, fontSize: 12.5, fontWeight: FontWeight.w500, fontFamily: kText),
      secondaryLabelStyle: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: kText),
      checkmarkColor: c.accent,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      iconTheme: IconThemeData(color: c.muted, size: 16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r12, side: BorderSide(color: c.borderStrong)),
      titleTextStyle: d(null, 17, FontWeight.w600, ls: -.2),
      contentTextStyle: TextStyle(color: c.muted, fontSize: 14, height: 1.5),
      elevation: 0,
      shadowColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r10, side: BorderSide(color: c.border)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      textColor: c.text,
      titleTextStyle: TextStyle(fontFamily: kText, color: c.text, fontSize: 13.5, fontWeight: FontWeight.w500),
      subtitleTextStyle: TextStyle(fontFamily: kText, color: c.muted, fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r6),
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
      shape: RoundedRectangleBorder(borderRadius: Shapes.r8, side: BorderSide(color: c.borderStrong)),
      textStyle: TextStyle(color: c.text, fontSize: 13, fontFamily: kText),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.dark ? c.raised : c.text, borderRadius: Shapes.r6,
          border: Border.all(color: c.dark ? c.borderStrong : Colors.transparent)),
      textStyle: TextStyle(color: c.dark ? c.text : c.canvas, fontSize: 12, fontFamily: kText),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.dark ? c.hover : c.text,
      contentTextStyle: TextStyle(color: c.dark ? c.text : c.canvas, fontFamily: kText, fontSize: 13.5),
      actionTextColor: c.dark ? c.accent : const Color(0xFF93B8FF),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r8),
      width: 460,
      elevation: 8,
    ),
    timePickerTheme: TimePickerThemeData(backgroundColor: c.raised, shape: RoundedRectangleBorder(borderRadius: Shapes.r12)),
  );
}
