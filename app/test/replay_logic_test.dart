import 'package:flutter_test/flutter_test.dart';
import 'package:trackone_japan/features/replay/replay_logic.dart';
import 'package:trackone_japan/models/models.dart';

Position _p(double lat, double lon, DateTime t) => Position(
    id: 1, deviceId: 1, fixTime: t, valid: true, latitude: lat, longitude: lon, speed: 0, course: 0, address: null, attributes: const {});

void main() {
  test('日の範囲（過去の日は 0:00〜23:59:59）', () {
    final r = dayRange(DateTime(2026, 10, 22, 15), now: DateTime(2026, 10, 24, 12));
    expect(r.from, DateTime(2026, 10, 22));
    expect(r.to, DateTime(2026, 10, 22, 23, 59, 59));
  });

  test('今日の範囲は「今」まで', () {
    final now = DateTime(2026, 10, 24, 12, 30);
    final r = dayRange(DateTime(2026, 10, 24, 8), now: now);
    expect(r.from, DateTime(2026, 10, 24));
    expect(r.to, now);
  });

  test('再生の進み方（1x = 1 秒に 2 地点）', () {
    expect(advanceCursor(0, 1, const Duration(milliseconds: 250)), 0.5);
    expect(advanceCursor(10, 4, const Duration(milliseconds: 250)), 12);
  });

  test('走行時間の合計', () {
    final t = DateTime(2026, 10, 24);
    final trips = [
      TripReport(startTime: t, endTime: t, duration: const Duration(minutes: 7, seconds: 30), distance: 2000, maxSpeed: 20),
      TripReport(startTime: t, endTime: t, duration: const Duration(minutes: 13), distance: 8000, maxSpeed: 22),
    ];
    expect(totalDriving(trips), const Duration(minutes: 20, seconds: 30));
  });

  test('GPX の書き出し', () {
    final gpx = buildGpx('車 & バイク', [
      _p(35.681236, 139.767125, DateTime.utc(2026, 10, 24, 0, 0)),
      _p(35.6955, 139.7509, DateTime.utc(2026, 10, 24, 0, 7, 30)),
    ]);
    expect(gpx, contains('<gpx version="1.1"'));
    expect(gpx, contains('<name>車 &amp; バイク</name>'));
    expect(gpx, contains('<trkpt lat="35.681236" lon="139.767125"><time>2026-10-24T00:00:00.000Z</time></trkpt>'));
    expect(RegExp('<trkpt').allMatches(gpx).length, 2);
  });

  test('ファイル名の整形', () {
    expect(safeFileName('テスト 車/1'), 'テスト_車_1');
    expect(safeFileName(''), 'device');
  });

  test('走行距離はルートの線の長さ（地点の順序が崩れた集計に左右されない）', () {
    // 東京駅 → 新宿駅は直線で約 6.1 km
    expect(haversine(35.6812, 139.7671, 35.6896, 139.7006) / 1000, closeTo(6.07, 0.1));
    expect(routeDistance(const []), 0);
  });
}
