import 'package:flutter/material.dart';

/// Neutral charcoal dark skin (no blue cast).
/// Zinc/graphite surfaces + soft amber accent for controls.
class AppTheme {
  static const accent = Color(0xFFE8B86D);
  static const accentSoft = Color(0xFFF0C98A);
  static const bg = Color(0xFF111111);
  static const bgMid = Color(0xFF161616);
  static const panel = Color(0xFF1A1A1A);
  static const panelElevated = Color(0xFF222222);
  static const surfaceInput = Color(0xFF141414);
  static const border = Color(0x24FFFFFF);
  static const textPrimary = Color(0xFFF5F5F5);
  static const textSecondary = Color(0xFFB0B0B0);
  static const textMuted = Color(0xFF8A8A8A);
  static const textDim = Color(0xFF5C5C5C);
  static const success = Color(0xFF4ADE80);
  static const danger = Color(0xFFF87171);

  static const colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: accent,
    onPrimary: Color(0xFF1A1208),
    primaryContainer: Color(0xFF3D2E18),
    onPrimaryContainer: Color(0xFFFFE8C2),
    secondary: accentSoft,
    onSecondary: Color(0xFF1A1208),
    secondaryContainer: Color(0xFF3A3018),
    onSecondaryContainer: Color(0xFFFFF0D4),
    tertiary: Color(0xFFD4D4D4),
    onTertiary: Color(0xFF111111),
    error: danger,
    onError: Color(0xFF1A0505),
    surface: panel,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    outline: textDim,
    outlineVariant: Color(0xFF2E2E2E),
    surfaceContainerHighest: panelElevated,
    surfaceContainerHigh: panel,
    surfaceContainer: bgMid,
    surfaceContainerLow: bg,
    surfaceContainerLowest: Color(0xFF0A0A0A),
  );

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      fontFamily: 'Microsoft YaHei',
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      iconTheme: const IconThemeData(color: textSecondary),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: textDim.withValues(alpha: 0.45),
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.16),
        valueIndicatorColor: panelElevated,
        valueIndicatorTextStyle: const TextStyle(color: textPrimary, fontSize: 12),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return textDim;
          if (states.contains(WidgetState.selected)) return accent;
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(Color(0xFF1A1208)),
        side: const BorderSide(color: textMuted, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return textDim;
          if (states.contains(WidgetState.selected)) return accent;
          return textSecondary;
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF1A1208),
          disabledBackgroundColor: textDim.withValues(alpha: 0.35),
          disabledForegroundColor: textMuted,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          disabledForegroundColor: textDim,
          side: const BorderSide(color: Color(0x33FFFFFF)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceInput,
        hintStyle: const TextStyle(color: textDim, fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border.withValues(alpha: 0.5)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accentSoft,
        linearTrackColor: Color(0x14FFFFFF),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: panelElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        textStyle: const TextStyle(color: textPrimary, fontSize: 12),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(textMuted.withValues(alpha: 0.55)),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(8),
      ),
    );
  }

  /// Neutral graphite backdrop — charcoal, not blue.
  static BoxDecoration scaffoldBackdrop() {
    return const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF161616),
          bg,
          Color(0xFF101010),
          Color(0xFF141414),
        ],
        stops: [0.0, 0.35, 0.7, 1.0],
      ),
    );
  }
}
