import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../api/traccar_client.dart';
import '../geofence_shape.dart';
import 'auth.dart';

/// エリア（ジオフェンス）一覧と、端末への割り当て
class GeofenceState {
  const GeofenceState({this.geofences = const [], this.links = const {}, this.loading = true, this.error});

  final List<Geofence> geofences;

  /// エリア ID → 割り当てられている端末 ID
  final Map<int, Set<int>> links;
  final bool loading;
  final String? error;

  Set<int> devicesOf(int geofenceId) => links[geofenceId] ?? const {};
}

class GeofenceNotifier extends Notifier<GeofenceState> {
  // ログインし直しても同じインスタンスが使い回されるため、世代番号で古い処理の結果を捨てる
  int _gen = 0;
  bool _alive(int gen) => gen == _gen && ref.mounted;

  TraccarClient? get _client => ref.mounted ? ref.read(authProvider).value?.client : null;

  @override
  GeofenceState build() {
    final gen = ++_gen;
    ref.onDispose(() => _gen++);
    final session = ref.watch(authProvider).value;
    if (session == null) return const GeofenceState(loading: false);
    Future.microtask(() => _reload(gen));
    return const GeofenceState();
  }

  Future<void> reload() => _reload(_gen);

  Future<void> _reload(int gen) async {
    final client = _client;
    if (client == null || !_alive(gen)) return;
    try {
      final geofences = await client.getGeofences();
      final devices = await client.getDevices();
      // 端末ごとに割り当てを調べ、「エリア → 端末」の形にする
      final links = <int, Set<int>>{};
      for (final d in devices) {
        final assigned = await client.getGeofencesForDevice(d.id);
        for (final g in assigned) {
          links.putIfAbsent(g.id, () => <int>{}).add(d.id);
        }
      }
      if (!_alive(gen)) return;
      geofences.sort((a, b) => a.name.compareTo(b.name));
      state = GeofenceState(geofences: geofences, links: links, loading: false);
    } on ApiException catch (e) {
      if (_alive(gen)) state = GeofenceState(geofences: state.geofences, links: state.links, loading: false, error: e.message);
    }
  }

  /// エリアを作成・更新し、端末の割り当てを合わせる。保存したエリアを返す
  Future<Geofence> save({Geofence? existing, required String name, required GeofenceShape shape, required Set<int> deviceIds}) async {
    final client = _client;
    if (client == null) throw ApiException('ログインしていません');
    final area = shape.toWkt();
    final saved = existing == null
        ? await client.createGeofence(name: name, area: area)
        : await client.updateGeofence(existing, name: name, area: area);
    final before = existing == null ? <int>{} : state.devicesOf(existing.id);
    for (final id in deviceIds.difference(before)) {
      await client.linkGeofence(id, saved.id);
    }
    for (final id in before.difference(deviceIds)) {
      await client.unlinkGeofence(id, saved.id);
    }
    await reload();
    return saved;
  }

  Future<void> delete(Geofence g) async {
    final client = _client;
    if (client == null) return;
    await client.deleteGeofence(g.id);
    await reload();
  }
}

final geofenceProvider = NotifierProvider<GeofenceNotifier, GeofenceState>(GeofenceNotifier.new);
