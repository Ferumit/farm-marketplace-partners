import 'package:flutter/material.dart';

import 'tokens.dart';

/// The app's theme, and the one way to reach the palette from a widget.
///
/// Flutter's ColorScheme cannot hold everything the design uses (tints, the two ink greys, the
/// track behind a progress bar), so the full palette rides along as a ThemeExtension and screens
/// read it through `context.et`.
class EtTheme extends ThemeExtension<EtTheme> {
  const EtTheme({required this.colors, required this.isDark});

  final EtColors colors;
  final bool isDark;

  @override
  EtTheme copyWith({EtColors? colors, bool? isDark}) =>
      EtTheme(colors: colors ?? this.colors, isDark: isDark ?? this.isDark);

  @override
  EtTheme lerp(covariant EtTheme? other, double t) => t < 0.5 ? this : (other ?? this);

  static ThemeData light() => _build(EtColors.light, Brightness.light);
  static ThemeData dark() => _build(EtColors.dark, Brightness.dark);

  static ThemeData _build(EtColors c, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    // Playfair for headings and Inter for everything else - the website's pairing, so the two
    // surfaces read as one product.
    //
    // Оба начертания вшиты в пакет (см. pubspec) и берутся из него, а не из сети. Пакет
    // google_fonts качал их при первом запуске, и телефон без связи оставался с системным
    // шрифтом — молча, потому что подмену шрифта никто не считает ошибкой.
    final base = ThemeData(brightness: brightness).textTheme;
    final display = base.apply(fontFamily: 'Playfair Display', package: 'et_ui');
    final body = base.apply(fontFamily: 'Inter', package: 'et_ui');

    final text = body
        .copyWith(
          displayLarge: display.displayLarge,
          displayMedium: display.displayMedium,
          displaySmall: display.displaySmall,
          headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w800),
          headlineMedium: display.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        )
        .apply(bodyColor: c.ink, displayColor: c.ink);

    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.greenSurface,
      onPrimary: c.onGreen,
      primaryContainer: c.greenTint,
      onPrimaryContainer: c.green,
      secondary: c.rust,
      onSecondary: Colors.white,
      secondaryContainer: c.rustTint,
      onSecondaryContainer: c.rust,
      error: c.danger,
      onError: Colors.white,
      surface: c.surface,
      onSurface: c.ink,
      surfaceContainerHighest: c.surfaceRaised,
      outline: c.line,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      textTheme: text,
      extensions: [EtTheme(colors: c, isDark: isDark)],
      // Переход между экранами: страница уезжает и растворяется, следующая приходит ей навстречу.
      // Старый андроидный переход выбрасывал экран снизу рывком — на экране, где человек открывает
      // тушу за тушей, это читается дёрганно. Здесь же и iOS, чтобы движение было одно на всех.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(fontSize: 22),
      ),
      cardTheme: CardThemeData(
        color: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: EtShape.cardRadius,
          side: BorderSide(color: c.line),
        ),
      ),
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),

      // Выбор одного из двух — зелёный, как и всё выбранное на платформе. По умолчанию Material
      // красит его вторичным цветом схемы, и «Половинами» выглядело тревожно-розовым, будто это
      // предупреждение, а не ответ на вопрос.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? c.greenTint : c.surfaceRaised,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? c.green : c.ink,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: c.line)),
          textStyle: WidgetStatePropertyAll(
            body.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),

      // Отмеченное — тоже зелёное: в списках скота и в конструкторе лота это один и тот же жест.
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.green : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(c.onGreen),
        side: BorderSide(color: c.inkFaint, width: 1.5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.greenSurface,
          foregroundColor: c.onGreen,
          minimumSize: const Size.fromHeight(52),
          textStyle: body.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.ink,
          side: BorderSide(color: c.line),
          minimumSize: const Size.fromHeight(52),
          textStyle: body.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.green,
          textStyle: body.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceRaised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: EtShape.smallRadius,
          borderSide: BorderSide(color: c.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: EtShape.smallRadius,
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: EtShape.smallRadius,
          borderSide: BorderSide(color: c.green, width: 1.6),
        ),
        labelStyle: TextStyle(color: c.inkDim),
        hintStyle: TextStyle(color: c.inkFaint),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? c.surfaceRaised : c.ink,
        contentTextStyle: TextStyle(color: isDark ? c.ink : c.surface),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: EtShape.smallRadius),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: c.surfaceRaised,
        selectedItemColor: c.green,
        unselectedItemColor: c.inkFaint,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.green, linearTrackColor: c.fillTrack),
    );
  }
}

extension EtThemeAccess on BuildContext {
  /// The full palette. Every screen reads colours through this and never hard-codes one.
  EtColors get et => Theme.of(this).extension<EtTheme>()!.colors;

  bool get isDarkTheme => Theme.of(this).extension<EtTheme>()!.isDark;

  TextTheme get texts => Theme.of(this).textTheme;
}
