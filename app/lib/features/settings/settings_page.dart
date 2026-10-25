import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/state/auth.dart';
import '../../core/state/map_type.dart';
import '../../core/state/theme_mode.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../alarms/notification_settings_page.dart';
import '../geofence/geofence_list_page.dart';

/// マイページ・設定
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authProvider).value;
    final mapType = ref.watch(mapTypeProvider);
    final themeMode = ref.watch(themeModeProvider);
    final connected = ref.watch(trackingProvider.select((s) => s.connected));

    return Scaffold(
      appBar: AppBar(title: const Text('マイページ')),
      backgroundColor: context.pal.surface,
      body: ListView(children: [
        Container(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF24569A), AppColors.navyDark]),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(children: [
            Image.asset('assets/icon/icon-512.png', width: 52, height: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(session?.user.name.isNotEmpty == true ? session!.user.name : 'ユーザー',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(session?.email ?? '', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              ]),
            ),
          ]),
        ),
        _Section(children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('サーバー'),
            subtitle: Text(session?.server ?? '—'),
            trailing: Icon(Icons.circle, size: 12, color: connected ? AppColors.green : AppColors.gray),
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('地図の種類'),
            subtitle: Text(mapType.label),
            onTap: () async {
              final t = await showDialog<MapType>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('地図の種類'),
                  children: [for (final m in MapType.values) SimpleDialogOption(onPressed: () => Navigator.pop(context, m), child: Text(m.label))],
                ),
              );
              if (t != null) ref.read(mapTypeProvider.notifier).set(t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('画面の明るさ'),
            subtitle: Text(themeModeLabel(themeMode)),
            onTap: () async {
              final m = await showDialog<ThemeMode>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('画面の明るさ'),
                  children: [
                    for (final m in ThemeMode.values)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, m),
                        child: Row(children: [
                          Icon(m == themeMode ? Icons.radio_button_checked : Icons.radio_button_off, size: 20, color: context.pal.brand),
                          const SizedBox(width: 10),
                          Expanded(child: Text(themeModeLabel(m))),
                        ]),
                      ),
                  ],
                ),
              );
              if (m != null) ref.read(themeModeProvider.notifier).set(m);
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('通知の設定'),
            subtitle: const Text('受け取るアラームの種類、通知欄への表示'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationSettingsPage())),
          ),
          ListTile(
            leading: const Icon(Icons.radar),
            title: const Text('エリア（ジオフェンス）'),
            subtitle: const Text('自宅・職場などの出入りを通知'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GeofenceListPage())),
          ),
        ]),
        _Section(children: [
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('アプリについて'),
              subtitle: Text('TrackOne Japan ${snap.data?.version ?? ''}'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'TrackOne Japan',
                applicationVersion: snap.data?.version,
                applicationIcon: Padding(padding: const EdgeInsets.all(8), child: Image.asset('assets/icon/icon-512.png', width: 64)),
                applicationLegalese: '地図: 国土地理院（地理院タイル）/ © OpenStreetMap contributors\nサーバー: Traccar（Apache License 2.0）',
              ),
            ),
          ),
        ]),
        _Section(children: [
          ListTile(
            leading: const Icon(Icons.logout, color: AppColors.red),
            title: const Text('ログアウト', style: TextStyle(color: AppColors.red)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('ログアウトしますか？'),
                  content: const Text('このスマホのログイン情報を削除します。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('ログアウト')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(authProvider.notifier).logout();
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
          ),
        ]),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        // ListTile のタップ効果が見えるよう、背景は Material で塗る
        child: Material(
          color: context.pal.card,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      );
}
