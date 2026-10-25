import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api/traccar_client.dart';
import '../../core/geofence_shape.dart';
import '../../core/state/alarms.dart';
import '../../core/state/geofences.dart';
import '../../core/state/map_type.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../widgets/base_map.dart';
import '../home/device_status.dart';

enum _Mode { circle, polygon }

/// エリアの作成・編集（円は中心と半径、多角形は頂点をタップ）
class GeofenceEditPage extends ConsumerStatefulWidget {
  const GeofenceEditPage({super.key, this.geofence});
  final Geofence? geofence;

  @override
  ConsumerState<GeofenceEditPage> createState() => _GeofenceEditPageState();
}

class _GeofenceEditPageState extends ConsumerState<GeofenceEditPage> {
  final _name = TextEditingController();
  final _map = MapController();
  _Mode _mode = _Mode.circle;
  LatLng? _center;
  double _radius = 300;
  final List<LatLng> _points = [];
  final Set<int> _devices = {};
  bool _unsupported = false; // アプリで編集できない形（線など）
  bool _saving = false;
  late final LatLng _initialCenter;
  CameraFit? _initialFit;

  bool get _isNew => widget.geofence == null;

  @override
  void initState() {
    super.initState();
    final g = widget.geofence;
    final tracking = ref.read(trackingProvider);
    if (g != null) {
      _name.text = g.name;
      _devices.addAll(ref.read(geofenceProvider).devicesOf(g.id));
      final shape = GeofenceShape.parse(g.area);
      switch (shape) {
        case CircleShape c:
          _mode = _Mode.circle;
          _center = c.center;
          _radius = c.radius.clamp(CircleShape.minRadius, CircleShape.maxRadius);
        case PolygonShape p:
          _mode = _Mode.polygon;
          _points.addAll(p.points);
        case null:
          _unsupported = true;
      }
      if (shape != null) {
        _initialFit = CameraFit.bounds(bounds: LatLngBounds.fromPoints(shape.boundsPoints), padding: const EdgeInsets.all(60), maxZoom: 17);
      }
    } else {
      // 新しいエリア：選択中の端末を対象にし、その位置を中心にする
      final sel = tracking.selectedId;
      if (sel != null) _devices.add(sel);
      final p = sel == null ? null : tracking.positions[sel];
      if (p != null) _center = LatLng(p.latitude, p.longitude);
    }
    _initialCenter = _center ?? (_points.isNotEmpty ? _points.first : const LatLng(35.681236, 139.767125));
  }

  @override
  void dispose() {
    _name.dispose();
    _map.dispose();
    super.dispose();
  }

  GeofenceShape? get _shape {
    if (_mode == _Mode.circle) return _center == null ? null : CircleShape(_center!, _radius);
    return _points.length >= 3 ? PolygonShape(List.of(_points)) : null;
  }

  void _onTap(LatLng p) {
    if (_unsupported) return;
    setState(() {
      if (_mode == _Mode.circle) {
        _center = p;
      } else {
        _points.add(p);
      }
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final shape = _shape;
    String? problem;
    if (name.isEmpty) problem = 'エリア名を入力してください';
    if (shape == null) problem = _mode == _Mode.circle ? '地図をタップして中心を決めてください' : '地図をタップして頂点を 3 つ以上置いてください';
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(geofenceProvider.notifier).save(existing: widget.geofence, name: name, shape: shape!, deviceIds: Set.of(_devices));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('「$name」を保存しました')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存できませんでした（${e is ApiException ? e.message : e}）')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final g = widget.geofence!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('「${g.name}」を削除しますか？'),
        content: const Text('このエリアの出入りの通知も届かなくなります。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(geofenceProvider.notifier).delete(g);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('削除できませんでした（$e）')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mapType = ref.watch(mapTypeProvider);
    final tracking = ref.watch(trackingProvider);
    final notify = ref.watch(notificationSettingsProvider);
    final shape = _shape;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'エリアを追加' : 'エリアの編集'),
        actions: [
          if (!_isNew) IconButton(tooltip: '削除', icon: const Icon(Icons.delete_outline), onPressed: _saving ? null : _delete),
          TextButton(onPressed: _saving || _unsupported ? null : _save, child: const Text('保存')),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: _initialCenter,
                initialZoom: 15,
                initialCameraFit: _initialFit,
                maxZoom: 19,
                onTap: (_, p) => _onTap(p),
              ),
              children: [
                baseTileLayer(context, mapType),
                if (shape is CircleShape)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: shape.center,
                      radius: shape.radius,
                      useRadiusInMeter: true,
                      color: AppColors.navy.withValues(alpha: 0.18),
                      borderColor: AppColors.navy,
                      borderStrokeWidth: 2.5,
                    ),
                  ]),
                if (_mode == _Mode.polygon && _points.length >= 3)
                  PolygonLayer(polygons: [
                    Polygon(points: _points, color: AppColors.navy.withValues(alpha: 0.18), borderColor: AppColors.navy, borderStrokeWidth: 2.5),
                  ]),
                if (_mode == _Mode.polygon && _points.length == 2)
                  PolylineLayer(polylines: [Polyline(points: _points, color: AppColors.navy, strokeWidth: 2.5)]),
                MarkerLayer(markers: [
                  // 対象の端末の現在地
                  for (final id in _devices)
                    if (tracking.positions[id] != null)
                      Marker(
                        point: LatLng(tracking.positions[id]!.latitude, tracking.positions[id]!.longitude),
                        width: 30,
                        height: 30,
                        child: Image.asset(DeviceKind.of(tracking.devices[id]?.category).asset),
                      ),
                  if (_mode == _Mode.circle && _center != null)
                    Marker(
                      point: _center!,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(color: AppColors.red, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                      ),
                    ),
                  if (_mode == _Mode.polygon)
                    for (var i = 0; i < _points.length; i++)
                      Marker(
                        point: _points[i],
                        width: 24,
                        height: 24,
                        child: Container(
                          decoration: BoxDecoration(color: AppColors.navy, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                          alignment: Alignment.center,
                          child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                      ),
                ]),
                baseAttribution(mapType),
              ],
            ),
            Positioned(
              left: 12,
              top: 12,
              right: 12,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!_unsupported)
                  SegmentedButton<_Mode>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      backgroundColor: context.pal.card,
                      selectedBackgroundColor: AppColors.navy,
                      selectedForegroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(value: _Mode.circle, label: Text('円')),
                      ButtonSegment(value: _Mode.polygon, label: Text('多角形')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (v) => setState(() => _mode = v.first),
                  ),
                const Spacer(),
                if (_mode == _Mode.polygon && _points.isNotEmpty) ...[
                  _MapButton(icon: Icons.undo, tooltip: '1 つ戻す', onTap: () => setState(() => _points.removeLast())),
                  const SizedBox(width: 6),
                  _MapButton(icon: Icons.delete_sweep_outlined, tooltip: '頂点をすべて消す', onTap: () => setState(_points.clear)),
                ],
              ]),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(16)),
                  child: Text(
                    _unsupported
                        ? 'この形のエリアはアプリでは編集できません。管理画面で編集してください'
                        : _mode == _Mode.circle
                            ? '地図をタップして中心を決めます'
                            : '地図をタップして頂点を追加します（3 点以上・今 ${_points.length} 点）',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
          ]),
        ),
        _EditPanel(
          name: _name,
          mode: _mode,
          radius: _radius,
          unsupported: _unsupported,
          devices: tracking.sortedDevices,
          selected: _devices,
          enterOn: notify.isOn('geofenceEnter'),
          exitOn: notify.isOn('geofenceExit'),
          notifyBusy: notify.loading || notify.working,
          saving: _saving,
          onRadius: (v) => setState(() => _radius = v),
          onToggleDevice: (id, on) => setState(() => on ? _devices.add(id) : _devices.remove(id)),
          onNotify: (type, on) => ref.read(notificationSettingsProvider.notifier).setEnabled(type, on),
          onSave: _save,
        ),
      ]),
    );
  }
}

