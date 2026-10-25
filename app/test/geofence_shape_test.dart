import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:trackone_japan/core/geofence_shape.dart';

void main() {
  test('円を Traccar の形式（緯度 経度, 半径）で書き出す', () {
    const c = CircleShape(LatLng(35.6717, 139.6949), 300);
    expect(c.toWkt(), 'CIRCLE (35.671700 139.694900, 300.0)');
  });

  test('円を読み取る（実際のサーバーの値）', () {
    final s = GeofenceShape.parse('CIRCLE (35.6717 139.6949, 300)');
    expect(s, isA<CircleShape>());
    final c = s as CircleShape;
    expect(c.center.latitude, 35.6717);
    expect(c.center.longitude, 139.6949);
    expect(c.radius, 300);
  });

  test('多角形は輪を閉じて書き出し、読み取るときは閉じた点を除く', () {
    const p = PolygonShape([LatLng(35.0, 139.0), LatLng(35.1, 139.0), LatLng(35.1, 139.1)]);
    final wkt = p.toWkt();
    expect(wkt, 'POLYGON ((35.000000 139.000000, 35.100000 139.000000, 35.100000 139.100000, 35.000000 139.000000))');
    final back = GeofenceShape.parse(wkt) as PolygonShape;
    expect(back.points.length, 3);
    expect(back.points.first, const LatLng(35.0, 139.0));
  });

  test('Traccar 管理画面で作った閉じていない多角形も読める', () {
    final back = GeofenceShape.parse('POLYGON((35.0 139.0, 35.1 139.0, 35.1 139.1, 35.0 139.1))') as PolygonShape;
    expect(back.points.length, 4);
  });

  test('対応していない形・壊れた値は null', () {
    expect(GeofenceShape.parse('LINESTRING (35 139, 36 140)'), isNull);
    expect(GeofenceShape.parse('CIRCLE (abc)'), isNull);
    expect(GeofenceShape.parse('POLYGON ((35 139, 36 140))'), isNull); // 2 点では多角形にならない
  });

  test('円の範囲（地図に収める点）は半径ぶん離れた 4 点', () {
    const c = CircleShape(LatLng(35.0, 139.0), 1000);
    final pts = c.boundsPoints;
    expect(pts.length, 4);
    const d = Distance();
    for (final p in pts) {
      expect(d.as(LengthUnit.Meter, c.center, p), closeTo(1000, 2));
    }
  });

  test('半径の表示', () {
    expect(formatRadius(300), '300 m');
    expect(formatRadius(1500), '1.5 km');
  });
}
