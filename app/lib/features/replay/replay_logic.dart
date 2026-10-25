import 'dart:math' as math;

import '../../models/models.dart';

/// 指定した日の 0:00〜23:59:59（端末のタイムゾーン）。今日なら「今」まで。
({DateTime from, DateTime to}) dayRange(DateTime day, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final from = DateTime(day.year, day.month, day.day);
  var to = from.add(const Duration(days: 1)).subtract(const Duration(seconds: 1));
  if (to.isAfter(n)) to = n;
  return (from: from, to: to);
}

bool isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// 再生速度。1x = 1 秒に 2 地点進む（30 秒間隔の記録なら実時間の約 60 倍）
const replaySpeeds = [1, 2, 4, 8, 16];

double advanceCursor(double cursor, int speed, Duration tick) => cursor + speed * 2 * tick.inMilliseconds / 1000;

/// 走行時間の合計
Duration totalDriving(List<TripReport> trips) => trips.fold(Duration.zero, (sum, t) => sum + t.duration);

/// ルートの長さ（メートル）。地図に描いた線に沿って、隣り合う地点の距離を足す。
///
/// Traccar の集計（summary）の距離は、発信機が圏外のあいだにためた古い位置を後から送ると
/// 累計距離の順序が崩れてマイナスになることがあるため、画面ではこちらを使う。
double routeDistance(List<Position> route) {
  var total = 0.0;
  for (var i = 1; i < route.length; i++) {
    total += haversine(route[i - 1].latitude, route[i - 1].longitude, route[i].latitude, route[i].longitude);
  }
  return total;
}

/// 2 点間の距離（メートル、球面上の最短距離）
double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

/// GPX 1.1 形式（他の地図アプリで開ける）
String buildGpx(String name, List<Position> route) {
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="TrackOne Japan" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('  <trk>')
    ..writeln('    <name>${esc(name)}</name>')
    ..writeln('    <trkseg>');
  for (final p in route) {
    b.write('      <trkpt lat="${p.latitude.toStringAsFixed(6)}" lon="${p.longitude.toStringAsFixed(6)}">');
    if (p.fixTime != null) b.write('<time>${p.fixTime!.toUtc().toIso8601String()}</time>');
    b.writeln('</trkpt>');
  }
  b
    ..writeln('    </trkseg>')
    ..writeln('  </trk>')
    ..writeln('</gpx>');
  return b.toString();
}

/// ファイル名に使えない文字を除く
String safeFileName(String s) {
  final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
  return cleaned.isEmpty ? 'device' : cleaned;
}
