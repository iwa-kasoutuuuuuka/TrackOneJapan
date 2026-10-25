import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/event_labels.dart';
import '../../core/state/alarms.dart';
import '../../core/state/clock.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../models/models.dart';
import 'alarm_detail_page.dart';
import 'notification_settings_page.dart';

/// アラーム一覧（TrackerOne の AlarmList に相当）
class AlarmListPage extends ConsumerStatefulWidget {
  const AlarmListPage({super.key});

  @override
  ConsumerState<AlarmListPage> createState() => _AlarmListPageState();
}

class _AlarmListPageState extends ConsumerState<AlarmListPage> {
  EventCategory? _filter;
  DateTime? _seenBefore; // 開いた時点の「最後に見た時刻」（未読の印に使う）

  @override
  void initState() {
    super.initState();
    _seenBefore = ref.read(alarmProvider).lastSeen ?? DateTime.now();
    // 開いたら既読にする（一覧の未読の印は、開いた時点のものを表示し続ける）
    Future.microtask(() => ref.read(alarmProvider.notifier).markAllRead());
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(alarmProvider);
    ref.watch(clockProvider); // 「〇分前」の表示を 30 秒ごとに更新
    final settings = ref.watch(notificationSettingsProvider);
    final events = s.events.where((e) => _filter == null || describeEvent(e).category == _filter).toList();
    final usedCategories = {for (final e in s.events) describeEvent(e).category};
    final noSettings = !settings.loading && settings.configs.where((c) => c.always && c.hasWeb).isEmpty;

    // 日付ごとに区切る
    final rows = <Object>[];
    String? lastHeader;
    for (final e in events) {
      final h = e.eventTime == null ? '日時不明' : dayHeader(e.eventTime!);
      if (h != lastHeader) {
        rows.add(h);
        lastHeader = h;
      }
      rows.add(e);
    }

    return Scaffold(
      backgroundColor: context.pal.surface,
      appBar: AppBar(
        title: const Text('アラーム'),
        actions: [
          IconButton(
            tooltip: '通知の設定',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationSettingsPage())),
          ),
        ],
      ),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(children: [
            ChoiceChip(label: const Text('すべて'), selected: _filter == null, onSelected: (_) => setState(() => _filter = null)),
            for (final c in EventCategory.values.where(usedCategories.contains)) ...[
              const SizedBox(width: 8),
              ChoiceChip(label: Text(c.label), selected: _filter == c, onSelected: (_) => setState(() => _filter = c)),
            ],
          ]),
        ),
        if (noSettings)
          _Banner(
            text: 'リアルタイムでアラームを受け取る種類が設定されていません。',
            action: 'おすすめ設定にする',
            onTap: settings.working ? null : () => ref.read(notificationSettingsProvider.notifier).enableRecommended(),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(alarmProvider.notifier).reload(),
            child: s.loading
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 80),
                        const Icon(Icons.notifications_none, size: 48, color: AppColors.gray),
                        const SizedBox(height: 10),
                        Center(child: Text(s.error ?? '過去 7 日間のアラームはありません', style: TextStyle(color: context.pal.sub))),
                      ])
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          if (r is String) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                              child: Text(r, style: TextStyle(fontSize: 12, color: context.pal.sub, fontWeight: FontWeight.w700)),
                            );
                          }
                          final e = r as TrackerEvent;
                          final unread = _seenBefore == null || (e.eventTime != null && e.eventTime!.isAfter(_seenBefore!));
                          return _AlarmTile(event: e, state: s, unread: unread);
                        },
                      ),
          ),
        ),
      ]),
    );
  }
}

class _AlarmTile extends StatelessWidget {
  const _AlarmTile({required this.event, required this.state, required this.unread});
  final TrackerEvent event;
  final AlarmState state;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final info = describeEvent(event, geofenceName: state.geofenceName(event));
    final t = event.eventTime;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: context.pal.card,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlarmDetailPage(eventId: event.id))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
            child: Row(children: [
              SizedBox(
                width: 8,
                child: unread ? Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.red, shape: BoxShape.circle)) : null,
              ),
              const SizedBox(width: 4),
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: info.color, borderRadius: BorderRadius.circular(11)),
                child: Icon(info.displayIcon, color: Colors.white, size: 21),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(info.title, style: TextStyle(fontSize: 14, fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(state.deviceName(event.deviceId), style: TextStyle(fontSize: 12, color: context.pal.sub)),
                ]),
              ),
              if (t != null)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 12, color: AppColors.gray)),
                  const SizedBox(height: 2),
                  Text(Units.ago(t), style: const TextStyle(fontSize: 10.5, color: AppColors.gray)),
                ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.action, required this.onTap});
  final String text;
  final String action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(color: context.pal.warnBg, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          const Icon(Icons.info_outline, color: Color(0xFFB86200)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
          TextButton(onPressed: onTap, child: Text(action)),
        ]),
      );
}
