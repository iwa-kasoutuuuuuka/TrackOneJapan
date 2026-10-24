import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../api/traccar_client.dart';
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
    this.unreadEvents = 0,
    this.error,
  });

  final Map<int, Device> devices;
  final Map<int, Position> positions; // deviceId -> 最新位置
  final Map<int, DateTime?> stoppedSince; // deviceId -> 停車開始（走行中なら null）
  final Map<int, String> addresses; // deviceId -> 住所
  final int? selectedId;
  final bool loading;
  final bool connected;
  final int unreadEvents;
  final String? error;

  List<Device> get sortedDevices => devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  Device? get selected => selectedId == null ? null : devices[selectedId];

  TrackingState copyWith({
    Map<int, Device>? devices,
    Map<int, Position>? positions,
    Map<int, DateTime?>? stoppedSince,
    Map<int, String>? addresses,
    int? selectedId,
    bool? loading,
    bool? connected,
    int? unreadEvents,
    String? error,
    bool clearError = false,
  }) =>
      TrackingState(
        devices: devices ?? this.devices,
        positions: positions ?? this.positions,
        stoppedSince: stoppedSince ?? this.stoppedSince,
        addresses: addresses ?? this.addresses,
        selectedId: selectedId ?? this.selectedId,
        loading: loading ?? this.loading,
        connected: connected ?? this.connected,
        unreadEvents: unreadEvents ?? this.unreadEvents,
        error: clearError ? null : (error ?? this.error),
      );
}

class TrackingNotifier extends Notifier<TrackingState> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _disposed = false;
  final Map<int, ({double lat, double lon})> _geocodedAt = {};
  final Set<int> _geocoding = {};

  TraccarClient? get _client => ref.read(authProvider).value?.client;

  @override
  TrackingState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _sub?.cancel();
      _retryTimer?.cancel();
    });
    // ログインしている間だけ動く
    final session = ref.watch(authProvider).value;
    if (session == null) return const TrackingState(loading: false);
    Future.microtask(_start);
    return const TrackingState();
  }

  Future<void> _start() async {
    await reload();
    await _connect();
  }

  /// 端末一覧・最新位置・停車開始時刻を読み直す
  Future<void> reload() async {
    final client = _client;
    if (client == null) return;
    try {
      final devices = await client.getDevices();
      final positions = await client.getPositions();
      if (_disposed) return;
      final devMap = {for (final d in devices) d.id: d};
      final posMap = {for (final p in positions) p.deviceId: p};
      final selected = state.selectedId ?? (devices.isNotEmpty ? (devices.toList()..sort((a, b) => a.name.compareTo(b.name))).first.id : null);
      state = state.copyWith(devices: devMap, positions: posMap, selectedId: selected, loading: false, clearError: true);
      await _loadStoppedSince(devices.map((d) => d.id));
      if (selected != null) ensureAddress(selected);
    } on ApiException catch (e) {
      if (e.unauthorized && await ref.read(authProvider.notifier).refreshSession()) {
        return reload();
      }
      if (!_disposed) state = state.copyWith(loading: false, error: e.message);
    }
  }

  Future<void> _loadStoppedSince(Iterable<int> deviceIds) async {
    final client = _client;
    if (client == null) return;
    final result = Map<int, DateTime?>.from(state.stoppedSince);
    await Future.wait(deviceIds.map((id) async {
      try {
        final events = await client.getMotionEvents(id);
        events.sort((a, b) => (a.eventTime ?? DateTime(0)).compareTo(b.eventTime ?? DateTime(0)));
        final last = events.isEmpty ? null : events.last;
        if (last != null) result[id] = last.type == 'deviceStopped' ? last.eventTime : null;
      } catch (_) {}
    }));
    if (!_disposed) state = state.copyWith(stoppedSince: result);
  }

  // ---------- WebSocket ----------

  Future<void> _connect() async {
    final client = _client;
    if (client == null || _disposed) return;
    await _sub?.cancel();
    try {
      final stream = await client.openSocket();
      _retryCount = 0;
      if (!_disposed) state = state.copyWith(connected: true);
      _sub = stream.listen(_onMessage, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
    } catch (_) {
      // セッション切れの可能性があるのでトークンで再ログインしてから再接続
      await ref.read(authProvider.notifier).refreshSession();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    state = state.copyWith(connected: false);
    _retryTimer?.cancel();
    final seconds = math.min(60, 5 * (1 << math.min(_retryCount, 4)));
    _retryCount++;
    _retryTimer = Timer(Duration(seconds: seconds), () async {
      await reload(); // 切れている間の変化を取り込む
      await _connect();
    });
  }

  void _onMessage(Map<String, dynamic> msg) {
    if (_disposed || msg.isEmpty) return;
    var next = state;
    if (msg['devices'] is List) {
      final devices = Map<int, Device>.from(next.devices);
      for (final e in msg['devices'] as List) {
        final d = Device.fromJson(e as Map<String, dynamic>);
        devices[d.id] = d;
      }
      next = next.copyWith(devices: devices);
    }
    if (msg['positions'] is List) {
      final positions = Map<int, Position>.from(next.positions);
      for (final e in msg['positions'] as List) {
        final p = Position.fromJson(e as Map<String, dynamic>);
        positions[p.deviceId] = p;
      }
      next = next.copyWith(positions: positions);
    }
    if (msg['events'] is List) {
      final stopped = Map<int, DateTime?>.from(next.stoppedSince);
      var unread = next.unreadEvents;
      for (final e in msg['events'] as List) {
        final ev = TrackerEvent.fromJson(e as Map<String, dynamic>);
        if (ev.type == 'deviceStopped') stopped[ev.deviceId] = ev.eventTime ?? DateTime.now();
        if (ev.type == 'deviceMoving') stopped[ev.deviceId] = null;
        if (ev.type != 'deviceMoving' && ev.type != 'deviceStopped') unread++;
      }
      next = next.copyWith(stoppedSince: stopped, unreadEvents: unread);
    }
    state = next;
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

  void clearUnread() => state = state.copyWith(unreadEvents: 0);

  /// 住所を取得（50m 以上動いたときだけ取り直す）
  Future<void> ensureAddress(int deviceId, {bool force = false}) async {
    final client = _client;
    final p = state.positions[deviceId];
    if (client == null || p == null || _geocoding.contains(deviceId)) return;
    final prev = _geocodedAt[deviceId];
    if (!force && prev != null && state.addresses.containsKey(deviceId) && _meters(prev.lat, prev.lon, p.latitude, p.longitude) < 50) {
      return;
    }
    _geocoding.add(deviceId);
    try {
      final address = p.address ?? await client.geocode(p.latitude, p.longitude);
      if (address != null && !_disposed) {
        _geocodedAt[deviceId] = (lat: p.latitude, lon: p.longitude);
        state = state.copyWith(addresses: {...state.addresses, deviceId: formatAddress(address)});
      }
    } catch (_) {
    } finally {
      _geocoding.remove(deviceId);
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
