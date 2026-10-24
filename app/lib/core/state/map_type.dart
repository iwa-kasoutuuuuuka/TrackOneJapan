import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth.dart';

/// 無料・登録不要の地図タイル
enum MapType {
  gsiStd('標準地図（国土地理院）', 'https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png', 18, '地理院タイル',
      'https://maps.gsi.go.jp/development/ichiran.html', true),
  gsiPale('淡色地図（国土地理院）', 'https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png', 18, '地理院タイル',
      'https://maps.gsi.go.jp/development/ichiran.html', true),
  gsiPhoto('航空写真（国土地理院）', 'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg', 18, '地理院タイル',
      'https://maps.gsi.go.jp/development/ichiran.html', true),
  osmJa('OpenStreetMap（日本語）', 'https://tile.openstreetmap.jp/styles/osm-bright-ja/{z}/{x}/{y}.png', 18,
      '© OpenStreetMap contributors', 'https://www.openstreetmap.org/copyright', false);

  const MapType(this.label, this.url, this.maxNativeZoom, this.attribution, this.attributionUrl, this.retina);
  final String label;
  final String url;
  final int maxNativeZoom;
  final String attribution;
  final String attributionUrl;
  /// 高精細画面で 1 段細かいタイルを使うか（256px タイル向け）
  final bool retina;
}

class MapTypeNotifier extends Notifier<MapType> {
  @override
  MapType build() {
    Future.microtask(() async {
      final saved = await ref.read(sessionStoreProvider).readMapType();
      final t = MapType.values.where((e) => e.name == saved);
      if (t.isNotEmpty) state = t.first;
    });
    return MapType.gsiStd;
  }

  void set(MapType t) {
    state = t;
    ref.read(sessionStoreProvider).saveMapType(t.name);
  }
}

final mapTypeProvider = NotifierProvider<MapTypeNotifier, MapType>(MapTypeNotifier.new);
