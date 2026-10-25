import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth.dart';

/// 画面の明るさの設定（初期値: スマホ・PC の設定に合わせる）
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    Future.microtask(() async {
      final saved = await ref.read(sessionStoreProvider).readThemeMode();
      final t = ThemeMode.values.where((e) => e.name == saved);
      if (t.isNotEmpty && ref.mounted) state = t.first;
    });
    return ThemeMode.system;
  }

  void set(ThemeMode mode) {
    state = mode;
    ref.read(sessionStoreProvider).saveThemeMode(mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

String themeModeLabel(ThemeMode m) => switch (m) {
      ThemeMode.system => 'スマホ・PC の設定に合わせる',
      ThemeMode.light => '明るい画面',
      ThemeMode.dark => '暗い画面（ダークモード）',
    };
