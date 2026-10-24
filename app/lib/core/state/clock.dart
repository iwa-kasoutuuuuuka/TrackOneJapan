import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 30 秒ごとに「今」を知らせる。
/// 「たった今」「5分前」「停車中 23分」など、時間とともに変わる表示を描き直すために使う
/// （新しいデータが届かなくても表示が古いままにならないように）。
final clockProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(seconds: 30), (_) => DateTime.now());
});
