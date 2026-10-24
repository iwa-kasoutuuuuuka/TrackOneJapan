import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../api/traccar_client.dart';
import '../event_labels.dart';
import '../notifications/phone_notifier.dart';
import 'auth.dart';

/// アラーム一覧の状態
class AlarmState {
  const AlarmState({
    this.events = const [],
    this.geofences = const {},
    this.deviceNames = const {},
    this.lastSeen,
    this.loading = true,
    this.error,
  });

  final List<TrackerEvent> events; // 新しい順。移動開始・停車は含めない
  final Map<int, String> geofences; // id -> 名前
  final Map<int, String> deviceNames;
  final DateTime? lastSeen;
  final bool loading;
  final String? error;

  int get unreadCount => events.where(isUnread).length;
  bool isUnread(TrackerEvent e) => lastSeen == null || (e.eventTime != null && e.eventTime!.isAfter(lastSeen!));

  String? geofenceName(TrackerEvent e) => geofences[e.geofenceId];
  String deviceName(int id) => deviceNames[id] ?? '端末';
  TrackerEvent? byId(int id) {
    for (final e in events) {
      if (e.id == id) return e;
    }
    return null;
  }

  AlarmState copyWith({
    List<TrackerEvent>? events,
    Map<int, String>? geofences,
    Map<int, String>? deviceNames,
    DateTime? lastSeen,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      AlarmState(
        events: events ?? this.events,
        geofences: geofences ?? this.geofences,
        deviceNames: deviceNames ?? this.deviceNames,
        lastSeen: lastSeen ?? this.lastSeen,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 一覧に表示する期間
const alarmLookBack = Duration(days: 7);

class AlarmNotifier extends Notifier<AlarmState> {
  bool _disposed = false;

  TraccarClient? get _client => ref.read(authProvider).value?.client;

  @override
  AlarmState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final session = ref.watch(authProvider).value;
    if (session == null) return const AlarmState(loading: false);
    Future.microtask(reload);
    return const AlarmState();
  }

  Future<void> reload() async {
    final client = _client;
    if (client == null) return;
    try {
      final store = ref.read(sessionStoreProvider);
      var lastSeen = await store.readLastSeenEvents();
      if (lastSeen == null) {
        // 初めて使うときは、過去のアラームを未読にしない
        lastSeen = DateTime.now();
        await store.saveLastSeenEvents(lastSeen);
      }
      final devices = await client.getDevices();
      final geofences = await client.getGeofences();
      final now = DateTime.now();
      final events = await client.getEvents(devices.map((d) => d.id).toList(), now.subtract(alarmLookBack), now);
      if (_disposed) return;
      final list = events.where((e) => !isQuietEvent(e.type)).toList()
        ..sort((a, b) => (b.eventTime ?? DateTime(0)).compareTo(a.eventTime ?? DateTime(0)));
      state = state.copyWith(
        events: list,
        geofences: {for (final g in geofences) g.id: g.name},
        deviceNames: {for (final d in devices) d.id: d.name},
        lastSeen: lastSeen,
        loading: false,
        clearError: true,
      );
    } on ApiException catch (e) {
      if (!_disposed) state = state.copyWith(loading: false, error: e.message);
    }
  }

  /// WebSocket で届いたイベントを追加し、スマホに通知する
  Future<void> addRealtime(List<TrackerEvent> incoming) async {
    final fresh = incoming.where((e) => !isQuietEvent(e.type) && state.byId(e.id) == null).toList();
    if (fresh.isEmpty || _disposed) return;
    // 知らないエリアのイベントならエリア名を取り直す
    if (fresh.any((e) => e.geofenceId != 0 && !state.geofences.containsKey(e.geofenceId))) {
      try {
        final g = await _client?.getGeofences();
        if (g != null) state = state.copyWith(geofences: {for (final x in g) x.id: x.name});
      } catch (_) {}
    }
    state = state.copyWith(events: [...fresh.reversed, ...state.events]);
    if (!await ref.read(sessionStoreProvider).readPhoneNotify()) return;
    for (final e in fresh) {
      final info = describeEvent(e, geofenceName: state.geofenceName(e));
      await PhoneNotifier.instance.show(eventId: e.id, title: '${state.deviceName(e.deviceId)}：${info.title}', body: 'タップして詳細を表示');
    }
  }

  void updateDeviceNames(Map<int, String> names) {
    if (names.isEmpty) return;
    state = state.copyWith(deviceNames: {...state.deviceNames, ...names});
  }

  /// すべて既読にする（アラーム一覧を開いたとき）
  Future<void> markAllRead() async {
    final now = DateTime.now();
    await ref.read(sessionStoreProvider).saveLastSeenEvents(now);
    if (!_disposed) state = state.copyWith(lastSeen: now);
  }
}

final alarmProvider = NotifierProvider<AlarmNotifier, AlarmState>(AlarmNotifier.new);

/// 通知設定の状態（Traccar の通知設定のうち、全端末・web 配信のもの）
class NotificationSettingsState {
  const NotificationSettingsState({this.configs = const [], this.notificators = const [], this.loading = true, this.error});
  final List<NotificationConfig> configs;
  final List<String> notificators;
  final bool loading;
  final String? error;

  NotificationConfig? configFor(String type) {
    for (final c in configs) {
      if (c.type == type && c.always && c.hasWeb) return c;
    }
    return null;
  }

  bool isOn(String type) => configFor(type) != null;
}

class NotificationSettingsNotifier extends Notifier<NotificationSettingsState> {
  TraccarClient? get _client => ref.read(authProvider).value?.client;

  @override
  NotificationSettingsState build() {
    ref.watch(authProvider);
    Future.microtask(reload);
    return const NotificationSettingsState();
  }

  Future<void> reload() async {
    final client = _client;
    if (client == null) return;
    try {
      var configs = await client.getNotifications();
      // 警報の種類が設定されていない「警報」の通知は何も届かないので、自動で直す
      final broken = configs.where((c) => c.missingAlarms).toList();
      if (broken.isNotEmpty) {
        for (final c in broken) {
          await client.repairAlarmNotification(c);
        }
        configs = await client.getNotifications();
      }
      final notificators = await client.getNotificators();
      state = NotificationSettingsState(configs: configs, notificators: notificators, loading: false);
    } on ApiException catch (e) {
      state = NotificationSettingsState(configs: state.configs, notificators: state.notificators, loading: false, error: e.message);
    }
  }

  /// 使える通知方法：web（アプリへの即時配信）＋ firebase（サーバーで設定済みならプッシュ通知）
  List<String> get _methods => ['web', if (state.notificators.contains('firebase')) 'firebase'];

  Future<void> setEnabled(String type, bool on) async {
    final client = _client;
    if (client == null) return;
    if (on) {
      if (!state.isOn(type)) await client.createNotification(type, _methods);
    } else {
      for (final c in state.configs.where((c) => c.type == type && c.always && c.hasWeb)) {
        await client.deleteNotification(c.id);
      }
    }
    await reload();
  }

  Future<void> enableRecommended() async {
    for (final t in notificationTypes.where((t) => t.recommended)) {
      if (!state.isOn(t.type)) await _client?.createNotification(t.type, _methods);
    }
    await reload();
  }
}

final notificationSettingsProvider =
    NotifierProvider<NotificationSettingsNotifier, NotificationSettingsState>(NotificationSettingsNotifier.new);
