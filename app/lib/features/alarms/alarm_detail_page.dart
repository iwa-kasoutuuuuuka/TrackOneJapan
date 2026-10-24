import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/event_labels.dart';
import '../../core/state/alarms.dart';
import '../../core/state/auth.dart';
import '../../core/state/map_type.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../models/models.dart';
import '../../widgets/base_map.dart';

/// アラーム詳細（発生地点の地図と情報）
class AlarmDetailPage extends ConsumerStatefulWidget {
  const AlarmDetailPage({super.key, required this.eventId});
  final int eventId;

  @override
  ConsumerState<AlarmDetailPage> createState() => _AlarmDetailPageState();
}

class _AlarmDetailPageState extends ConsumerState<AlarmDetailPage> {
  Position? _position;
  String? _address;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(authProvider).value?.client;
    var event = ref.read(alarmProvider).byId(widget.eventId);
    if (event == null) {
      // 通知から開いた直後など、一覧にまだない場合は読み直す
      await ref.read(alarmProvider.notifier).reload();
      event = ref.read(alarmProvider).byId(widget.eventId);
    }
    if (client == null || event == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final p = await client.getPosition(event.positionId);
      String? address = p?.address;
      if (p != null && address == null) address = await client.geocode(p.latitude, p.longitude);
      if (!mounted) return;
      setState(() {
        _position = p;
        _address = address == null ? null : formatAddress(address);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(alarmProvider);
    final mapType = ref.watch(mapTypeProvider);
    final e = s.byId(widget.eventId);

    if (e == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('アラームの詳細')),
        body: Center(child: _loading ? const CircularProgressIndicator() : const Text('このアラームは見つかりませんでした')),
      );
    }

    final info = describeEvent(e, geofenceName: s.geofenceName(e));
    final p = _position;
    return Scaffold(
      appBar: AppBar(title: const Text('アラームの詳細')),
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: info.color, borderRadius: BorderRadius.circular(14)),
              child: Icon(info.displayIcon, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(info.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text('${s.deviceName(e.deviceId)}・${info.category.label}', style: const TextStyle(fontSize: 13, color: AppColors.sub)),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : p == null
                  ? const Center(child: Text('発生地点の位置情報はありません', style: TextStyle(color: AppColors.sub)))
                  : FlutterMap(
                      options: MapOptions(initialCenter: LatLng(p.latitude, p.longitude), initialZoom: 16, maxZoom: 19),
                      children: [
                        baseTileLayer(context, mapType),
                        MarkerLayer(markers: [
                          Marker(
                            point: LatLng(p.latitude, p.longitude),
                            width: 44,
                            height: 44,
                            child: Container(
                              decoration: BoxDecoration(
                                color: info.color,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 3),
                                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                              ),
                              child: Icon(info.displayIcon, color: Colors.white, size: 22),
                            ),
                          ),
                        ]),
                        baseAttribution(mapType),
                      ],
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _Row('発生時刻', e.eventTime == null ? '—' : '${Units.dateTime(e.eventTime!)}（${Units.ago(e.eventTime!)}）'),
              _Row('場所', _address ?? (p == null ? '—' : '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}')),
              if (p != null) _Row('速度', Units.speedKmh(p.speed)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('この端末を地図で見る'),
                  onPressed: () {
                    ref.read(trackingProvider.notifier).select(e.deviceId);
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  },
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 76, child: Text(label, style: const TextStyle(color: AppColors.sub, fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13.5))),
        ]),
      );
}
