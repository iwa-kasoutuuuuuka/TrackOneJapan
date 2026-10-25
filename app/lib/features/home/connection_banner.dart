import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/clock.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../core/units.dart';

/// サーバーとの接続が切れているときの表示（地図の左上・一覧の上）
///
/// 切れてからの時間と、待たずにつなぎ直す「今すぐ再接続」ボタンを出す。
/// 表示中の位置は切れる前のものなので、「最終更新」の時刻で古さがわかる。
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key, this.compact = false});

  /// 地図の上に重ねる小さい表示
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(trackingProvider);
    ref.watch(clockProvider); // 「〇分前から」を更新
    if (s.connected || s.loading) return const SizedBox.shrink();
    final since = s.disconnectedAt;
    final recent = since == null || DateTime.now().difference(since).inMinutes < 1;
    final message = recent ? 'サーバーにつながりません' : 'サーバーにつながりません（${Units.ago(since)}から）';
    return Container(
      margin: compact ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: compact ? context.pal.card : context.pal.warnBg,
        borderRadius: BorderRadius.circular(10),
        boxShadow: compact ? const [BoxShadow(color: Colors.black26, blurRadius: 4)] : null,
      ),
      child: Row(mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max, children: [
        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 8),
        Flexible(
          fit: compact ? FlexFit.loose : FlexFit.tight,
          child: Text(
            compact ? '再接続中…' : '$message。再接続しています',
            style: TextStyle(fontSize: 12, color: context.pal.ink),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
          onPressed: () => ref.read(trackingProvider.notifier).reconnectNow(),
          child: const Text('今すぐ再接続', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}
