/// 単位換算と日本語の表示形式
class Units {
  /// Traccar の速度はノット。km/h に換算する。
  static double knotsToKmh(double knots) => knots * 1.852;

  static String speedKmh(double knots) => '${knotsToKmh(knots).round()} km/h';

  static String distanceKm(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  /// 「23分」「2時間5分」「3日」のような長さの表示
  static String duration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    if (d.inMinutes < 1) return '1分未満';
    if (d.inHours < 1) return '${d.inMinutes}分';
    if (d.inDays < 1) {
      final m = d.inMinutes % 60;
      return m == 0 ? '${d.inHours}時間' : '${d.inHours}時間$m分';
    }
    return '${d.inDays}日';
  }

  /// 「たった今」「5分前」「3時間前」「2日前」
  static String ago(DateTime time, {DateTime? now}) {
    final d = (now ?? DateTime.now()).difference(time);
    if (d.inSeconds < 60) return 'たった今';
    if (d.inMinutes < 60) return '${d.inMinutes}分前';
    if (d.inHours < 24) return '${d.inHours}時間前';
    return '${d.inDays}日前';
  }

  static const _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

  /// 「12:34」（今日）／「10月23日（金）12:34」（それ以外）
  static String dateTime(DateTime t, {DateTime? now}) {
    final local = t.toLocal();
    final n = (now ?? DateTime.now()).toLocal();
    final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final sameDay = local.year == n.year && local.month == n.month && local.day == n.day;
    if (sameDay) return hm;
    return '${local.month}月${local.day}日（${_weekdays[local.weekday - 1]}）$hm';
  }
}
