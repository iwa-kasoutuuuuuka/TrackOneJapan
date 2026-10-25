import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../api/traccar_client.dart';
import 'alarms.dart';
import 'auth.dart';

/// 端末・最新位置・停車開始時刻・住所をまとめた状態
class TrackingState {
  const TrackingState({
    this.devices = const {},
    this.positions = const {},
    this.stoppedSince = const {},
    this.addresses = const {},
    this.selectedId,
    this.loading = true,
    this.connected = false,
    this.disconnectedAt,
    this.error,
  });

  final Map<int, Device> devices;
  final Map<int, Position> positions; // deviceId -> 最新位置
  final Map<int, DateTime?> stoppedSince; // deviceId -> 停車開始（走行中なら null）
  final Map<int, String> addresses; // deviceId -> 住所
  final int? selectedId;
  final bool loading;
  final bool connected;

  /// サーバーとの接続が切れた時刻（つながっている間は null）
  final DateTime? disconnectedAt;
  final String? error;

  List<Device> get sortedDevices => devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  Device? get selected => selectedId == null ? null : devices[selectedId];

  TrackingState copyWith({
    Map<int, Device>? devices,
    Map<int, Position>? positions,
    Map<int, DateTime?>? stoppedSince,
    Map<int, String>? addresses,
    int? selectedId,
    bool clearSelected = false,
    bool? loading,
    bool? connected,
    DateTime? disconnectedAt,
    bool clearDisconnectedAt = false,
    String? error,
    bool clearError = false,
  }) =>
      TrackingState(
        devices: devices ?? this.devices,
        positions: positions ?? this.positions,
        stoppedSince: stoppedSince ?? this.stoppedSince,
        addresses: addresses ?? this.addresses,
        selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
        loading: loading ?? this.loading,
        connected: connected ?? this.connected,
        disconnectedAt: clearDisconnectedAt ? null : (disconnectedAt ?? this.disconnectedAt),
        error: clearError ? null : (error ?? this.error),
      );
}

class TrackingNotifier extends Notifier<TrackingState> {
  // Riverpod 3 では、ログインし直しても同じインスタンスが使い回される。
  // そのため「どのログインのときに始めた処理か」を世代番号で見分け、
  // 古い処理の結果が新しいログインの画面に混ざらないようにする。
  int _gen = 0;
  bool _alive(int gen) => gen == _gen && ref.mounted;

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _connecting = false;
  bool _everConnected = false;

  final Map<int, ({double lat, double lon})> _geocodedAt = {};
  final Map<int, DateTime> _geocodeFailedAt = {};
  final Set<int> _geocodeQueued = {};
  final Queue<int> _geocodeQueue = Queue();
  bool _geocodeRunning = false;
  final Map<int, DateTime> _stopRefreshedAt = {};
  AppLifecycleListener? _lifecycle;

  static bool get _hasBinding {
    try {
      WidgetsBinding.instance; // 単体テストなど、画面のない環境では作らない
      return true;
    } catch (_) {
      return false;
    }
  }

  TraccarClient? get _client => ref.mounted ? ref.read(authProvider).value?.client : null;

  @override
  TrackingState build() {
    final gen = ++_gen;
    ref.onDispose(() {
      _gen++; // 破棄後に戻ってきた処理を無効にする
      _sub?.cancel();
      _sub = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _lifecycle?.dispose();
      _lifecycle = null;
    });
    // スマホがスリープから戻ったとき・アプリを開き直したときは、待たずにすぐ最新にする
    _lifecycle?.dispose();
    _lifecycle = !_hasBinding ? null : AppLifecycleListener(onResume: () {
      if (!_alive(gen)) return;
      if (state.connected) {
        _reload(gen);
      } else {
        reconnectNow();
      }
    });
    _retryCount = 0;
    _connecting = false;
    _everConnected = false;
    _geocodedAt.clear();
    _geocodeFailedAt.clear();
    _geocodeQueued.clear();
    _geocodeQueue.clear();
    _stopRefreshedAt.clear();

    // ログインしている間だけ動く
    final session = ref.watch(authProvider).value;
    if (session == null) return const TrackingState(loading: false);
    Future.microtask(() => _start(gen));
    return const TrackingState();
  }

