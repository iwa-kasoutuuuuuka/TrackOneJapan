import 'dart:io';
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
  Future<void>? _initFuture; // 同時に何度呼ばれても、初期化は 1 回だけ

  /// 通知をタップしたときに呼ばれる（引数はイベント ID）
  void Function(int eventId)? onTap;

  static const _channel = AndroidNotificationChannel(
    'alarms',
    'アラーム',
    description: 'SOS・エリアの出入り・速度超過などのアラーム',
    importance: Importance.high,
  );

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (kIsWeb) return;
    try {
      await _initPlugin();
    } catch (e) {
      // 通知が使えない環境でも、アプリ自体は動き続けるようにする
      debugPrint('通知の初期化に失敗しました: $e');
    }
  }

  Future<void> _initPlugin() async {
    await _plugin.initialize(
      settings: InitializationSettings(
        // オリジナルの通知アイコン（白一色のシルエット）
        android: const AndroidInitializationSettings('ic_stat_trackone'),
        iOS: const DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        // Windows 版（PC アプリ）：通知センターに出すアプリ名とオリジナルアイコン
        windows: WindowsInitializationSettings(
          appName: 'TrackOne Japan',
          appUserModelId: 'TrackOneJapan.App',
          guid: '6f0b6f3e-2a7c-4c1e-9b8e-3d5a1f2c7e41',
          iconPath: _windowsIconPath(),
        ),
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

  /// Windows 版：実行ファイルと一緒に配置されるアイコン画像の場所
  static String? _windowsIconPath() {
    if (kIsWeb || !Platform.isWindows) return null;
    final dir = File(Platform.resolvedExecutable).parent.path;
    final path = '$dir\\data\\flutter_assets\\assets\\icon\\icon-512.png';
    return File(path).existsSync() ? path : null;
  }

  /// Android 13 以降は通知の許可が必要
  Future<bool> requestPermission() async {
    await init();
    if (!_ready) return false;
    try {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return granted ?? true;
    } catch (_) {
      return false;
    }
  }

  /// 表示中の通知をすべて消す（ログアウトしたとき）
  Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  Future<void> show({required int eventId, required String title, required String body}) async {
    await init();
    if (!_ready) return;
    try {
      await _show(eventId, title, body);
    } catch (e) {
      debugPrint('通知を表示できませんでした: $e');
    }
  }

  Future<void> _show(int eventId, String title, String body) async {
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
          // ロック画面で内容を隠す設定のスマホでは、端末名やアラームの内容を出さない
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }
}
