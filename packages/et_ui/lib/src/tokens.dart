import 'package:flutter/material.dart';

/// The platform's colours, in both themes.
///
/// These are the website's tokens (css/tokens.css), not a second palette that merely resembles
/// them: a buyer who opens the site and the app on the same evening must see one product. The
/// names match the CSS so a change on one side is easy to carry to the other.
class EtColors {
  const EtColors({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.ink,
    required this.inkDim,
    required this.inkFaint,
    required this.line,
    required this.green,
    required this.greenSurface,
    required this.greenTint,
    required this.rust,
    required this.rustTint,
    required this.danger,
    required this.dangerTint,
    required this.warn,
    required this.fillTrack,
    required this.onGreen,
  });

  /// Фон страницы. На сайте это --bg: тёплый песочный, на два тона темнее карточек — именно он
  /// и делает так, что карточка ЛЕЖИТ на странице, а не растворяется в ней. Приложение раньше
  /// красило страницу цветом --surface, почти белым, и всё выглядело выстиранным.
  final Color bg;

  /// Поверхность второго уровня: вложенные блоки внутри карточки, листы, поля.
  final Color surface;

  /// Карточка.
  final Color surfaceRaised;
  final Color ink;
  final Color inkDim;
  final Color inkFaint;
  final Color line;
  final Color green;
  final Color greenSurface;
  final Color greenTint;
  final Color rust;
  final Color rustTint;
  final Color danger;
  final Color dangerTint;
  final Color warn;
  final Color fillTrack;
  final Color onGreen;

  static const light = EtColors(
    bg: Color(0xFFF3F0E8),
    surface: Color(0xFFFBFAF6),
    surfaceRaised: Color(0xFFFFFFFF),
    ink: Color(0xFF1C1B19),
    inkDim: Color(0xFF6F6A5E),
    inkFaint: Color(0xFF726C60),
    line: Color(0xFFE6E1D6),
    green: Color(0xFF0F4C3B),
    greenSurface: Color(0xFF0F4C3B),
    greenTint: Color(0xFFE4EDE9),
    rust: Color(0xFF9C4A2E),
    rustTint: Color(0xFFF1E4DE),
    danger: Color(0xFFB3392A),
    dangerTint: Color(0x1FB3392A),
    warn: Color(0xFF8A5A12),
    fillTrack: Color(0xFFEDE9DE),
    onGreen: Color(0xFFFFFFFF),
  );

  /// Dark is not an inversion: the greens lighten so they still read as ACCENT TEXT on a dark
  /// page, while buttons keep a deep green underneath white type.
  static const dark = EtColors(
    bg: Color(0xFF14120F),
    surface: Color(0xFF1C1917),
    surfaceRaised: Color(0xFF232019),
    ink: Color(0xFFF5F1E8),
    inkDim: Color(0xFFB8B1A3),
    inkFaint: Color(0xFF9A9384),
    line: Color(0xFF2E2A24),
    green: Color(0xFF4FBF96),
    greenSurface: Color(0xFF13624A),
    greenTint: Color(0xFF17302A),
    rust: Color(0xFFD98060),
    rustTint: Color(0xFF32211B),
    danger: Color(0xFFE8705E),
    dangerTint: Color(0x33E8705E),
    warn: Color(0xFFE0A34A),
    fillTrack: Color(0xFF2A2721),
    onGreen: Color(0xFFFFFFFF),
  );
}

/// Corners, spacing and the two shadows - collected so screens stop inventing their own.
class EtShape {
  EtShape._();

  static const radiusCard = 22.0;
  static const radiusSmall = 12.0;
  static const radiusPill = 999.0;

  static const gutter = 20.0;
  static const gap = 14.0;
  static const gapSmall = 8.0;

  static const cardRadius = BorderRadius.all(Radius.circular(radiusCard));
  static const smallRadius = BorderRadius.all(Radius.circular(radiusSmall));

  /// Тень карточки — та же, что на сайте (--shadow-card): широкая, мягкая, смещённая вниз.
  /// Без неё белая карточка на песочной странице держится только рамкой и выглядит наклейкой.
  static List<BoxShadow> card(bool dark) => [
        BoxShadow(
          color: dark ? const Color(0x99000000) : const Color(0x2E1C1B19),
          blurRadius: 30,
          spreadRadius: -12,
          offset: const Offset(0, 12),
        ),
      ];

  /// --shadow-soft: для мелочи, которая только приподнята.
  static List<BoxShadow> soft(bool dark) => [
        BoxShadow(
          color: dark ? const Color(0x66000000) : const Color(0x14141210),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
}
