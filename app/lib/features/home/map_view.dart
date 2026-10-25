import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/geofence_shape.dart';
import '../../core/state/geofences.dart';
import '../../core/state/map_type.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../widgets/base_map.dart';
import 'device_status.dart';

class MapView extends ConsumerStatefulWidget {
  const MapView({super.key});

  @override
  ConsumerState<MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<MapView> {
  final _map = MapController();
  bool _ready = false;
  int? _centeredOn;
  LatLng? _initialCenter;

  static const _tokyo = LatLng(35.681236, 139.767125);

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 起動時は、選択中の端末の位置で地図を開く（起動直後に移動するとタイルが出ないことがあるため）
    final s = ref.read(trackingProvider);
    final p = s.selectedId == null ? null : s.positions[s.selectedId];
    if (p != null) {
      _initialCenter = LatLng(p.latitude, p.longitude);
      _centeredOn = s.selectedId;
    }
  }

  void _centerOnSelected({bool force = false}) {
    if (!mounted) return; // 画面の切り替え（ウィンドウ幅の変更・ログアウト）で消えた後に呼ばれることがある
    final s = ref.read(trackingProvider);
    final id = s.selectedId;
    final p = id == null ? null : s.positions[id];
    if (!_ready || p == null) return;
    if (!force && _centeredOn == id) return;
    _centeredOn = id;
    _map.move(LatLng(p.latitude, p.longitude), _map.camera.zoom < 13 ? 16 : _map.camera.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(trackingProvider);
    final mapType = ref.watch(mapTypeProvider);
    // 登録したエリアを薄く表示する
    final shapes = [for (final g in ref.watch(geofenceProvider).geofences) GeofenceShape.parse(g.area)].whereType<GeofenceShape>().toList();

    // 選択が変わったら地図をその端末へ
    ref.listen(trackingProvider.select((t) => t.selectedId), (_, _) => _centerOnSelected(force: true));
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnSelected());

    final markers = <Marker>[];
    for (final d in s.sortedDevices) {
      final p = s.positions[d.id];
      if (p == null) continue;
      final selected = d.id == s.selectedId;
      final kind = DeviceKind.of(d.category);
      markers.add(Marker(
        point: LatLng(p.latitude, p.longitude),
        width: 120,
        height: 70,
        alignment: Alignment.center,
        child: GestureDetector(
          onTap: () => ref.read(trackingProvider.notifier).select(d.id),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: selected ? AppColors.navy : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
                child: Text(d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: selected ? Colors.white : AppColors.navy)),
              ),
              const SizedBox(height: 3),
              Opacity(
                opacity: d.isOnline ? 1 : 0.55,
                child: Image.asset(kind.asset, width: selected ? 40 : 34, height: selected ? 40 : 34),
              ),
            ],
          ),
        ),
      ));
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _initialCenter ?? _tokyo,
            initialZoom: _initialCenter == null ? 12 : 16,
            maxZoom: 19,
            onMapReady: () {
              _ready = true;
              // 位置がまだ無かった場合は、描画が落ち着いてから端末へ移動
              WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnSelected());
            },
          ),
          children: [
            baseTileLayer(context, mapType),
            CircleLayer(circles: [
              for (final s in shapes.whereType<CircleShape>())
                CircleMarker(
                  point: s.center,
                  radius: s.radius,
                  useRadiusInMeter: true,
                  color: const Color(0xFF3B82C4).withValues(alpha: 0.10),
                  borderColor: const Color(0xFF3B82C4).withValues(alpha: 0.7),
                  borderStrokeWidth: 1.5,
                ),
            ]),
            PolygonLayer(polygons: [
              for (final s in shapes.whereType<PolygonShape>())
                Polygon(
                  points: s.points,
                  color: const Color(0xFF3B82C4).withValues(alpha: 0.10),
                  borderColor: const Color(0xFF3B82C4).withValues(alpha: 0.7),
                  borderStrokeWidth: 1.5,
                ),
            ]),
            MarkerLayer(markers: markers),
            baseAttribution(mapType),
          ],
        ),
        Positioned(
          right: 12,
          top: 12,
          child: Column(children: [
            _Fab(icon: Icons.layers_outlined, tooltip: '地図の種類', onTap: () => _chooseMapType(context)),
            const SizedBox(height: 40),
            _Fab(icon: Icons.keyboard_arrow_up, tooltip: '前の端末', onTap: () => ref.read(trackingProvider.notifier).selectRelative(-1)),
            const SizedBox(height: 8),
            _Fab(icon: Icons.keyboard_arrow_down, tooltip: '次の端末', onTap: () => ref.read(trackingProvider.notifier).selectRelative(1)),
            const SizedBox(height: 16),
            _Fab(icon: Icons.my_location, tooltip: '選択中の端末へ移動', onTap: () => _centerOnSelected(force: true)),
          ]),
        ),
        if (!s.connected && !s.loading)
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('再接続中…', style: TextStyle(fontSize: 12)),
              ]),
            ),
          ),
      ],
    );
  }

  Future<void> _chooseMapType(BuildContext context) async {
    final current = ref.read(mapTypeProvider);
    final chosen = await showModalBottomSheet<MapType>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('地図の種類', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          for (final t in MapType.values)
            ListTile(
              leading: Icon(t == current ? Icons.radio_button_checked : Icons.radio_button_off, color: AppColors.navy),
              title: Text(t.label),
              subtitle: Text(t.attribution, style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(context, t),
            ),
        ])),
      ),
    );
    if (!mounted) return; // 選んでいる間に画面が切り替わった（PC のウィンドウ幅の変更など）
    if (chosen != null) ref.read(mapTypeProvider.notifier).set(chosen);
  }
}

class _Fab extends StatelessWidget {
  const _Fab({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        elevation: 3,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Tooltip(message: tooltip, child: SizedBox(width: 40, height: 40, child: Icon(icon, color: AppColors.navy, size: 22))),
        ),
      );
}
