import 'package:flutter/material.dart';

/// TrackOne Japan のブランドカラー（オリジナルアイコンと同じ配色）
class AppColors {
  static const navy = Color(0xFF1F4A85);
  static const navyDark = Color(0xFF0D2346);
  static const red = Color(0xFFE63946);
  static const teal = Color(0xFF20B7A3);
  static const orange = Color(0xFFF08C00);
  static const green = Color(0xFF2B9348);
  static const gray = Color(0xFF8A94A6);
  static const ink = Color(0xFF1B2333);
  static const sub = Color(0xFF5B6475);
  static const surface = Color(0xFFF5F7FA);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.navy,
    primary: AppColors.navy,
    secondary: AppColors.red,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: AppColors.ink,
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
