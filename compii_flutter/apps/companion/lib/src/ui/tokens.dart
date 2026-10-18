import 'package:flutter/material.dart';

/// Compii's design tokens, taken from the Orbling itself: its night-indigo
/// ink, cream mittens, indigo body, gold sparkle and cyan "listening" glow.
///
/// Light is warm paper with indigo ink; dark is a deep night sky. Colour is
/// spent on meaning: indigo = Compii / primary, gold = needs you,
/// coral = danger, green = done, cyan = listening.
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
    required this.dark,
  });

  final Color canvas; // window background
  final Color surface; // sidebar, side panels
  final Color raised; // cards, composer, dialogs
  final Color sunken; // inputs, code, wells
  final Color hover; // hover / selected rows
  final Color border; // hairlines
  final Color borderStrong; // inputs, outlined buttons
  final Color text; // ink
  final Color muted;
  final Color faint;
  final Color accent; // Orbling indigo
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
  final bool dark;

  static const light = CompiiColors(
    canvas: Color(0xFFF7F4EE),
    surface: Color(0xFFF1EDE5),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF4F1EA),
    hover: Color(0xFFE9E4DA),
    border: Color(0xFFE6E0D5),
    borderStrong: Color(0xFFD5CEC1),
    text: Color(0xFF15122E),
    muted: Color(0xFF5E5A70),
    faint: Color(0xFF928D9E),
    accent: Color(0xFF4B3FE0),
    accentSoft: Color(0xFFECE9FF),
    accentGlow: Color(0x334B3FE0),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1C8A55),
    successSoft: Color(0xFFE2F4E9),
    warning: Color(0xFFB87300),
    warningSoft: Color(0xFFFFF0D2),
    danger: Color(0xFFD13F35),
    dangerSoft: Color(0xFFFCE7E4),
    listen: Color(0xFF0E9FAA),
    userBubble: Color(0xFF15122E),
    shadow: Color(0x1A2A2140),
    dark: false,
  );

  static const night = CompiiColors(
    canvas: Color(0xFF0D0B1A),
    surface: Color(0xFF121027),
    raised: Color(0xFF1A1833),
    sunken: Color(0xFF100E22),
    hover: Color(0xFF221F40),
    border: Color(0xFF26234A),
    borderStrong: Color(0xFF353160),
    text: Color(0xFFF1EEFB),
    muted: Color(0xFFADA8C6),
    faint: Color(0xFF79739A),
    accent: Color(0xFF8E84FF),
    accentSoft: Color(0xFF262153),
    accentGlow: Color(0x408E84FF),
    onAccent: Color(0xFF0D0B1A),
    success: Color(0xFF5BD69A),
    successSoft: Color(0xFF13302A),
    warning: Color(0xFFFFC94D),
    warningSoft: Color(0xFF332812),
    danger: Color(0xFFFF7D72),
    dangerSoft: Color(0xFF3A1820),
    listen: Color(0xFF5CE1E6),
    userBubble: Color(0xFF2B2660),
    shadow: Color(0x66000000),
    dark: true,
  );


  /// Text on the user's own message bubble.
  Color get onBubble => dark ? text : const Color(0xFFF7F4EE);

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
      dark: t < .5 ? dark : other.dark,
    );
  }
}

extension CompiiTheme on BuildContext {
  CompiiColors get c => Theme.of(this).extension<CompiiColors>()!;
  TextTheme get type => Theme.of(this).textTheme;
}

/// Shared shapes and elevation.
class Shapes {
  static const r6 = BorderRadius.all(Radius.circular(6));
  static const r10 = BorderRadius.all(Radius.circular(10));
  static const r12 = BorderRadius.all(Radius.circular(12));
  static const r16 = BorderRadius.all(Radius.circular(16));
  static const r20 = BorderRadius.all(Radius.circular(20));

  /// Soft, layered card shadow (light) / nothing but a hairline glow (night).
  static List<BoxShadow> card(CompiiColors c) => c.dark
      ? const []
      : [
          BoxShadow(color: c.shadow, blurRadius: 1, offset: const Offset(0, 1)),
          BoxShadow(color: c.shadow.withValues(alpha: .045), blurRadius: 14, offset: const Offset(0, 4)),
        ];

  /// Floating things: composer, dialogs, toasts.
  static List<BoxShadow> float(CompiiColors c) => [
        BoxShadow(color: c.shadow, blurRadius: 2, offset: const Offset(0, 1)),
        BoxShadow(color: c.shadow.withValues(alpha: c.dark ? .45 : .08), blurRadius: 28, offset: const Offset(0, 10)),
      ];

