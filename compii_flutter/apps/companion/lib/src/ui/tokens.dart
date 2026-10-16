import 'package:flutter/material.dart';

/// Compii's design tokens: calm neutrals, one indigo accent (the Orbling's
/// body colour), and risk colours that are only used for meaning.
@immutable
class CompiiColors extends ThemeExtension<CompiiColors> {
  const CompiiColors({
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.sunken,
    required this.border,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.userBubble,
  });

  final Color canvas; // window background
  final Color surface; // panels, sidebar
  final Color raised; // cards, composer
  final Color sunken; // inputs, code
  final Color border;
  final Color text;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color accentSoft;
  final Color onAccent;
  final Color success;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;
  final Color userBubble;

  static const light = CompiiColors(
    canvas: Color(0xFFF6F5F8),
    surface: Color(0xFFEFEDF3),
    raised: Color(0xFFFFFFFF),
    sunken: Color(0xFFF1EFF5),
    border: Color(0xFFE2DFE8),
    text: Color(0xFF17151F),
    muted: Color(0xFF5F5A6D),
    faint: Color(0xFF8F8A9C),
    accent: Color(0xFF4B3FE0),
    accentSoft: Color(0xFFEAE8FD),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F8A4C),
    warning: Color(0xFFB26A00),
    warningSoft: Color(0xFFFFF3DC),
    danger: Color(0xFFC0352B),
    dangerSoft: Color(0xFFFDE8E6),
    userBubble: Color(0xFFE7E4FB),
  );

  static const dark = CompiiColors(
    canvas: Color(0xFF111019),
    surface: Color(0xFF17161F),
    raised: Color(0xFF1F1E29),
    sunken: Color(0xFF14131B),
    border: Color(0xFF2C2A38),
    text: Color(0xFFECEAF3),
    muted: Color(0xFFA7A2B5),
    faint: Color(0xFF77728A),
    accent: Color(0xFF8C82FF),
    accentSoft: Color(0xFF26234A),
    onAccent: Color(0xFF0F0D1F),
    success: Color(0xFF5BD18B),
    warning: Color(0xFFF2B24B),
    warningSoft: Color(0xFF332712),
    danger: Color(0xFFFF7A6E),
    dangerSoft: Color(0xFF3A1A18),
    userBubble: Color(0xFF2A2650),
  );

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
      border: l(border, other.border),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccent: l(onAccent, other.onAccent),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
      danger: l(danger, other.danger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      userBubble: l(userBubble, other.userBubble),
    );
  }
}

extension CompiiTheme on BuildContext {
  CompiiColors get c => Theme.of(this).extension<CompiiColors>()!;
  TextTheme get type => Theme.of(this).textTheme;
}

const _font = 'Segoe UI Variable Text';
const _fallback = ['Segoe UI', 'Roboto'];

ThemeData compiiTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? CompiiColors.dark : CompiiColors.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: _font,
    fontFamilyFallback: _fallback,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.surface,
      onSurface: c.text,
      error: c.danger,
    ),
    scaffoldBackgroundColor: c.canvas,
    dividerColor: c.border,
    extensions: [c],
  );
  final t = base.textTheme;
  return base.copyWith(
    textTheme: t.copyWith(
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w600, color: c.text, letterSpacing: -.4),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: c.text, fontSize: 18),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: c.text, fontSize: 15),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: c.text, fontSize: 13.5),
      bodyLarge: t.bodyLarge?.copyWith(color: c.text, fontSize: 15, height: 1.5),
      bodyMedium: t.bodyMedium?.copyWith(color: c.text, fontSize: 14, height: 1.45),
      bodySmall: t.bodySmall?.copyWith(color: c.muted, fontSize: 12.5, height: 1.4),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5),
      labelMedium: t.labelMedium?.copyWith(color: c.muted, fontSize: 12),
    ),
    iconTheme: IconThemeData(color: c.muted, size: 20),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        minimumSize: const Size(44, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.border),
        minimumSize: const Size(44, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.muted,
        minimumSize: const Size(36, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontFamily: _font, fontFamilyFallback: _fallback, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: c.canvas, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.text,
      contentTextStyle: TextStyle(color: c.canvas),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
