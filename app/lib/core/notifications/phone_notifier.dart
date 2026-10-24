import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// スマホの通知欄にアラームを出す（アプリが動いている間）
///
/// アプリを完全に閉じているときの通知（プッシュ通知）は Firebase の設定が必要。
class PhoneNotifier {
  PhoneNotifier._();
  static final instance = PhoneNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// 通知をタップしたときに呼ばれる（引数はイベント ID）
  void Function(int eventId)? onTap;

  static const _channel = AndroidNotificationChannel(
    'alarms',
    'アラーム',
    description: 'SOS・エリアの出入り・速度超過などのアラーム',
    importance: Importance.high,
  );

  Future<void> init() async {
    if (_ready || kIsWeb) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        // オリジナルの通知アイコン（白一色のシルエット）
        android: AndroidInitializationSettings('ic_stat_trackone'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
      onDidReceiveNotificationResponse: (r) {
        final id = int.tryParse(r.payload ?? '');
        if (id != null) onTap?.call(id);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    _ready = true;

    // 通知をタップしてアプリが起動した場合
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && payload != null) {
      final id = int.tryParse(payload);
      if (id != null) Future.delayed(const Duration(seconds: 1), () => onTap?.call(id));
    }
  }

  /// Android 13 以降は通知の許可が必要
  Future<bool> requestPermission() async {
    await init();
    final granted = await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    return granted ?? true;
  }

  Future<void> show({required int eventId, required String title, required String body}) async {
    await init();
    await _plugin.show(
      id: eventId & 0x7fffffff,
      title: title,
      body: body,
      payload: '$eventId',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          color: const Color(0xFF1F4A85),
          category: AndroidNotificationCategory.event,
        ),
      ),
    );
  }
}
