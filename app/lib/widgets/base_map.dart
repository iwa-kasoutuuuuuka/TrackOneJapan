import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/state/map_type.dart';

/// 地図の背景タイル（国土地理院 / OpenStreetMap）
Widget baseTileLayer(BuildContext context, MapType mapType) => TileLayer(
      key: ValueKey(mapType),
      urlTemplate: mapType.url,
      maxNativeZoom: mapType.maxNativeZoom,
      // 地理院タイルは 256px 前提のため、高精細画面では 1 段細かいタイルを縮小して表示
      retinaMode: mapType.retina && RetinaMode.isHighDensity(context),
      userAgentPackageName: 'io.github.iwakasoutuuuuuka.trackone_japan',
    );

/// 地図の出典表示（利用条件）
Widget baseAttribution(MapType mapType) => RichAttributionWidget(
      alignment: AttributionAlignment.bottomLeft,
      showFlutterMapAttribution: false,
      attributions: [
        TextSourceAttribution(mapType.attribution, onTap: () => launchUrl(Uri.parse(mapType.attributionUrl))),
      ],
    );
