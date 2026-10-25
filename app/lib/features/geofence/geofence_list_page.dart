import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geofence_shape.dart';
import '../../core/state/alarms.dart';
import '../../core/state/geofences.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import 'geofence_edit_page.dart';

/// エリア（ジオフェンス）一覧（TrackerOne の ElectricFence に相当）
class GeofenceListPage extends ConsumerWidget {
  const GeofenceListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(geofenceProvider);
    final devices = ref.watch(trackingProvider.select((t) => t.devices));
    final notify = ref.watch(notificationSettingsProvider);
    final notifyOff = !notify.loading && !notify.isOn('geofenceEnter') && !notify.isOn('geofenceExit');

    return Scaffold(
      backgroundColor: context.pal.surface,
      appBar: AppBar(title: const Text('エリア（ジオフェンス）')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('エリアを追加'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GeofenceEditPage())),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(geofenceProvider.notifier).reload(),
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), children: [
          if (notifyOff)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(color: context.pal.warnBg, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.notifications_off_outlined, color: Color(0xFFB86200)),
                const SizedBox(width: 10),
                const Expanded(child: Text('エリアに入った・出たときの通知がオフです。', style: TextStyle(fontSize: 12.5))),
                TextButton(
                  onPressed: notify.working
                      ? null
                      : () async {
                          final n = ref.read(notificationSettingsProvider.notifier);
                          await n.setEnabled('geofenceEnter', true);
                          await n.setEnabled('geofenceExit', true);
                        },
                  child: const Text('オンにする'),
                ),
              ]),
            ),
          if (s.loading)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (s.geofences.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 60, 24, 24),
              child: Column(children: [
                const Icon(Icons.radar, size: 52, color: AppColors.gray),
                const SizedBox(height: 12),
                Text(s.error ?? 'エリアはまだありません', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  '自宅や職場などをエリアとして登録すると、発信機がそのエリアに入ったとき・出たときに通知が届きます。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: context.pal.sub, height: 1.6),
                ),
              ]),
            )
          else
            for (final g in s.geofences)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: context.pal.card,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GeofenceEditPage(geofence: g))),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: const Color(0xFF3B82C4), borderRadius: BorderRadius.circular(13)),
                          child: Icon(GeofenceShape.parse(g.area) is PolygonShape ? Icons.pentagon_outlined : Icons.radio_button_unchecked,
                              color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(g.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(_shapeLabel(g.area), style: TextStyle(fontSize: 12, color: context.pal.sub)),
                            const SizedBox(height: 2),
                            Text(
                              _targets(s.devicesOf(g.id).map((id) => devices[id]?.name).whereType<String>().toList()),
                              style: const TextStyle(fontSize: 11.5, color: AppColors.gray),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ]),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.gray),
                      ]),
                    ),
                  ),
                ),
              ),
        ]),
      ),
    );
  }

  static String _shapeLabel(String area) {
    final shape = GeofenceShape.parse(area);
    return switch (shape) {
      CircleShape c => '円・半径 ${formatRadius(c.radius)}',
      PolygonShape p => '多角形・${p.points.length} 点',
      null => 'アプリでは編集できない形（管理画面で編集）',
    };
  }

  static String _targets(List<String> names) => names.isEmpty ? '対象の端末：なし（通知は届きません）' : '対象の端末：${names.join('、')}';
}
