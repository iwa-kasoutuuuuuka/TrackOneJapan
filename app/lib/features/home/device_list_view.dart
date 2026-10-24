import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/tracking.dart';
import '../../core/state/clock.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import 'device_status.dart';

/// 端末一覧（TrackerOne の list タブに相当）
class DeviceListView extends ConsumerStatefulWidget {
  const DeviceListView({super.key, required this.onOpenOnMap});
  final VoidCallback onOpenOnMap;

  @override
  ConsumerState<DeviceListView> createState() => _DeviceListViewState();
}

class _DeviceListViewState extends ConsumerState<DeviceListView> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(trackingProvider);
    ref.watch(clockProvider); // 経過時間の表示を 30 秒ごとに更新
    final notifier = ref.read(trackingProvider.notifier);
    final devices = s.sortedDevices.where((d) => _query.isEmpty || d.name.contains(_query) || d.uniqueId.contains(_query)).toList();

    return Container(
      color: AppColors.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: InputDecoration(
              hintText: '端末を検索（名前・IMEI）',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: notifier.reload,
            child: devices.isEmpty
                ? ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Center(child: Text('端末がありません')))])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    itemCount: devices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 9),
                    itemBuilder: (context, i) {
                      final d = devices[i];
                      final p = s.positions[d.id];
                      final info = DeviceStatusInfo.of(d, p, s.stoppedSince[d.id]);
                      final kind = DeviceKind.of(d.category);
                      final updated = p?.fixTime ?? d.lastUpdate;
                      // 画面の描画中に状態を変えないよう、描画後に住所を取りに行く
                      if (s.addresses[d.id] == null && p != null) Future.microtask(() => notifier.ensureAddress(d.id));
                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            notifier.select(d.id);
                            widget.onOpenOnMap();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(color: d.isOnline ? kind.color : AppColors.gray, borderRadius: BorderRadius.circular(13)),
                                child: Icon(kind.icon, color: Colors.white),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Expanded(child: Text(d.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                                    StatusPill(info),
                                  ]),
                                  const SizedBox(height: 4),
                                  Text(s.addresses[d.id] ?? (p == null ? '位置情報なし' : '住所を取得中…'),
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.sub)),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (p?.batteryLevel != null) '電池 ${p!.batteryLevel!.round()}%',
                                      if (p?.ignition != null) 'エンジン ${p!.ignition! ? 'ON' : 'OFF'}',
                                      if (updated != null) Units.ago(updated),
                                    ].join('　'),
                                    style: const TextStyle(fontSize: 11, color: AppColors.gray),
                                  ),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}
