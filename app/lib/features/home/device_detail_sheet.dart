import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../core/units.dart';

/// 端末の詳細（段階1は表示のみ）
void showDeviceDetail(BuildContext context, WidgetRef ref, int deviceId) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => Consumer(builder: (context, ref, _) {
      final s = ref.watch(trackingProvider);
      final d = s.devices[deviceId];
      if (d == null) return const SizedBox.shrink();
      final p = s.positions[deviceId];
      final rows = <(String, String)>[
        ('名前', d.name),
        ('IMEI（識別子）', d.uniqueId),
        ('機種', d.model?.isNotEmpty == true ? d.model! : '—'),
        ('SIM の電話番号', d.phone?.isNotEmpty == true ? d.phone! : '—'),
        ('通信状態', d.isOnline ? 'オンライン' : 'オフライン'),
        ('最終通信', d.lastUpdate == null ? '—' : '${Units.dateTime(d.lastUpdate!)}（${Units.ago(d.lastUpdate!)}）'),
        if (p != null) ...[
          ('測位時刻', p.fixTime == null ? '—' : Units.dateTime(p.fixTime!)),
          ('緯度・経度', '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}'),
          ('速度', Units.speedKmh(p.speed)),
          ('衛星数', p.satellites?.toString() ?? '—'),
          if (p.attributes['totalDistance'] is num) ('総走行距離', Units.distanceKm((p.attributes['totalDistance'] as num).toDouble())),
        ],
      ];
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('端末の詳細', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 120, child: Text(r.$1, style: const TextStyle(color: AppColors.sub, fontSize: 13))),
                  Expanded(child: SelectableText(r.$2, style: const TextStyle(fontSize: 13.5))),
                ]),
              ),
            const SizedBox(height: 6),
            const Text('名前や種類の変更は次の開発段階で追加します。', style: TextStyle(fontSize: 11.5, color: AppColors.gray)),
          ]),
        ),
      );
    }),
  );
}
