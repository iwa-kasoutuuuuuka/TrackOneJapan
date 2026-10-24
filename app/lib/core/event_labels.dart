import 'package:flutter/material.dart';

import '../models/models.dart';
import 'theme.dart';
import 'units.dart';

/// アラームの分類（一覧の絞り込みと色分けに使う）
enum EventCategory {
  emergency('緊急', AppColors.red, Icons.warning_amber_rounded),
  geofence('エリア', Color(0xFF3B82C4), Icons.radar),
  speed('速度', AppColors.orange, Icons.speed),
  power('電源', AppColors.orange, Icons.bolt),
  engine('エンジン', AppColors.navy, Icons.key),
  connection('通信', AppColors.gray, Icons.wifi_off),
  motion('移動', AppColors.teal, Icons.directions_car),
  other('その他', Color(0xFF7A8599), Icons.notifications);

  const EventCategory(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}

/// イベントの日本語表示
class EventInfo {
  const EventInfo(this.title, this.category, {this.icon});
  final String title;
  final EventCategory category;
  final IconData? icon;

  Color get color => category.color;
  IconData get displayIcon => icon ?? category.icon;
}

/// 移動開始・停車は件数が多いため、アラーム一覧・未読数・通知の対象から外す
bool isQuietEvent(String type) => type == 'deviceMoving' || type == 'deviceStopped';

const _alarmLabels = <String, (String, EventCategory, IconData?)>{
  'sos': ('SOS', EventCategory.emergency, Icons.sos),
  'fallDown': ('転倒を検知', EventCategory.emergency, null),
  'accident': ('事故を検知', EventCategory.emergency, null),
  'tow': ('けん引を検知', EventCategory.emergency, null),
  'tampering': ('いたずらを検知', EventCategory.emergency, null),
  'removing': ('取り外しを検知', EventCategory.emergency, null),
  'gpsAntennaCut': ('GPS アンテナが外れました', EventCategory.emergency, null),
  'jamming': ('電波妨害を検知', EventCategory.emergency, null),
  'vibration': ('振動を検知', EventCategory.other, Icons.vibration),
  'movement': ('動きを検知', EventCategory.other, Icons.directions_run),
  'overspeed': ('速度超過', EventCategory.speed, null),
  'lowspeed': ('低速', EventCategory.speed, null),
  'powerCut': ('電源が切断されました', EventCategory.power, Icons.power_off),
  'powerRestored': ('電源が復旧しました', EventCategory.power, Icons.power),
  'powerOff': ('電源オフ', EventCategory.power, Icons.power_settings_new),
  'powerOn': ('電源オン', EventCategory.power, Icons.power_settings_new),
  'lowPower': ('外部電源の電圧が低下', EventCategory.power, null),
  'lowBattery': ('電池残量が低下', EventCategory.power, Icons.battery_alert),
  'door': ('ドアの開閉', EventCategory.other, Icons.sensor_door_outlined),
  'lock': ('施錠', EventCategory.other, Icons.lock_outline),
  'unlock': ('解錠', EventCategory.other, Icons.lock_open),
  'geofence': ('エリアの警報', EventCategory.geofence, null),
  'geofenceEnter': ('エリアに入りました', EventCategory.geofence, null),
  'geofenceExit': ('エリアから出ました', EventCategory.geofence, null),
  'idle': ('アイドリング', EventCategory.engine, null),
  'hardAcceleration': ('急加速', EventCategory.speed, null),
  'hardBraking': ('急ブレーキ', EventCategory.speed, null),
  'hardCornering': ('急ハンドル', EventCategory.speed, null),
  'fatigueDriving': ('長時間運転', EventCategory.other, null),
  'temperature': ('温度の異常', EventCategory.other, Icons.thermostat),
  'parking': ('駐車中の異常', EventCategory.other, null),
  'fault': ('故障', EventCategory.other, Icons.build_outlined),
};

/// Traccar のイベントを日本語にする
EventInfo describeEvent(TrackerEvent e, {String? geofenceName}) {
  final area = (geofenceName == null || geofenceName.isEmpty) ? 'エリア' : '「$geofenceName」エリア';
  switch (e.type) {
    case 'alarm':
      final a = e.alarm ?? '';
      final hit = _alarmLabels[a];
      if (hit != null) return EventInfo(hit.$1, hit.$2, icon: hit.$3);
      return EventInfo(a.isEmpty ? '警報' : '警報（$a）', EventCategory.emergency);
    case 'geofenceEnter':
      return EventInfo('$areaに入りました', EventCategory.geofence, icon: Icons.login);
    case 'geofenceExit':
      return EventInfo('$areaから出ました', EventCategory.geofence, icon: Icons.logout);
    case 'geofenceCrossed':
      return EventInfo('$areaを通過しました', EventCategory.geofence);
    case 'deviceOverspeed':
      final speed = (e.attributes['speed'] as num?)?.toDouble();
      return EventInfo(speed == null ? '速度超過' : '速度超過（${Units.speedKmh(speed)}）', EventCategory.speed);
    case 'deviceOnline':
      return const EventInfo('通信を再開しました', EventCategory.connection, icon: Icons.wifi);
    case 'deviceOffline':
      return const EventInfo('通信が途絶えました', EventCategory.connection);
    case 'deviceUnknown':
      return const EventInfo('通信状態が不明です', EventCategory.connection);
    case 'deviceInactive':
      return const EventInfo('長期間通信がありません', EventCategory.connection);
    case 'deviceMoving':
      return const EventInfo('移動を開始しました', EventCategory.motion);
    case 'deviceStopped':
      return const EventInfo('停車しました', EventCategory.motion, icon: Icons.local_parking);
    case 'ignitionOn':
      return const EventInfo('エンジン ON', EventCategory.engine);
    case 'ignitionOff':
      return const EventInfo('エンジン OFF', EventCategory.engine, icon: Icons.key_off);
    case 'commandResult':
      final r = e.attributes['result'];
      return EventInfo(r == null ? 'コマンドの結果を受信' : 'コマンドの結果：$r', EventCategory.other, icon: Icons.terminal);
    case 'queuedCommandSent':
      return const EventInfo('保留中のコマンドを送信しました', EventCategory.other, icon: Icons.terminal);
    case 'deviceFuelDrop':
      return const EventInfo('燃料が急に減りました', EventCategory.other, icon: Icons.local_gas_station);
    case 'deviceFuelIncrease':
      return const EventInfo('給油しました', EventCategory.other, icon: Icons.local_gas_station);
    case 'maintenance':
      return const EventInfo('点検の時期です', EventCategory.other, icon: Icons.build_outlined);
    case 'driverChanged':
      return const EventInfo('ドライバーが変わりました', EventCategory.other, icon: Icons.badge_outlined);
    case 'media':
      return const EventInfo('写真・動画を受信しました', EventCategory.other, icon: Icons.photo_camera_outlined);
    case 'textMessage':
      return const EventInfo('メッセージを受信しました', EventCategory.other, icon: Icons.sms_outlined);
    default:
      return EventInfo(e.type, EventCategory.other);
  }
}

/// 通知設定の画面に並べる種類（Traccar の通知タイプ → 日本語）
class NotificationTypeInfo {
  const NotificationTypeInfo(this.type, this.label, this.description, {this.recommended = false});
  final String type;
  final String label;
  final String description;
  final bool recommended;
}

const notificationTypes = <NotificationTypeInfo>[
  NotificationTypeInfo('alarm', '警報', 'SOS・振動・電源切断・電池低下・取り外しなど、発信機が送る警報', recommended: true),
  NotificationTypeInfo('geofenceEnter', 'エリアに入ったとき', '登録したエリア（ジオフェンス）に入ったとき', recommended: true),
  NotificationTypeInfo('geofenceExit', 'エリアから出たとき', '登録したエリア（ジオフェンス）から出たとき', recommended: true),
  NotificationTypeInfo('deviceOverspeed', '速度超過', '端末に設定した制限速度を超えたとき', recommended: true),
  NotificationTypeInfo('deviceOffline', '通信が途絶えたとき', '発信機から一定時間通信がないとき', recommended: true),
  NotificationTypeInfo('deviceOnline', '通信を再開したとき', '発信機の通信が戻ったとき'),
  NotificationTypeInfo('ignitionOn', 'エンジン ON', 'エンジンがかかったとき（ACC 線の接続が必要）'),
  NotificationTypeInfo('ignitionOff', 'エンジン OFF', 'エンジンが切れたとき（ACC 線の接続が必要）'),
  NotificationTypeInfo('commandResult', 'コマンドの結果', '発信機からコマンドの返事が届いたとき'),
];

/// 日付の見出し（「今日　10月24日（土）」など）
String dayHeader(DateTime t, {DateTime? now}) {
  const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  final n = now ?? DateTime.now();
  final d = DateTime(t.year, t.month, t.day);
  final today = DateTime(n.year, n.month, n.day);
  final label = '${t.month}月${t.day}日（${weekdays[t.weekday - 1]}）';
  final diff = today.difference(d).inDays;
  if (diff == 0) return '今日　$label';
  if (diff == 1) return '昨日　$label';
  return label;
}
