

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A deliberately plain, dense, high-contrast theme.
///
/// The full visual direction is still an open decision. What is settled here
/// is the part that affects use rather than taste: tap targets big enough for
/// a thumb over a counter, numbers that line up in columns, and no Material
/// default purple.
class NivraTheme {
  const NivraTheme._();

  // Ink and a single accent. Deep green reads as money in India without
  // borrowing the blue every competitor already uses.
  static const Color _accent = Color(0xFF0F6B4F);
  static const Color _accentDark = Color(0xFF3DBF92);
  static const Color _ink = Color(0xFF141A17);
  static const Color _paper = Color(0xFFF7F6F2);

  /// Money and quantities use tabular figures so columns line up and a
  /// changing total does not make the row jitter.
  static const List<FontFeature> numericFeatures = [
    FontFeature.tabularFigures(),
  ];

  static ThemeData light() => _build(
        ColorScheme.fromSeed(
          seedColor: _accent,
          brightness: Brightness.light,
        ).copyWith(surface: _paper, onSurface: _ink),
        Brightness.light,
      );

  static ThemeData dark() => _build(
        ColorScheme.fromSeed(
          seedColor: _accentDark,
          brightness: Brightness.dark,
        ),
        Brightness.dark,
      );

  static ThemeData _build(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    final isLight = brightness == Brightness.light;

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
        systemOverlayStyle:
            isLight ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isLight ? Colors.white : scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 52dp: a thumb, one-handed, without looking.
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minVerticalPadding: 10,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

/// Text styles for figures. Used everywhere a rupee or a quantity appears.
extension NumericTextStyles on TextTheme {
  TextStyle get money => (titleMedium ?? const TextStyle()).copyWith(
        fontFeatures: NivraTheme.numericFeatures,
        fontWeight: FontWeight.w600,
      );

  TextStyle get moneyLarge => (headlineSmall ?? const TextStyle()).copyWith(
        fontFeatures: NivraTheme.numericFeatures,
        fontWeight: FontWeight.w700,
      );

  TextStyle get figure => (bodyMedium ?? const TextStyle()).copyWith(
        fontFeatures: NivraTheme.numericFeatures,
      );
}
