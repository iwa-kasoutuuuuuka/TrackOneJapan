import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../settings/settings_page.dart';
import 'device_card.dart';
import 'device_list_view.dart';
import 'map_view.dart';
import 'wide_home_layout.dart';

/// ホーム（地図／一覧の切り替え）
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _tab = 0; // 0 = 地図, 1 = 一覧

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(trackingProvider);
    final wide = isWideLayout(context); // PC など広い画面は一覧と地図を並べる

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'マイページ',
          icon: const Icon(Icons.person_outline),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
        ),
        title: wide ? const Text('TrackOne Japan') : SegmentedButton<int>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            selectedBackgroundColor: AppColors.navy,
            selectedForegroundColor: Colors.white,
          ),
          segments: const [
            ButtonSegment(value: 0, label: Text('地図')),
            ButtonSegment(value: 1, label: Text('一覧')),
          ],
          selected: {_tab},
          onSelectionChanged: (v) => setState(() => _tab = v.first),
        ),
        actions: [
          IconButton(
            tooltip: 'アラーム',
            onPressed: () {
              ref.read(trackingProvider.notifier).clearUnread();
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('アラーム一覧は次の開発段階で追加します')));
            },
            icon: Badge(
              isLabelVisible: s.unreadEvents > 0,
              label: Text('${s.unreadEvents}'),
              backgroundColor: AppColors.red,
              child: const Icon(Icons.notifications_none),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: s.loading
          ? const Center(child: CircularProgressIndicator())
          : s.error != null && s.devices.isEmpty
              ? _ErrorView(message: s.error!, onRetry: () => ref.read(trackingProvider.notifier).reload())
              : wide ? const WideHomeLayout() : IndexedStack(
                  index: _tab,
                  children: [
                    const Column(children: [Expanded(child: MapView()), DeviceCard()]),
                    DeviceListView(onOpenOnMap: () => setState(() => _tab = 0)),
                  ],
                ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 48, color: AppColors.gray),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('再読み込み')),
          ]),
        ),
      );
}
