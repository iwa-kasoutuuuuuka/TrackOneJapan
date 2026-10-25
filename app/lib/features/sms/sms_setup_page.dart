import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/state/auth.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';

/// SMS の文面のひな形（GT06 系の発信機で一般的なもの。機種によって違うので編集して送る）
class SmsTemplate {
  const SmsTemplate(this.label, this.description, this.build, {this.warning});
  final String label;
  final String description;
  final String Function(String domain, String port) build;
  final String? warning;
}

final smsTemplates = <SmsTemplate>[
  SmsTemplate(
    '接続先を自分のサーバーにする',
    '発信機が位置を送る先を、自分の Traccar サーバー（DuckDNS のドメインとポート）に変えます',
    (domain, port) => 'SERVER,1,${domain.isEmpty ? '<ドメイン>' : domain},${port.isEmpty ? '5023' : port},0#',
    warning: '送ると TrackerOne アプリでは位置が見られなくなります。元に戻す文面は TrackerOne の「サーバー切替」画面で控えておいてください。',
  ),
  SmsTemplate('状態の確認', '電池・GPS・通信の状態を返信で知らせます', (_, _) => 'STATUS#'),
  SmsTemplate('位置の問い合わせ', '今の位置（地図のリンクなど）を返信で知らせます', (_, _) => 'WHERE#'),
  SmsTemplate('設定の確認', '今の接続先・送信間隔などの設定を返信で知らせます', (_, _) => 'PARAM#'),
  SmsTemplate('送信間隔の変更', '走行中 10 秒・停車中 180 秒ごとに位置を送ります（数字は変えられます）', (_, _) => 'TIMER,10,180#'),
  SmsTemplate('再起動', '発信機を再起動します', (_, _) => 'RESET#'),
];

/// SMS で発信機を設定する（TrackerOne の「サーバー切替」に相当）
class SmsSetupPage extends ConsumerStatefulWidget {
  const SmsSetupPage({super.key, required this.deviceId});
  final int deviceId;

  @override
  ConsumerState<SmsSetupPage> createState() => _SmsSetupPageState();
}

class _SmsSetupPageState extends ConsumerState<SmsSetupPage> {
  final _domain = TextEditingController();
  final _port = TextEditingController(text: '5023');

  bool get _canSendSms => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    ref.read(sessionStoreProvider).readSmsTarget().then((t) {
      if (!mounted) return;
      setState(() {
        _domain.text = t.domain;
        _port.text = t.port;
      });
    });
  }

  @override
  void dispose() {
    _domain.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _open(SmsTemplate t) async {
    await ref.read(sessionStoreProvider).saveSmsTarget(_domain.text.trim(), _port.text.trim());
    if (!mounted) return;
    final phone = ref.read(trackingProvider).devices[widget.deviceId]?.phone ?? '';
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _EditDialog(template: t, initial: t.build(_domain.text.trim(), _port.text.trim()), canSendSms: _canSendSms),
    );
    if (text == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_canSendSms && phone.isNotEmpty) {
      // スマホの SMS アプリを、宛先と文面を入れた状態で開く
      final uri = Uri(scheme: 'sms', path: phone, queryParameters: {'body': text});
      final ok = await launchUrl(uri);
      if (!ok) messenger.showSnackBar(const SnackBar(content: Text('SMS アプリを開けませんでした')));
    } else {
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(SnackBar(
        content: Text(_canSendSms ? '文面をコピーしました（SIM の電話番号が未登録のため、宛先は手で入力してください）' : '文面をコピーしました。スマホから発信機の SIM あてに SMS で送ってください'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(trackingProvider.select((s) => s.devices[widget.deviceId]));
    final phone = device?.phone ?? '';
    return Scaffold(
      backgroundColor: context.pal.surface,
      appBar: AppBar(title: const Text('SMS で発信機を設定')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 24), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: context.pal.card, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(device?.name ?? '端末', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(phone.isEmpty ? 'SIM の電話番号：未登録（端末の設定で登録すると宛先が自動で入ります）' : 'SIM の電話番号：$phone',
                style: TextStyle(fontSize: 12.5, color: phone.isEmpty ? AppColors.red : context.pal.sub)),
            const SizedBox(height: 8),
            Text(
              '発信機の多くは、決まった文面の SMS で設定を変えられます。文面は機種によって違うため、送る前に説明書や TrackerOne の画面で確認し、必要なら書き換えてください。',
              style: TextStyle(fontSize: 12, color: context.pal.sub, height: 1.6),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          decoration: BoxDecoration(color: context.pal.card, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('自分のサーバーの接続先', style: TextStyle(fontSize: 12.5, color: context.pal.sub, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _domain,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'ドメイン', hintText: 'myhome-tracker.duckdns.org', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'ポート（ルーターで開けた外部ポート）', isDense: true),
            ),
            const SizedBox(height: 4),
            const Text('アプリのサーバー URL（ts.net）ではなく、発信機用の DuckDNS のドメインです。', style: TextStyle(fontSize: 11, color: AppColors.gray)),
          ]),
        ),
        const SizedBox(height: 12),
        for (final t in smsTemplates)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: context.pal.card,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _open(t),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Icon(t.warning != null ? Icons.swap_horiz : Icons.sms_outlined, color: t.warning != null ? AppColors.orange : context.pal.brand),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(t.description, style: TextStyle(fontSize: 11.5, color: context.pal.sub)),
                      ]),
                    ),
                    const Icon(Icons.chevron_right, color: AppColors.gray),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.template, required this.initial, required this.canSendSms});
  final SmsTemplate template;
  final String initial;
  final bool canSendSms;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.template.label),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.template.warning != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: context.pal.warnBg, borderRadius: BorderRadius.circular(10)),
              child: Text(widget.template.warning!, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 12),
          ],
          TextField(controller: _text, decoration: const InputDecoration(labelText: 'SMS の文面（書き換えられます）'), maxLines: 2),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(
            onPressed: () => Navigator.pop(context, _text.text.trim()),
            child: Text(widget.canSendSms ? 'SMS アプリで開く' : 'コピー'),
          ),
        ],
      );
}