class _EditPanel extends StatelessWidget {
  const _EditPanel({
    required this.name,
    required this.mode,
    required this.radius,
    required this.unsupported,
    required this.devices,
    required this.selected,
    required this.enterOn,
    required this.exitOn,
    required this.notifyBusy,
    required this.saving,
    required this.onRadius,
    required this.onToggleDevice,
    required this.onNotify,
    required this.onSave,
  });

  final TextEditingController name;
  final _Mode mode;
  final double radius;
  final bool unsupported;
  final List<Device> devices;
  final Set<int> selected;
  final bool enterOn;
  final bool exitOn;
  final bool notifyBusy;
  final bool saving;
  final ValueChanged<double> onRadius;
  final void Function(int id, bool on) onToggleDevice;
  final void Function(String type, bool on) onNotify;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: context.pal.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 14, offset: Offset(0, -3))],
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'エリア名', hintText: '自宅、職場、学校 など', isDense: true),
                ),
                if (mode == _Mode.circle && !unsupported) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Text('半径', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: radius,
                        min: CircleShape.minRadius,
                        max: CircleShape.maxRadius,
                        divisions: 99,
                        label: formatRadius(radius),
                        onChanged: onRadius,
                      ),
                    ),
                    SizedBox(width: 64, child: Text(formatRadius(radius), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
                  ]),
                ],
                const SizedBox(height: 8),
                Text('対象の端末', style: TextStyle(fontSize: 12.5, color: context.pal.sub, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (devices.isEmpty)
                  const Text('端末がありません', style: TextStyle(fontSize: 12.5, color: AppColors.gray))
                else
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    for (final d in devices)
                      FilterChip(label: Text(d.name), selected: selected.contains(d.id), onSelected: (on) => onToggleDevice(d.id, on)),
                  ]),
                const SizedBox(height: 10),
                Text('通知（すべてのエリア・端末に共通）', style: TextStyle(fontSize: 12.5, color: context.pal.sub, fontWeight: FontWeight.w700)),
                Row(children: [
                  Expanded(child: _NotifySwitch(label: '入ったとき', value: enterOn, onChanged: notifyBusy ? null : (v) => onNotify('geofenceEnter', v))),
                  const SizedBox(width: 8),
                  Expanded(child: _NotifySwitch(label: '出たとき', value: exitOn, onChanged: notifyBusy ? null : (v) => onNotify('geofenceExit', v))),
                ]),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: saving || unsupported ? null : onSave,
                  child: saving
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('保存'),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _NotifySwitch extends StatelessWidget {
  const _NotifySwitch({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(border: Border.all(color: context.isDark ? const Color(0xFF3A4352) : const Color(0xFFD5DAE3), width: 1.5), borderRadius: BorderRadius.circular(11)),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Switch(value: value, onChanged: onChanged),
        ]),
      );
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: context.pal.card,
        elevation: 3,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Tooltip(message: tooltip, child: SizedBox(width: 40, height: 40, child: Icon(icon, color: context.pal.brand))),
        ),
      );
}