  Future<void> _start(int gen) async {
    await _reload(gen);
    await _connect(gen);
  }

  /// 端末一覧・最新位置・停車開始時刻を読み直す（引っ張って更新など）
  Future<void> reload() => _reload(_gen);

  Future<void> _reload(int gen) async {
    final client = _client;
    if (client == null || !_alive(gen)) return;
    try {
      final devices = await client.getDevices();
      final positions = await client.getPositions();
      if (!_alive(gen)) return;
      final devMap = {for (final d in devices) d.id: d};
      final posMap = {for (final p in positions) p.deviceId: p};
      // 選択中の端末が削除されていたら、先頭の端末を選び直す
      var selected = state.selectedId;
      if (selected == null || !devMap.containsKey(selected)) {
        selected = devices.isEmpty ? null : (devices.toList()..sort((a, b) => a.name.compareTo(b.name))).first.id;
      }
      state = state.copyWith(
        devices: devMap,
        positions: posMap,
        selectedId: selected,
        clearSelected: selected == null,
        loading: false,
        clearError: true,
      );
      ref.read(alarmProvider.notifier).updateDeviceNames({for (final d in devices) d.id: d.name});
      await _loadStoppedSince(gen, devices.map((d) => d.id));
      if (selected != null) ensureAddress(selected);
    } on ApiException catch (e) {
      if (_alive(gen)) state = state.copyWith(loading: false, error: e.message);
    }
  }

  Future<void> _loadStoppedSince(int gen, Iterable<int> deviceIds) async {
    final client = _client;
    if (client == null) return;
    final fetched = <int, DateTime?>{};
    await Future.wait(deviceIds.map((id) async {
      try {
        final events = await client.getMotionEvents(id);
        events.sort((a, b) => (a.eventTime ?? DateTime(0)).compareTo(b.eventTime ?? DateTime(0)));
        final last = events.isEmpty ? null : events.last;
        if (last != null) fetched[id] = last.type == 'deviceStopped' ? last.eventTime : null;
      } catch (_) {}
    }));
    if (!_alive(gen) || fetched.isEmpty) return;
    // 取り直した端末だけを、いまの状態に重ねる（取得中に届いた変化を消さない）
    final merged = Map<int, DateTime?>.from(state.stoppedSince);
    fetched.forEach((id, since) {
      final p = state.positions[id];
      // 取得中に走り出していたら、古い停車時刻で上書きしない
      if (p?.motion == true) {
        merged[id] = null;
      } else {
        merged[id] = since;
      }
    });
    state = state.copyWith(stoppedSince: merged);
  }

  // ---------- WebSocket ----------

  Future<void> _connect(int gen) async {
    final client = _client;
    if (client == null || !_alive(gen) || _connecting) return;
    _connecting = true;
    try {
      final stream = await client.openSocket();
      if (!_alive(gen)) {
        // 接続中にログアウト・切り替えされた → この接続は使わずに閉じる
        await stream.listen((_) {}).cancel();
        return;
      }
      await _sub?.cancel();
      _retryCount = 0;
      state = state.copyWith(connected: true, clearDisconnectedAt: true);
      _sub = stream.listen(
        (m) => _onMessage(gen, m),
        onDone: () => _scheduleReconnect(gen),
        onError: (_) => _scheduleReconnect(gen),
      );
      if (_everConnected) {
        // 切れている間に起きたアラームを取り込む（WebSocket は過去の分を送り直さない）
        ref.read(alarmProvider.notifier).reload();
      }
      _everConnected = true;
    } catch (_) {
      if (!_alive(gen)) return;
      // セッション切れの可能性があるのでトークンで再ログインしてから再接続
      await ref.read(authProvider.notifier).refreshSession();
      _scheduleReconnect(gen);
    } finally {
      _connecting = false;
    }
  }

