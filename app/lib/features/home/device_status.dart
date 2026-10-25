import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/units.dart';
import '../../models/models.dart';

/// 最後の位置がこれより古ければ、「走行中」の表示をやめて停車中とみなす
const staleMotionAfter = Duration(minutes: 5);

/// 端末の状態（走行中・停車中・オフライン）と表示色
class DeviceStatusInfo {
  DeviceStatusInfo(this.label, this.color, this.background);
  final String label;
  final Color color;
  final Color background;

  static DeviceStatusInfo of(Device device, Position? position, DateTime? stoppedSince, {DateTime? now}) {
    final n = now ?? DateTime.now();
    if (device.disabled) {
      return DeviceStatusInfo('無効', AppColors.gray, const Color(0xFFECEEF2));
    }
    if (!device.isOnline) {
      return DeviceStatusInfo('オフライン', AppColors.gray, const Color(0xFFECEEF2));
    }
    // 止まると位置を送らなくなる発信機（GT06 系に多い）では、最後の位置が「走行中」のまま残る。
    // 最後の位置から一定時間たっていたら、止まったものとみなす。
    final fix = position?.fixTime;
    final stale = fix != null && n.difference(fix) > staleMotionAfter;
    if (position?.motion == true && !stale) {
      return DeviceStatusInfo('走行中 ${Units.speedKmh(position!.speed)}', AppColors.green, const Color(0xFFDDF5E6));
    }
    final since = stoppedSince ?? (position?.motion == true && stale ? fix : null);
    final label = since == null ? '停車中' : '停車中 ${Units.duration(n.difference(since))}';
    return DeviceStatusInfo(label, const Color(0xFFB86200), const Color(0xFFFFF1DB));
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.info, {super.key});
  final DeviceStatusInfo info;

  @override
  Widget build(BuildContext context) {
    // 暗い画面では、薄い背景色の代わりに文字色を透かした背景にし、文字を少し明るくする
    final dark = context.isDark;
    final fg = dark ? Color.lerp(info.color, Colors.white, 0.25)! : info.color;
    final bg = dark ? info.color.withValues(alpha: 0.22) : info.background;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(info.label, style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

/// 端末の種類（Traccar の category）→ マーカー画像と色
class DeviceKind {
  const DeviceKind(this.asset, this.color, this.icon);
  final String asset;
  final Color color;
  final IconData icon;

  static DeviceKind of(String? category) {
    switch (category) {
      case 'car':
      case 'pickup':
      case 'van':
      case 'truck':
      case 'bus':
      case 'offroad':
      case 'camper':
        return const DeviceKind('assets/markers/car.png', AppColors.navy, Icons.directions_car_filled);
      case 'motorcycle':
      case 'scooter':
      case 'bicycle':
        return const DeviceKind('assets/markers/motorcycle.png', AppColors.teal, Icons.two_wheeler);
      case 'person':
        return const DeviceKind('assets/markers/person.png', AppColors.red, Icons.person);
      case 'animal':
        return const DeviceKind('assets/markers/pet.png', AppColors.orange, Icons.pets);
      default:
        return const DeviceKind('assets/markers/package.png', Color(0xFF7A8599), Icons.inventory_2);
    }
  }
}

/// GPS の受信状態
String gpsLabel(Position? p) {
  if (p == null) return '—';
  if (!p.valid) return '測位なし';
  final sat = p.satellites;
  if (sat == null) return '受信中';
  if (sat >= 8) return '良好';
  if (sat >= 4) return '普通';
  return '弱い';
}

/// GPS の表示色。[ink] は普通のときの文字色（画面では `context.pal.ink` を渡す）
Color gpsColor(Position? p, {Color ink = AppColors.ink}) {
  final l = gpsLabel(p);
  if (l == '—') return AppColors.gray; // データなし
  if (l == '良好') return AppColors.green;
  if (l == '普通' || l == '受信中') return ink;
  return AppColors.red;
}
