import 'package:flutter/material.dart';

/// TrackOne Japan のブランドカラー（オリジナルアイコンと同じ配色）
///
/// 状態を表す色（赤・青緑・橙・緑・灰）と、ボタンなどの塗りに使う紺は明るい画面・暗い画面で共通。
/// 背景・文字・紺の文字など、明るさで変える色は [AppPalette]（`context.pal`）を使う。
class AppColors {
  static const navy = Color(0xFF1F4A85);
  static const navyDark = Color(0xFF0D2346);
  static const red = Color(0xFFE63946);
  static const teal = Color(0xFF20B7A3);
  static const orange = Color(0xFFF08C00);
  static const green = Color(0xFF2B9348);
  static const gray = Color(0xFF8A94A6);
  // 以下は明るい画面の値。画面では context.pal の同名の色を使う
  static const ink = Color(0xFF1B2333);
  static const sub = Color(0xFF5B6475);
  static const surface = Color(0xFFF5F7FA);
}

/// 明るい画面・暗い画面で変わる色
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.card,
    required this.surface,
    required this.ink,
    required this.sub,
    required this.brand,
    required this.warnBg,
    required this.dangerBg,
    required this.chipBg,
  });

  /// カード・シート・入力欄などの背景（明: 白）
  final Color card;

  /// 画面の背景（明: 薄い灰色）
  final Color surface;

  /// 本文の文字
  final Color ink;

  /// 補足の文字
  final Color sub;

  /// 紺の文字・アイコン（暗い画面では明るい青にして読みやすくする）
  final Color brand;

  /// 注意書きの背景（薄い橙）
  final Color warnBg;

  /// 危険・エラーの背景（薄い赤）
  final Color dangerBg;

  /// 選択中の行・チップの背景（薄い紺）
  final Color chipBg;

  static const light = AppPalette(
    card: Colors.white,
    surface: AppColors.surface,
    ink: AppColors.ink,
    sub: AppColors.sub,
    brand: AppColors.navy,
    warnBg: Color(0xFFFFF4E0),
    dangerBg: Color(0xFFFDECEE),
    chipBg: Color(0xFFE8EEF7),
  );

  static const dark = AppPalette(
    card: Color(0xFF1A202B),
    surface: Color(0xFF10141B),
    ink: Color(0xFFE7EAF0),
    sub: Color(0xFFA9B1BF),
    brand: Color(0xFF8FB5F2),
    warnBg: Color(0xFF3A2C10),
    dangerBg: Color(0xFF3D1A1E),
    chipBg: Color(0xFF243247),
  );

  @override
  AppPalette copyWith({Color? card, Color? surface, Color? ink, Color? sub, Color? brand, Color? warnBg, Color? dangerBg, Color? chipBg}) =>
      AppPalette(
        card: card ?? this.card,
        surface: surface ?? this.surface,
        ink: ink ?? this.ink,
        sub: sub ?? this.sub,
        brand: brand ?? this.brand,
        warnBg: warnBg ?? this.warnBg,
        dangerBg: dangerBg ?? this.dangerBg,
        chipBg: chipBg ?? this.chipBg,
      );

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      card: Color.lerp(card, other.card, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      sub: Color.lerp(sub, other.sub, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      warnBg: Color.lerp(warnBg, other.warnBg, t)!,
      dangerBg: Color.lerp(dangerBg, other.dangerBg, t)!,
      chipBg: Color.lerp(chipBg, other.chipBg, t)!,
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// いまの明るさに合った色（例: `context.pal.sub`）
  AppPalette get pal => Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

ThemeData buildTheme([Brightness brightness = Brightness.light]) {
  final dark = brightness == Brightness.dark;
  final pal = dark ? AppPalette.dark : AppPalette.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.navy,
    brightness: brightness,
    // 暗い画面でもボタンは紺系の塗り＋白い文字にする
    primary: dark ? const Color(0xFF3F6FB5) : AppColors.navy,
    onPrimary: Colors.white,
    secondary: AppColors.red,
    surface: pal.card,
    onSurface: pal.ink,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: pal.card,
    canvasColor: pal.card,
    extensions: [pal],
    appBarTheme: AppBarTheme(
      backgroundColor: pal.card,
      foregroundColor: pal.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      // 横幅いっぱいにはしない（確認画面のボタンが崩れるため）。必要な画面で個別に広げる
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