  void _scheduleReconnect(int gen) {
    if (!_alive(gen)) return;
    state = state.copyWith(connected: false, disconnectedAt: state.disconnectedAt ?? DateTime.now());
    _retryTimer?.cancel();
    final seconds = math.min(60, 5 * (1 << math.min(_retryCount, 4)));
    _retryCount++;
    _retryTimer = Timer(Duration(seconds: seconds), () async {
      if (!_alive(gen)) return;
      await _reload(gen); // 切れている間の変化を取り込む
      await _connect(gen);
    });
  }

  /// 再接続の待ち時間を飛ばして、すぐにつなぎ直す（「今すぐ再接続」ボタン・アプリに戻ったとき）
  Future<void> reconnectNow() async {
    final gen = _gen;
    if (!_alive(gen) || state.connected || _connecting) return;
    _retryTimer?.cancel();
    _retryCount = 0;
    await _reload(gen);
    await _connect(gen);
  }

  void _onMessage(int gen, Map<String, dynamic> msg) {
    if (!_alive(gen) || msg.isEmpty) return;
    var next = state;
    if (msg['devices'] is List) {
      final devices = Map<int, Device>.from(next.devices);
      for (final e in msg['devices'] as List) {
        final d = Device.fromJson(e as Map<String, dynamic>);
        devices[d.id] = d;
      }
      next = next.copyWith(devices: devices);
      ref.read(alarmProvider.notifier).updateDeviceNames({for (final d in devices.values) d.id: d.name});
    }
    final needStopRefresh = <int>[];
    if (msg['positions'] is List) {
      final positions = Map<int, Position>.from(next.positions);
      final stopped = Map<int, DateTime?>.from(next.stoppedSince);
      for (final e in msg['positions'] as List) {
        final p = Position.fromJson(e as Map<String, dynamic>);
        positions[p.deviceId] = p;
        if (p.motion == true) {
          stopped[p.deviceId] = null; // 走り出したら停車時間はリセット
        } else if (p.motion == false && stopped[p.deviceId] == null) {
          needStopRefresh.add(p.deviceId); // 止まったら停車開始時刻を取り直す
        }
      }
      next = next.copyWith(positions: positions, stoppedSince: stopped);
    }
    if (msg['events'] is List) {
      final stopped = Map<int, DateTime?>.from(next.stoppedSince);
      final events = <TrackerEvent>[];
      for (final e in msg['events'] as List) {
        final ev = TrackerEvent.fromJson(e as Map<String, dynamic>);
        if (ev.type == 'deviceStopped') stopped[ev.deviceId] = ev.eventTime ?? DateTime.now();
        if (ev.type == 'deviceMoving') stopped[ev.deviceId] = null;
        events.add(ev);
      }
      next = next.copyWith(stoppedSince: stopped);
      // アラーム一覧に追加し、スマホに通知
      ref.read(alarmProvider.notifier).addRealtime(events);
    }
    state = next;
    _refreshStoppedSince(gen, needStopRefresh);
    final sel = state.selectedId;
    if (sel != null) ensureAddress(sel);
  }

  // ---------- 操作 ----------

  void select(int deviceId) {
    state = state.copyWith(selectedId: deviceId);
    ensureAddress(deviceId);
  }

  /// 前／次の端末を選ぶ（地図の ▲▼ ボタン）
  void selectRelative(int step) {
    final list = state.sortedDevices;
    if (list.isEmpty) return;
    final idx = list.indexWhere((d) => d.id == state.selectedId);
    final next = list[(idx + step + list.length) % list.length];
    select(next.id);
  }

