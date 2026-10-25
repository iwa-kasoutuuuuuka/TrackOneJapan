import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/tracking.dart';
import '../../core/state/clock.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../commands/commands_page.dart';
import '../replay/replay_page.dart';
import '../share/share_sheet.dart';
import 'device_detail_sheet.dart';
import 'device_status.dart';

/// 地図の下に出る、選択中の端末のカード（TrackerOne のメイン画面下部に相当）
class DeviceCard extends ConsumerWidget {
  const DeviceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(trackingProvider);
    ref.watch(clockProvider); // 経過時間の表示を 30 秒ごとに更新
    final d = s.selected;
    if (d == null) {
      return const _CardShell(child: Padding(padding: EdgeInsets.all(20), child: Text('表示できる端末がありません。管理画面で端末を追加するか、管理者に割り当てを依頼してください。')));
    }
    final p = s.positions[d.id];
    final info = DeviceStatusInfo.of(d, p, s.stoppedSince[d.id]);
    final address = s.addresses[d.id];
    final updated = p?.fixTime ?? d.lastUpdate;
    final ignition = p?.ignition;
    final battery = p?.batteryLevel;

    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(d.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                StatusPill(info),
              ]),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => ref.read(trackingProvider.notifier).ensureAddress(d.id, force: true),
                child: Text(
                  p == null ? '位置情報がまだありません' : (address ?? '住所を取得中…'),
                  style: const TextStyle(fontSize: 13, color: AppColors.sub, height: 1.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  _Stat(label: 'GPS', value: gpsLabel(p), color: gpsColor(p)),
                  _Stat(label: 'エンジン', value: ignition == null ? '—' : (ignition ? 'ON' : 'OFF'), color: ignition == true ? AppColors.green : AppColors.ink),
                  _Stat(label: '電池', value: battery == null ? '—' : '${battery.round()}%', color: (battery ?? 100) < 20 ? AppColors.red : AppColors.ink),
                ]),
              ),
              const Divider(height: 1),
              const SizedBox(height: 6),
              Text(
                updated == null ? '最終更新 —' : '最終更新 ${Units.dateTime(updated)}（${Units.ago(updated)}）',
                style: const TextStyle(fontSize: 11.5, color: AppColors.gray),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
            child: Row(children: [
              _MenuButton(
                icon: Icons.history,
                label: '履歴再生',
                color: AppColors.teal,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReplayPage(deviceId: d.id))),
              ),
              _MenuButton(icon: Icons.article_outlined, label: '詳細', color: AppColors.navy, onTap: () => showDeviceDetail(context, ref, d.id)),
              _MenuButton(icon: Icons.share_outlined, label: '共有', color: const Color(0xFF3B82C4), onTap: () => showShareSheet(context, d.id, d.name)),
              _MenuButton(icon: Icons.terminal, label: 'コマンド', color: AppColors.red, onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommandsPage(deviceId: d.id)))),
            ]),
          ),
        ],
      ),
    );
  }

}

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 14, offset: Offset(0, -3))],
        ),
        // 横向き・文字を大きくした設定でもはみ出さないよう、高さを画面の 55% までにしてスクロールさせる
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * (MediaQuery.orientationOf(context) == Orientation.landscape ? 0.45 : 0.55)),
            child: SingleChildScrollView(child: child),
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.sub)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(13)),
                child: Icon(icon, color: Colors.white, size: 21),
              ),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 11, color: AppColors.sub)),
            ]),
          ),
        ),
      );
}