  static BoxDecoration panel(CompiiColors c, {BorderRadius radius = r16, Color? color}) => BoxDecoration(
        color: color ?? c.raised,
        borderRadius: radius,
        border: Border.all(color: c.border),
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
    splashFactory: InkSparkle.constantTurbulenceSeedSplashFactory,
    hoverColor: c.hover.withValues(alpha: .6),
    highlightColor: Colors.transparent,
    focusColor: c.accentGlow,
    visualDensity: VisualDensity.standard,
    extensions: [c],
  );
  TextStyle d(TextStyle? s, double size, FontWeight w, {double ls = -.2, Color? color}) =>
      (s ?? const TextStyle()).copyWith(
        fontFamily: kDisplay,
        fontFamilyFallback: kFallback,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        color: color ?? c.text,
        height: 1.2,
      );
  final t = base.textTheme;
  const label = TextStyle(fontFamily: kText, fontFamilyFallback: kFallback, fontWeight: FontWeight.w600, fontSize: 13.5, letterSpacing: 0);
  final buttonShape = RoundedRectangleBorder(borderRadius: Shapes.r10);

  return base.copyWith(
    textTheme: t.copyWith(
      displaySmall: d(t.displaySmall, 34, FontWeight.w700, ls: -.9),
      headlineMedium: d(t.headlineMedium, 28, FontWeight.w700, ls: -.7),
      headlineSmall: d(t.headlineSmall, 22, FontWeight.w600, ls: -.4),
      titleLarge: d(t.titleLarge, 17, FontWeight.w600, ls: -.25),
      titleMedium: d(t.titleMedium, 15, FontWeight.w600, ls: -.1),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: c.text, fontSize: 13.5),
      bodyLarge: t.bodyLarge?.copyWith(color: c.text, fontSize: 15, height: 1.55),
      bodyMedium: t.bodyMedium?.copyWith(color: c.text, fontSize: 14, height: 1.5),
      bodySmall: t.bodySmall?.copyWith(color: c.muted, fontSize: 12.5, height: 1.45),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5, color: c.text),
      labelMedium: t.labelMedium?.copyWith(color: c.muted, fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: t.labelSmall?.copyWith(color: c.faint, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .6),
    ),
    iconTheme: IconThemeData(color: c.muted, size: 20),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? c.border : s.contains(WidgetState.hovered) ? Color.lerp(c.accent, c.text, .12) : c.accent),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.faint : c.onAccent),
        overlayColor: WidgetStatePropertyAll(c.onAccent.withValues(alpha: .08)),
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
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? c.hover.withValues(alpha: .7) : c.raised),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.faint : c.text),
        side: WidgetStatePropertyAll(BorderSide(color: c.borderStrong)),
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
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? c.text : c.muted),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? c.hover.withValues(alpha: .7) : Colors.transparent),
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
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? c.text : c.muted),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? c.hover.withValues(alpha: .8) : Colors.transparent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
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
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.sunken),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong),
      trackOutlineWidth: const WidgetStatePropertyAll(1.2),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      overlayColor: WidgetStatePropertyAll(c.accentGlow),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.raised : c.sunken),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.text : c.muted),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
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
      shape: RoundedRectangleBorder(borderRadius: Shapes.r20, side: BorderSide(color: c.border)),
      titleTextStyle: d(null, 20, FontWeight.w700, ls: -.4),
      contentTextStyle: TextStyle(color: c.muted, fontSize: 14, height: 1.5),
      elevation: 24,
      shadowColor: c.shadow,
    ),
    cardTheme: CardThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r16, side: BorderSide(color: c.border)),
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
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(6),
      thumbColor: WidgetStatePropertyAll(c.borderStrong.withValues(alpha: .8)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.accentSoft,
      circularTrackColor: Colors.transparent,
      strokeCap: StrokeCap.round,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: Shapes.r12, side: BorderSide(color: c.border)),
      textStyle: TextStyle(color: c.text, fontSize: 13.5, fontFamily: kText),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.dark ? c.hover : c.text, borderRadius: Shapes.r6),
      textStyle: TextStyle(color: c.dark ? c.text : c.canvas, fontSize: 12, fontFamily: kText),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.dark ? c.hover : c.text,
      contentTextStyle: TextStyle(color: c.dark ? c.text : c.canvas, fontFamily: kText, fontSize: 13.5),
      actionTextColor: c.dark ? c.accent : const Color(0xFFB9B2FF),
      shape: RoundedRectangleBorder(borderRadius: Shapes.r12),
      width: 460,
      elevation: 8,
    ),
    timePickerTheme: TimePickerThemeData(backgroundColor: c.raised, shape: RoundedRectangleBorder(borderRadius: Shapes.r20)),
  );
}
