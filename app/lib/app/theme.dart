import 'package:flutter/material.dart';

/// The app's palette.
///
/// OLED rules from the spec are encoded here rather than at call sites:
/// the background is *pure* `#000000` — never a near-black such as `#111111`,
/// which burns the same power while looking washed out on an OLED panel — and
/// separation between surfaces is expressed with hairline strokes and value
/// contrast instead of elevated grey fills.
abstract final class AppColors {
  static const Color background = Color(0xFF000000);

  /// Card fill. Identical to the background on purpose; the border does the
  /// separating. A slightly lifted fill here would defeat the OLED savings.
  static const Color surface = Color(0xFF000000);

  /// Fill for genuinely raised, transient surfaces (sheets, dialogs) where a
  /// border alone would not read.
  static const Color surfaceRaised = Color(0xFF161616);

  static const Color hairline = Color(0x1FFFFFFF);
  static const Color hairlineStrong = Color(0x3DFFFFFF);

  /// Translucent black laid over the map. Two strengths, because the two uses
  /// have different jobs: a badge has to stay readable over bright road tiles,
  /// an attribution line only has to be legible over the map's own fill.
  static const Color scrim = Color(0xCC000000);
  static const Color scrimSoft = Color(0x99000000);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFA8ADB4);
  static const Color textTertiary = Color(0xFF6B7075);

  /// Live / moving / primary action.
  static const Color accent = Color(0xFFC8FF3D);
  static const Color accentMuted = Color(0x33C8FF3D);

  /// Auto-paused or awaiting user action.
  static const Color warning = Color(0xFFFFB020);

  /// Off-route, GPS lost, sync failure.
  static const Color danger = Color(0xFFFF453A);

  /// Synced / confirmed.
  static const Color success = Color(0xFF30D158);

  /// The planned route — the line the rider is following.
  ///
  /// This is the accent, and on a map it is the only thing that should be.
  /// Planning a good cycling route is the product's primary action, and the
  /// route line is where that action becomes visible.
  static const Color routeLine = Color(0xFFC8FF3D);

  /// The recorded track — where the rider has actually been.
  ///
  /// Deliberately *not* the accent, even on the screens where it is the only
  /// line drawn. The accent means "in progress / primary action", and the
  /// live thing on a map is the position marker, which already carries it. A
  /// track is a fact about the past. Both being accent-lime meant that in
  /// navigation — the one screen that draws a route *and* a track on the same
  /// map — two lines shared the colour that is supposed to mean one thing.
  ///
  /// The value is the midpoint of the theme's own text ramp, halfway between
  /// `textSecondary` and `textTertiary`. It reads on both the dimmed basemap
  /// and AMap's light one, and recedes next to the route drawn over it.
  static const Color trackLine = Color(0xFF8A8F95);

  static const Color elevationFill = Color(0x33C8FF3D);
}

/// Named text styles.
///
/// The dashboard is read at arm's length, in sunlight, with gloves on, so the
/// hierarchy is extreme: one enormous number and a set of small, quiet labels.
abstract final class AppText {
  /// Tabular figures keep digits from shifting width as values change, which
  /// is the difference between a calm readout and a jittering one.
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// The hero number. Size is supplied by the layout, since it must scale to
  /// the available box; everything else about it is fixed.
  static TextStyle hero(double size) => TextStyle(
        fontSize: size,
        height: 0.92,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.02 * size,
        color: AppColors.textPrimary,
        fontFeatures: _tabular,
      );

  static const TextStyle bigValue = TextStyle(
    fontSize: 34,
    height: 1.0,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.8,
    color: AppColors.textPrimary,
    fontFeatures: _tabular,
  );

  static const TextStyle value = TextStyle(
    fontSize: 24,
    height: 1.05,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFeatures: _tabular,
  );

  static const TextStyle smallValue = TextStyle(
    fontSize: 19,
    height: 1.1,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFeatures: _tabular,
  );

  static const TextStyle unit = TextStyle(
    fontSize: 13,
    height: 1.1,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.6,
    color: AppColors.textSecondary,
  );

  static const TextStyle label = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.4,
    color: AppColors.textSecondary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: AppColors.textTertiary,
  );

  static const TextStyle sectionTitle = TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
    color: AppColors.textTertiary,
  );

  /// Turn instruction text in navigation, e.g. 「左转」.
  static const TextStyle maneuver = TextStyle(
    fontSize: 30,
    height: 1.1,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle title = TextStyle(
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.35,
    color: AppColors.textPrimary,
  );

  /// Button label on the primary action. Sized for gloved taps, not for
  /// elegance: 18pt minimum.
  static const TextStyle button = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
  );

  /// The start button's label — the one control the home screen exists for
  /// (spec §4: find it within a second). Larger than [button] on purpose, but
  /// still a token so it cannot drift into a one-off at the call site.
  static const TextStyle cta = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
  );
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: Color(0xFF000000),
    secondary: AppColors.accent,
    onSecondary: Color(0xFF000000),
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    error: AppColors.danger,
    onError: Color(0xFF000000),
    outline: AppColors.hairline,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    fontFamily: null,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: AppText.title,
      iconTheme: IconThemeData(color: AppColors.textPrimary),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      space: 1,
      thickness: 1,
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.background,
      selectedItemColor: AppColors.accent,
      unselectedItemColor: AppColors.textTertiary,
      type: BottomNavigationBarType.fixed,
      showUnselectedLabels: true,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 62,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppText.label.copyWith(color: AppColors.accent)
            : AppText.label.copyWith(color: AppColors.textTertiary),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.textTertiary,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        // 56pt tall: tappable with winter gloves on a bike mount.
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: AppText.button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: AppColors.hairlineStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: AppText.button,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        textStyle: AppText.body,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textSecondary,
      textColor: AppColors.textPrimary,
      subtitleTextStyle: AppText.caption,
      contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.black
            : AppColors.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.surfaceRaised,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(AppColors.hairline),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.hairline,
      thumbColor: AppColors.accent,
      overlayColor: AppColors.accentMuted,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceRaised,
      hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: AppText.title,
      contentTextStyle: AppText.body,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceRaised,
      contentTextStyle: AppText.body,
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: AppColors.hairline,
    ),
  );
}
