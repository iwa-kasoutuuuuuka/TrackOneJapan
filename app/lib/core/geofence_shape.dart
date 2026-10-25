import 'package:latlong2/latlong.dart';

/// エリア（ジオフェンス）の形。Traccar は WKT 形式の文字列で保存する。
/// 注意：Traccar の WKT は「緯度 経度」の順（一般的な WKT の「経度 緯度」とは逆）。
sealed class GeofenceShape {
  const GeofenceShape();

  String toWkt();

  /// 地図に収めるための点（円は東西南北の端、多角形は頂点）
  List<LatLng> get boundsPoints;

  /// 文字列から形を読み取る。円と多角形以外（線など）は null
  static GeofenceShape? parse(String wkt) {
    final s = wkt.trim();
    final upper = s.toUpperCase();
    try {
      if (upper.startsWith('CIRCLE')) {
        final inner = s.substring(s.indexOf('(') + 1, s.lastIndexOf(')'));
        final parts = inner.split(',');
        final ll = parts[0].trim().split(RegExp(r'\s+'));
        return CircleShape(LatLng(double.parse(ll[0]), double.parse(ll[1])), double.parse(parts[1].trim()));
      }
      if (upper.startsWith('POLYGON')) {
        final inner = s.substring(s.indexOf('(') + 1, s.lastIndexOf(')')).replaceAll('(', '').replaceAll(')', '');
        final points = inner.split(',').map((p) {
          final ll = p.trim().split(RegExp(r'\s+'));
          return LatLng(double.parse(ll[0]), double.parse(ll[1]));
        }).toList();
        // 最後の点が最初の点と同じ（閉じた輪）なら、編集用には除く
        if (points.length > 3 && points.first == points.last) points.removeLast();
        return points.length >= 3 ? PolygonShape(points) : null;
      }
    } catch (_) {}
    return null;
  }
}

class CircleShape extends GeofenceShape {
  const CircleShape(this.center, this.radius);
  final LatLng center;
  final double radius; // メートル

  static const minRadius = 50.0;
  static const maxRadius = 5000.0;

  @override
  String toWkt() => 'CIRCLE (${_n(center.latitude)} ${_n(center.longitude)}, ${radius.toStringAsFixed(1)})';

  @override
  List<LatLng> get boundsPoints {
    const d = Distance();
    return [0.0, 90.0, 180.0, 270.0].map((bearing) => d.offset(center, radius, bearing)).toList();
  }
}

class PolygonShape extends GeofenceShape {
  const PolygonShape(this.points);
  final List<LatLng> points; // 閉じていない頂点の並び（3 点以上）

  @override
  String toWkt() {
    final ring = [...points, points.first]; // 輪を閉じる
    return 'POLYGON ((${ring.map((p) => '${_n(p.latitude)} ${_n(p.longitude)}').join(', ')}))';
  }

  @override
  List<LatLng> get boundsPoints => points;
}

String _n(double v) => v.toStringAsFixed(6);

/// 半径の表示（「300 m」「1.5 km」）
String formatRadius(double meters) => meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km';
