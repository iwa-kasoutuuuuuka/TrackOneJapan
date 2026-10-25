import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api/traccar_client.dart';
import '../../core/state/auth.dart';
import '../../core/state/map_type.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../models/models.dart';
import '../../platform/save_gpx.dart';
import '../../widgets/base_map.dart';
import '../home/device_status.dart';
import 'replay_logic.dart';

/// 履歴再生（TrackerOne の Playback に相当）
class ReplayPage extends ConsumerStatefulWidget {
  const ReplayPage({super.key, required this.deviceId});
  final int deviceId;

  @override
  ConsumerState<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends ConsumerState<ReplayPage> {
  final _map = MapController();
  DateTime _day = DateTime.now();
  bool _loading = true;
  String? _error;
  List<Position> _route = const [];
  List<StopReport> _stops = const [];
  List<TripReport> _trips = const [];
  SummaryReport? _summary;
  double? _distance; // 走行距離（ルートの線の長さ。読み込み時に 1 回だけ計算）

  double _cursor = 0;
  bool _playing = false;
  int _speedIndex = 2; // 4x
  Timer? _timer;
  bool _mapReady = false;
  int _loadGeneration = 0;
  int _request = 0;

  static const _tick = Duration(milliseconds: 250);

  int get _index => _route.isEmpty ? 0 : _cursor.floor().clamp(0, _route.length - 1);
  Position? get _current => _route.isEmpty ? null : _route[_index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(authProvider).value?.client;
    if (client == null) return;
    // 日付を素早く切り替えたとき、古い日の結果で上書きしないよう番号で見分ける
    final request = ++_request;
    _pause();
    setState(() {
      _loading = true;
      _error = null;
      // 前の日のデータを残さない（失敗したときに別の日のルートを書き出さないように）
      _route = const [];
      _stops = const [];
      _trips = const [];
      _summary = null;
      _distance = null;
      _cursor = 0;
    });
    final r = dayRange(_day);
    try {
      final results = await Future.wait([
        client.getRoute(widget.deviceId, r.from, r.to),
        client.getStops(widget.deviceId, r.from, r.to),
        client.getTrips(widget.deviceId, r.from, r.to),
        client.getSummary(widget.deviceId, r.from, r.to),
      ]);
      if (!mounted || request != _request) return;
      setState(() {
        _route = (results[0] as List<Position>).where((p) => p.valid || p.latitude != 0).toList();
        _stops = results[1] as List<StopReport>;
        _trips = results[2] as List<TripReport>;
        _summary = results[3] as SummaryReport?;
        final summaryDistance = _summary?.distance;
        _distance = _route.length >= 2
            ? routeDistance(_route)
            : (summaryDistance != null && summaryDistance >= 0 ? summaryDistance : null);
        _cursor = 0;
        _loading = false;
        _mapReady = false;
        _loadGeneration++;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          _error = e is ApiException ? e.message : '走行記録を読み込めませんでした';
          _loading = false;
        });
      }
    }
  }