  /// 停車開始時刻の取り直し（同じ端末は 2 分に 1 回まで）
  void _refreshStoppedSince(int gen, List<int> deviceIds) {
    final now = DateTime.now();
    final targets = deviceIds.where((id) {
      final last = _stopRefreshedAt[id];
      return last == null || now.difference(last) > const Duration(minutes: 2);
    }).toList();
    if (targets.isEmpty) return;
    for (final id in targets) {
      _stopRefreshedAt[id] = now;
    }
    _loadStoppedSince(gen, targets);
  }

  // ---------- 住所 ----------

  /// 住所の取得を予約する（50m 以上動いたときだけ取り直す）。
  /// 住所変換サービス（Nominatim）の利用規約「1 秒に 1 回まで」を守るため、1 件ずつ間隔をあけて取得し、
  /// 失敗した端末は 5 分間は取り直さない。
  void ensureAddress(int deviceId, {bool force = false}) {
    final p = state.positions[deviceId];
    if (p == null || _geocodeQueued.contains(deviceId)) return;
    if (!force) {
      final failed = _geocodeFailedAt[deviceId];
      if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 5)) return;
      final prev = _geocodedAt[deviceId];
      if (prev != null && state.addresses.containsKey(deviceId) && _meters(prev.lat, prev.lon, p.latitude, p.longitude) < 50) return;
    }
    if (p.address != null) {
      // サーバーが住所を付けて送ってきた場合はそのまま使う
      _geocodedAt[deviceId] = (lat: p.latitude, lon: p.longitude);
      state = state.copyWith(addresses: {...state.addresses, deviceId: formatAddress(p.address!)});
      return;
    }
    _geocodeQueued.add(deviceId);
    _geocodeQueue.add(deviceId);
    _runGeocodeQueue(_gen);
  }

  Future<void> _runGeocodeQueue(int gen) async {
    if (_geocodeRunning) return;
    _geocodeRunning = true;
    try {
      while (_geocodeQueue.isNotEmpty && _alive(gen)) {
        final id = _geocodeQueue.removeFirst();
        _geocodeQueued.remove(id);
        final client = _client;
        final p = state.positions[id];
        if (client == null || p == null) continue;
        try {
          final address = await client.geocode(p.latitude, p.longitude);
          if (!_alive(gen)) return;
          if (address != null) {
            _geocodedAt[id] = (lat: p.latitude, lon: p.longitude);
            _geocodeFailedAt.remove(id);
            state = state.copyWith(addresses: {...state.addresses, id: formatAddress(address)});
          } else {
            _geocodeFailedAt[id] = DateTime.now();
          }
        } catch (_) {
          _geocodeFailedAt[id] = DateTime.now();
        }
        if (_geocodeQueue.isNotEmpty) await Future<void>.delayed(const Duration(milliseconds: 1100));
      }
    } finally {
      _geocodeRunning = false;
      // 古いログインの処理が抜けた後に、新しいログインの予約が残っていれば続ける
      // （破棄済みのときは何もしない。ここで呼び直すと無限に繰り返してしまう）
      if (_geocodeQueue.isNotEmpty && gen != _gen && ref.mounted) _runGeocodeQueue(_gen);
    }
  }

  static double _meters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }
}

/// Nominatim の住所（「施設名;階, 区, JP」など）を日本向けに読みやすく整える
String formatAddress(String raw) {
  final parts = raw
      .split(RegExp(r'[,;]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != 'JP' && s != 'Japan' && s != '日本')
      .where((s) => !RegExp(r'^\d{3}-?\d{4}$').hasMatch(s)) // 郵便番号
      .toList();
  if (parts.isEmpty) return raw;
  // Nominatim は「細かい → 大まか」の順なので、日本式（大まか → 細かい）に並べ替える
  return parts.reversed.join(' ');
}

final trackingProvider = NotifierProvider<TrackingNotifier, TrackingState>(TrackingNotifier.new);
