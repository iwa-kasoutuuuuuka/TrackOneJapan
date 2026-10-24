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
  }) => AlarmState(
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
  /// 既読時刻を保存するときの持ち主（サーバー＋ユーザー）
  String get _owner {
    final s = ref.read(authProvider).value;
    return s == null ? '' : '${s.server}#${s.user.id}';
  }

  // ログインし直しても同じインスタンスが使い回されるため、世代番号で古い処理の結果を捨てる
  int _gen = 0;
  bool _alive(int gen) => gen == _gen && ref.mounted;

  TraccarClient? get _client => ref.mounted ? ref.read(authProvider).value?.client : null;

  @override
  AlarmState build() {
    final gen = ++_gen;
    ref.onDispose(() => _gen++); // 破棄後に戻ってきた処理を無効にする
    final session = ref.watch(authProvider).value;
    if (session == null) return const AlarmState(loading: false);
    Future.microtask(() => _reload(gen));
    return const AlarmState();
  }

  Future<void> reload() => _reload(_gen);

  Future<void> _reload(int gen) async {
    final client = _client;
    if (client == null || !_alive(gen)) return;
    try {
      final store = ref.read(sessionStoreProvider);
      final owner = _owner;
      var stored = await store.readLastSeenEvents(owner);
      if (stored == null) {
        // 初めて使うときは、過去のアラームを未読にしない
        stored = DateTime.now();
        await store.saveLastSeenEvents(owner, stored);
      }
      final devices = await client.getDevices();
      final geofences = await client.getGeofences();
      final now = DateTime.now();
      final events = await client.getEvents(devices.map((d) => d.id).toList(), now.subtract(alarmLookBack), now);
      if (!_alive(gen)) return;
      final list = events.where((e) => !isQuietEvent(e.type)).toList()
        ..sort((a, b) => (b.eventTime ?? DateTime(0)).compareTo(a.eventTime ?? DateTime(0)));
      // 読み込み中に「既読」にされていたら、そちらを優先する（既読が戻らないように）
      final current = state.lastSeen;
      final lastSeen = (current != null && current.isAfter(stored)) ? current : stored;
      state = state.copyWith(
        events: list,
        geofences: {for (final g in geofences) g.id: g.name},
        deviceNames: {for (final d in devices) d.id: d.name},
        lastSeen: lastSeen,
        loading: false,
        clearError: true,
      );
    } on ApiException catch (e) {
      if (_alive(gen)) state = state.copyWith(loading: false, error: e.message);
    }
  }

  /// WebSocket で届いたイベントを追加し、スマホに通知する
  Future<void> addRealtime(List<TrackerEvent> incoming) async {
    final gen = _gen;
    final fresh = incoming.where((e) => !isQuietEvent(e.type) && state.byId(e.id) == null).toList();
    if (fresh.isEmpty) return;
    // 知らないエリアのイベントならエリア名を取り直す
    if (fresh.any((e) => e.geofenceId != 0 && !state.geofences.containsKey(e.geofenceId))) {
      try {
        final g = await _client?.getGeofences();
        if (g != null && _alive(gen)) state = state.copyWith(geofences: {for (final x in g) x.id: x.name});
      } catch (_) {}
    }
    if (!_alive(gen)) return;
    // 待っている間に同じイベントが入っていたら除く
    final toAdd = fresh.where((e) => state.byId(e.id) == null).toList();
    if (toAdd.isEmpty) return;
    state = state.copyWith(events: [...toAdd.reversed, ...state.events]);
    if (!await ref.read(sessionStoreProvider).readPhoneNotify() || !_alive(gen)) return;
    for (final e in toAdd) {
      if (!_alive(gen)) return;
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
    final gen = _gen;
    final now = DateTime.now();
    state = state.copyWith(lastSeen: now);
    await ref.read(sessionStoreProvider).saveLastSeenEvents(_owner, now);
    if (!_alive(gen)) return;
  }
}

final alarmProvider = NotifierProvider<AlarmNotifier, AlarmState>(AlarmNotifier.new);

/// 通知設定の状態（Traccar の通知設定のうち、全端末・web 配信のもの）
class NotificationSettingsState {
  const NotificationSettingsState({
    this.configs = const [],
    this.notificators = const [],
    this.loading = true,
    this.working = false,
    this.error,
  });
  final List<NotificationConfig> configs;
  final List<String> notificators;
  final bool loading;
  final bool working; // 変更中（ボタンの連打で同じ設定が二重にできないように）
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
  int _gen = 0;
  bool _alive(int gen) => gen == _gen && ref.mounted;

  TraccarClient? get _client => ref.mounted ? ref.read(authProvider).value?.client : null;

  @override
  NotificationSettingsState build() {
    final gen = ++_gen;
    ref.onDispose(() => _gen++);
    ref.watch(authProvider);
    Future.microtask(() => _reload(gen));
    return const NotificationSettingsState();
  }

  Future<void> reload() => _reload(_gen);

  Future<void> _reload(int gen) async {
    final client = _client;
    if (client == null || !_alive(gen)) return;
    try {
      var configs = await client.getNotifications();
      // 警報の種類が設定されていない「警報」の通知は何も届かないので、自動で直す（1 件ずつ。失敗しても他は続ける）
      var repaired = false;
      for (final c in configs.where((c) => c.missingAlarms)) {
        try {
          await client.repairAlarmNotification(c);
          repaired = true;
        } catch (_) {}
      }
      if (repaired) configs = await client.getNotifications();
      final notificators = await client.getNotificators();
      if (!_alive(gen)) return;
      state = NotificationSettingsState(configs: configs, notificators: notificators, loading: false);
    } on ApiException catch (e) {
      if (!_alive(gen)) return;
      state = NotificationSettingsState(configs: state.configs, notificators: state.notificators, loading: false, error: e.message);
    }
  }

  /// 使える通知方法：web（アプリへの即時配信）＋ firebase（サーバーで設定済みならプッシュ通知）
  List<String> get _methods => ['web', if (state.notificators.contains('firebase')) 'firebase'];

  void _setWorking(bool w) {
    if (!ref.mounted) return;
    state = NotificationSettingsState(
      configs: state.configs,
      notificators: state.notificators,
      loading: state.loading,
      working: w,
      error: state.error,
    );
  }

  Future<void> setEnabled(String type, bool on) async {
    final client = _client;
    if (client == null || state.working || state.loading) return;
    _setWorking(true);
    try {
      if (on) {
        if (!state.isOn(type)) await client.createNotification(type, _methods);
      } else {
        for (final c in state.configs.where((c) => c.type == type && c.always && c.hasWeb)) {
          await client.deleteNotification(c.id);
        }
      }
    } finally {
      await reload();
      _setWorking(false);
    }
  }

  Future<void> enableRecommended() async {
    final client = _client;
    // 読み込み前に押すと「全部オフ」に見えて二重に作ってしまうので、読み込み後だけ受け付ける
    if (client == null || state.working || state.loading) return;
    _setWorking(true);
    try {
      for (final t in notificationTypes.where((t) => t.recommended)) {
        if (!ref.mounted) return;
        if (!state.isOn(t.type)) await client.createNotification(t.type, _methods);
      }
    } finally {
      await reload();
      _setWorking(false);
    }
  }
}

final notificationSettingsProvider = NotifierProvider<NotificationSettingsNotifier, NotificationSettingsState>(
  NotificationSettingsNotifier.new,
);