  /// 走行範囲が収まる表示（2 地点以上あるとき）
  CameraFit? _routeFit() {
    if (_route.length < 2) return null;
    final points = _route.map((p) => LatLng(p.latitude, p.longitude)).toList();
    return CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(40), maxZoom: 17);
  }

  // ---------- 再生 ----------

  void _togglePlay() => _playing ? _pause() : _play();

  void _play() {
    if (_route.length < 2) return;
    if (_index >= _route.length - 1) _cursor = 0;
    setState(() => _playing = true);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) {
      final next = advanceCursor(_cursor, replaySpeeds[_speedIndex], _tick);
      if (next >= _route.length - 1) {
        setState(() => _cursor = (_route.length - 1).toDouble());
        _pause();
      } else {
        setState(() => _cursor = next);
      }
      _follow();
    });
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _playing) setState(() => _playing = false);
  }

  /// 再生中の地点が画面外に出たら地図を動かす
  void _follow() {
    final p = _current;
    if (!_mapReady || p == null) return;
    final point = LatLng(p.latitude, p.longitude);
    if (!_map.camera.visibleBounds.contains(point)) _map.move(point, _map.camera.zoom);
  }

  // ---------- 日付 ----------

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      helpText: '日付を選ぶ',
    );
    if (picked != null) _setDay(picked);
  }

  void _setDay(DateTime d) {
    setState(() => _day = d);
    _load();
  }

  // ---------- GPX 書き出し ----------

  Future<void> _exportGpx(String deviceName) async {
    if (_route.isEmpty) return;
    final ymd = '${_day.year}${_day.month.toString().padLeft(2, '0')}${_day.day.toString().padLeft(2, '0')}';
    // スマホは共有シート、Windows は保存ダイアログ（lib/platform/save_gpx.dart）
    final saved = await exportGpxFile(
      fileName: 'trackone_${safeFileName(deviceName)}_$ymd.gpx',
      gpx: buildGpx('$deviceName $ymd', _route),
      subject: '$deviceName の走行記録（${_day.month}月${_day.day}日）',
    );
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存しました: $saved')));
    }
  }

  // ---------- 画面 ----------

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(trackingProvider.select((s) => s.devices[widget.deviceId]));
    final mapType = ref.watch(mapTypeProvider);
    final name = device?.name ?? '端末';

    return Scaffold(
      appBar: AppBar(
        title: Text('履歴再生　$name', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'GPX ファイルで書き出し',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _route.isEmpty ? null : () => _exportGpx(name),
          ),
        ],
      ),
      body: Column(
        children: [
          _DateChips(day: _day, onSelect: _setDay, onPick: _pickDate),
          Expanded(
            child: Stack(
              children: [
                if (!_loading)
                  FlutterMap(
                    // 読み込み直すたびに地図を作り直し、最初から走行範囲で開く
                    // （準備完了の直後に表示範囲を動かすとタイルが読み込まれないことがあるため）
                    key: ValueKey(_loadGeneration),
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: _route.isEmpty
                          ? const LatLng(35.681236, 139.767125)
                          : LatLng(_route.first.latitude, _route.first.longitude),
                      initialZoom: _route.isEmpty ? 12 : 16,
                      initialCameraFit: _routeFit(),
                      maxZoom: 19,
                      onMapReady: () => _mapReady = true,
                    ),
                    children: [
                      baseTileLayer(context, mapType),
                      if (_route.length >= 2) ..._routeLayers(),
                      MarkerLayer(markers: _markers(device)),
                      baseAttribution(mapType),
                    ],
                  ),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (!_loading && _error != null) _MapMessage(icon: Icons.cloud_off, text: _error!, onRetry: _load),
                if (!_loading && _error == null && _route.isEmpty) const _MapMessage(icon: Icons.event_busy, text: 'この日の走行記録はありません'),
              ],
            ),
          ),
          _ReplayPanel(
            summary: _summary,
            distance: _distance,
            driving: totalDriving(_trips),
            stops: _stops,
            current: _current,
            cursor: _cursor,
            length: _route.length,
            playing: _playing,
            speed: replaySpeeds[_speedIndex],
            onTogglePlay: _togglePlay,
            onSeek: (v) {
              setState(() => _cursor = v);
              _follow();
            },
            onSpeed: () => setState(() => _speedIndex = (_speedIndex + 1) % replaySpeeds.length),
            onShowStops: _showStops,
          ),
        ],
      ),
    );
  }

  List<Widget> _routeLayers() {
    final all = _route.map((p) => LatLng(p.latitude, p.longitude)).toList();
    final played = all.sublist(0, _index + 1);
    return [
      PolylineLayer(
        polylines: [
          Polyline(
            points: all,
            strokeWidth: 5,
            color: AppColors.navy.withValues(alpha: 0.55),
            borderStrokeWidth: 1,
            borderColor: Colors.white70,
          ),
          if (played.length >= 2)
            Polyline(points: played, strokeWidth: 6, color: AppColors.teal, borderStrokeWidth: 1.5, borderColor: Colors.white),
        ],
      ),
    ];
  }

  List<Marker> _markers(Device? device) {
    if (_route.isEmpty) return const [];
    final first = _route.first, last = _route.last;
    final markers = <Marker>[
      _pin(LatLng(first.latitude, first.longitude), AppColors.green, Icons.flag, '出発'),
      if (_route.length > 1) _pin(LatLng(last.latitude, last.longitude), AppColors.red, Icons.sports_score, '到着'),
    ];
    for (var i = 0; i < _stops.length; i++) {
      final s = _stops[i];
      markers.add(
        Marker(
          point: LatLng(s.latitude, s.longitude),
          width: 30,
          height: 30,
          child: GestureDetector(
            onTap: () => _showStop(i),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.navy,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
              ),
              alignment: Alignment.center,
              child: Text(
                '${i + 1}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ),
        ),
      );
    }
    final c = _current;
    if (c != null) {
      markers.add(
        Marker(point: LatLng(c.latitude, c.longitude), width: 44, height: 44, child: Image.asset(DeviceKind.of(device?.category).asset)),
      );
    }
    return markers;
  }

  Marker _pin(LatLng p, Color color, IconData icon, String tooltip) => Marker(
    point: p,
    width: 30,
    height: 30,
    child: Tooltip(
      message: tooltip,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Icon(icon, size: 16, color: Colors.white),
      ),
    ),
  );

  void _showStop(int i) {
    final s = _stops[i];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('停車 ${i + 1}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              _InfoRow('到着', Units.dateTime(s.startTime)),
              _InfoRow('出発', Units.dateTime(s.endTime)),
              _InfoRow('停車時間', Units.duration(s.duration)),
              _InfoRow('場所', s.address == null ? '—' : formatAddress(s.address!)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.my_location),
                  label: const Text('この地点へ移動'),
                  onPressed: () {
                    Navigator.pop(context);
                    _map.move(LatLng(s.latitude, s.longitude), 17);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showStops() {
    if (_stops.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('停車地点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _stops.length,
                itemBuilder: (context, i) {
                  final s = _stops[i];
                  return ListTile(
                    leading: CircleAvatar(backgroundColor: AppColors.navy, foregroundColor: Colors.white, child: Text('${i + 1}')),
                    title: Text('${Units.dateTime(s.startTime)} 〜 ${Units.dateTime(s.endTime)}（${Units.duration(s.duration)}）'),
                    subtitle: Text(s.address == null ? '—' : formatAddress(s.address!), maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.pop(context);
                      _map.move(LatLng(s.latitude, s.longitude), 17);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 部品 ----------

class _DateChips extends StatelessWidget {
  const _DateChips({required this.day, required this.onSelect, required this.onPick});
  final DateTime day;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));
    final isToday = isSameDay(day, today);
    final isYesterday = isSameDay(day, yesterday);
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          ChoiceChip(label: const Text('今日'), selected: isToday, onSelected: (_) => onSelect(today)),
          const SizedBox(width: 8),
          ChoiceChip(label: const Text('昨日'), selected: isYesterday, onSelected: (_) => onSelect(yesterday)),
          const SizedBox(width: 8),
          if (!isToday && !isYesterday) ...[
            ChoiceChip(label: Text('${day.month}/${day.day}（${weekdays[day.weekday - 1]}）'), selected: true, onSelected: (_) => onPick()),
            const SizedBox(width: 8),
          ],
          ActionChip(avatar: const Icon(Icons.calendar_month, size: 18), label: const Text('日付を選ぶ'), onPressed: onPick),
        ],
      ),
    );
  }
}

class _ReplayPanel extends StatelessWidget {
  const _ReplayPanel({
    required this.summary,
    required this.distance,
    required this.driving,
    required this.stops,
    required this.current,
    required this.cursor,
    required this.length,
    required this.playing,
    required this.speed,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onSpeed,
    required this.onShowStops,
  });

  final SummaryReport? summary;
  final double? distance;
  final Duration driving;
  final List<StopReport> stops;
  final Position? current;
  final double cursor;
  final int length;
  final bool playing;
  final int speed;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final VoidCallback onSpeed;
  final VoidCallback onShowStops;

  @override
  Widget build(BuildContext context) {
    final c = current;
    return Container(
      decoration: BoxDecoration(
        color: context.pal.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 14, offset: Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        // 横向き・大きい文字でもはみ出さないよう、高さを抑えてスクロールさせる
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _Kpi(value: distance == null ? '—' : Units.distanceKm(distance!), label: '走行距離'),
                      _Kpi(value: driving == Duration.zero ? '—' : Units.duration(driving), label: '走行時間'),
                      _Kpi(value: summary == null ? '—' : Units.speedKmh(summary!.maxSpeed), label: '最高速度'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c == null || c.fixTime == null ? '—' : '${Units.dateTime(c.fixTime!)}　${Units.speedKmh(c.speed)}',
                          style: TextStyle(fontSize: 13, color: context.pal.sub),
                        ),
                      ),
                      InkWell(
                        onTap: stops.isEmpty ? null : onShowStops,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Text(
                            '停車 ${stops.length} 回${stops.isEmpty ? '' : ' ›'}',
                            style: TextStyle(
                              fontSize: 13,
                              color: stops.isEmpty ? context.pal.sub : context.pal.brand,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton.filled(
                        tooltip: playing ? '一時停止' : '再生',
                        // 暗い画面では本文色（明るい色）だと白いアイコンが見えないので、紺系の塗りにする
                        style: IconButton.styleFrom(backgroundColor: context.isDark ? Theme.of(context).colorScheme.primary : AppColors.ink),
                        onPressed: length < 2 ? null : onTogglePlay,
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      ),
                      Expanded(
                        child: Slider(
                          value: length < 2 ? 0 : cursor.clamp(0, (length - 1).toDouble()),
                          min: 0,
                          max: length < 2 ? 1 : (length - 1).toDouble(),
                          activeColor: AppColors.teal,
                          onChanged: length < 2 ? null : onSeek,
                        ),
                      ),
                      OutlinedButton(
                        onPressed: onSpeed,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(52, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
                          side: BorderSide(color: context.pal.ink, width: 1.5),
                        ),
                        child: Text(
                          '${speed}x',
                          style: TextStyle(color: context.pal.ink, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 11.5, color: context.pal.sub)),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: TextStyle(color: context.pal.sub, fontSize: 13)),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13.5))),
      ],
    ),
  );
}

class _MapMessage extends StatelessWidget {
  const _MapMessage({required this.icon, required this.text, this.onRetry});
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.pal.card.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: AppColors.gray),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center),
          if (onRetry != null) ...[const SizedBox(height: 10), OutlinedButton(onPressed: onRetry, child: const Text('再読み込み'))],
        ],
      ),
    ),
  );
}
