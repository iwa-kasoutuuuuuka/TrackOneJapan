import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/event_labels.dart';
import '../../core/notifications/phone_notifier.dart';
import '../../core/state/alarms.dart';
import '../../core/state/auth.dart';
import '../../core/theme.dart';

/// 通知の設定（TrackerOne の AlarmSetting / ReceiveAlarmType に相当）
class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  ConsumerState<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends ConsumerState<NotificationSettingsPage> {
  bool? _phoneNotify;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    ref.read(sessionStoreProvider).readPhoneNotify().then((v) {
      if (mounted) setState(() => _phoneNotify = v);
    });
  }

  Future<void> _toggle(String type, bool on) async {
    setState(() => _busy.add(type));
    try {
      await ref.read(notificationSettingsProvider.notifier).setEnabled(type, on);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('変更できませんでした（$e）')));
    } finally {
      if (mounted) setState(() => _busy.remove(type));
    }
  }

  Future<void> _setPhoneNotify(bool on) async {
    if (on) await PhoneNotifier.instance.requestPermission();
    await ref.read(sessionStoreProvider).savePhoneNotify(on);
    setState(() => _phoneNotify = on);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(notificationSettingsProvider);
    final hasPush = s.notificators.contains('firebase');

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(title: const Text('通知の設定')),
      body: s.loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              const _Caption('このスマホ'),
              _Card(children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('通知欄に表示する'),
                  subtitle: const Text('アラームが届いたら、スマホの通知欄に表示します'),
                  value: _phoneNotify ?? true,
                  onChanged: _phoneNotify == null ? null : _setPhoneNotify,
                ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  hasPush
                      ? 'サーバーでプッシュ通知（Firebase）が使えるため、アプリを閉じていても通知が届きます。'
                      : 'いまはアプリが動いている間（画面を閉じても、アプリを終了していなければ）通知が届きます。'
                          'アプリを完全に終了しているときにも届けるには、サーバーにプッシュ通知（Firebase）の設定が必要です。',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.sub, height: 1.6),
                ),
              ),
              const _Caption('受け取るアラームの種類（全端末共通）'),
              _Card(children: [
                for (final t in notificationTypes)
                  SwitchListTile(
                    title: Text(t.label),
                    subtitle: Text(t.description, style: const TextStyle(fontSize: 12)),
                    value: s.isOn(t.type),
                    onChanged: _busy.contains(t.type) ? null : (v) => _toggle(t.type, v),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('おすすめ設定にする'),
                  onPressed: () => ref.read(notificationSettingsProvider.notifier).enableRecommended(),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Text(
                  'この設定はサーバーに保存され、同じアカウントでログインしている他のスマホやブラウザにも反映されます。'
                  'アラームの履歴（過去 7 日間）は、設定に関係なく一覧で見られます。',
                  style: TextStyle(fontSize: 11.5, color: AppColors.sub, height: 1.6),
                ),
              ),
              if (s.error != null) Padding(padding: const EdgeInsets.all(16), child: Text(s.error!, style: const TextStyle(color: AppColors.red))),
            ]),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Text(text, style: const TextStyle(fontSize: 12.5, color: AppColors.sub, fontWeight: FontWeight.w700)),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: Column(children: children),
      );
}
