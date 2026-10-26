import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/traccar_client.dart';
import '../../core/command_labels.dart';
import '../../core/state/auth.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../../models/models.dart';

/// コマンド（TrackerOne の Instruct に相当）
class CommandsPage extends ConsumerStatefulWidget {
  const CommandsPage({super.key, required this.deviceId});
  final int deviceId;

  @override
  ConsumerState<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends ConsumerState<CommandsPage> {
  List<String>? _types;
  List<TrackerEvent> _history = const [];
  String? _error;

  TraccarClient? get _client => ref.read(authProvider).value?.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    try {
      final types = await client.getCommandTypes(widget.deviceId);
      final history = await client.getCommandEvents(widget.deviceId);
      if (!mounted) return;
      types.sort((a, b) => commandOrder(a).compareTo(commandOrder(b)));
      history.sort((a, b) => (b.eventTime ?? DateTime(0)).compareTo(a.eventTime ?? DateTime(0)));
      setState(() {
        _types = types;
        _history = history;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open(String type) async {
    final device = ref.read(trackingProvider).devices[widget.deviceId];
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CommandSheet(type: type, deviceId: widget.deviceId, deviceName: device?.name ?? '端末'),
    );
    if (sent != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(trackingProvider.select((s) => s.devices[widget.deviceId]));
    final types = _types;
    return Scaffold(
      backgroundColor: context.pal.surface,
      appBar: AppBar(title: Text('コマンド　${device?.name ?? ''}', overflow: TextOverflow.ellipsis)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
          if (device != null && !device.isOnline)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: context.pal.warnBg, borderRadius: BorderRadius.circular(12)),
              child: const Text('発信機はオフラインです。送ったコマンドは保留され、通信が戻ったときに送られます（エンジン停止などの危険な操作は保留せず、送れません）。', style: TextStyle(fontSize: 12.5)),
            ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: AppColors.red)))
          else if (types == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (types.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('この発信機で使えるコマンドはありません'))
          else
            for (final t in types) _CommandTile(type: t, onTap: () => _open(t)),
          if (types != null && types.length == 1 && types.first == 'custom')
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Text(
                'この発信機の通信方式では「任意のコマンド」だけが使えます。GT06 方式の発信機では、エンジン停止・再開なども表示されます。',
                style: TextStyle(fontSize: 11.5, color: context.pal.sub, height: 1.6),
              ),
            ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text('最近の結果（過去 7 日間）', style: TextStyle(fontSize: 12.5, color: context.pal.sub, fontWeight: FontWeight.w700)),
          ),
          if (_history.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text('まだ結果はありません', style: TextStyle(fontSize: 12.5, color: AppColors.gray)))
          else
            for (final e in _history.take(20))
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: context.pal.card, borderRadius: BorderRadius.circular(12)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(e.type == 'commandResult' ? Icons.reply : Icons.outbox_outlined, size: 20, color: context.pal.brand),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e.type == 'commandResult' ? '発信機からの返事' : '保留中のコマンドを送信しました',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      if (e.attributes['result'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: SelectableText('${e.attributes['result']}', style: TextStyle(fontSize: 12.5, color: context.pal.sub)),
                        ),
                    ]),
                  ),
                  if (e.eventTime != null) Text(Units.dateTime(e.eventTime!), style: const TextStyle(fontSize: 11, color: AppColors.gray)),
                ]),
              ),
        ]),
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({required this.type, required this.onTap});
  final String type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final info = describeCommand(type);
    final color = info.danger ? AppColors.red : AppColors.navy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: context.pal.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
                child: Icon(info.icon, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(info.label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: info.danger ? AppColors.red : context.pal.ink)),
                  const SizedBox(height: 2),
                  Text(info.description, style: TextStyle(fontSize: 11.5, color: context.pal.sub), maxLines: 2, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const Icon(Icons.chevron_right, color: AppColors.gray),
            ]),
          ),
        ),
      ),
    );
  }
}

/// コマンドの入力と送信
class _CommandSheet extends ConsumerStatefulWidget {
  const _CommandSheet({required this.type, required this.deviceId, required this.deviceName});
  final String type;
  final int deviceId;
  final String deviceName;

  @override
  ConsumerState<_CommandSheet> createState() => _CommandSheetState();
}

class _CommandSheetState extends ConsumerState<_CommandSheet> {
  final _text = TextEditingController();
  final _seconds = TextEditingController(text: '60');
  final _phone = TextEditingController();
  bool _sending = false;
  String? _problem; // シートの後ろにスナックバーを出しても見えないので、シートの中に表示する

  @override
  void dispose() {
    _text.dispose();
    _seconds.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<bool> _confirmDanger(CommandInfo info, {bool customLooksDangerous = false}) async {
    for (final step in [1, 2]) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: AppColors.red, size: 36),
          title: Text(step == 1 ? '「${info.label}」を送りますか？' : '本当に送りますか？（最終確認）'),
          content: Text(step == 1
              ? (customLooksDangerous
                  ? '「${_text.text.trim()}」は、エンジン停止・電源オフ・初期化などのコマンドに見えます。走行中に届くと大変危険です。'
                  : info.description)
              : '「${widget.deviceName}」に「${info.label}」を送ります。車が止まっていることを確認してください。\n'
                  '発信機がオフラインのときは送らずに中止します（後から届くことはありません）。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('やめる')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.red),
              onPressed: () => Navigator.pop(context, true),
              child: Text(step == 1 ? '次へ' : '送信する'),
            ),
          ],
        ),
      );
      if (ok != true) return false;
    }
    return true;
  }

  Future<void> _send() async {
    final info = describeCommand(widget.type);
    final client = ref.read(authProvider).value?.client;
    if (client == null) return;
    String? problem;
    if (info.param == CommandParam.text && _text.text.trim().isEmpty) problem = 'コマンドを入力してください';
    final sec = int.tryParse(_seconds.text.trim());
    if (info.param == CommandParam.seconds && (sec == null || sec < 10 || sec > 86400)) problem = '10〜86400 秒で入力してください';
    if (info.param == CommandParam.sos && _phone.text.trim().isEmpty) problem = '電話番号を入力してください';
    final danger = isDangerousCommand(widget.type, text: _text.text.trim());
    final online = ref.read(trackingProvider).devices[widget.deviceId]?.isOnline ?? false;
    if (problem == null && danger && !online) {
      problem = '発信機がオフラインのため送れません。危険な操作は、後から届かないよう、発信機がオンラインのときだけ送れます';
    }
    setState(() => _problem = problem);
    if (problem != null) return;
    if (danger && !await _confirmDanger(info, customLooksDangerous: !info.danger)) return;
    if (!mounted) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final now = await client.sendCommand(widget.deviceId, widget.type,
          attributes: commandAttributes(widget.type, text: _text.text.trim(), seconds: sec, sosPhone: _phone.text.trim()),
          noQueue: danger);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(
        content: Text(now ? '「${info.label}」を送信しました' : '発信機が圏外のため保留しました。通信が戻ったら送られます'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _problem = '送信できませんでした（${e is ApiException ? e.message : e}）';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = describeCommand(widget.type);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(info.icon, color: info.danger ? AppColors.red : context.pal.brand),
              const SizedBox(width: 8),
              Expanded(child: Text(info.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            Text(info.description, style: TextStyle(fontSize: 13, color: context.pal.sub, height: 1.5)),
            const SizedBox(height: 14),
            if (info.param == CommandParam.text)
              TextField(
                controller: _text,
                autofocus: true,
                decoration: InputDecoration(labelText: widget.type == 'custom' ? 'コマンド（例：STATUS#）' : 'メッセージ'),
              ),
            if (info.param == CommandParam.seconds)
              TextField(
                controller: _seconds,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: '送信間隔（秒）', helperText: '例：走行中の追跡は 10〜30 秒、普段は 60〜300 秒'),
              ),
            if (info.param == CommandParam.sos)
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'SOS の連絡先（電話番号）'),
              ),
            if (_problem != null) ...[
              const SizedBox(height: 10),
              Text(_problem!, style: const TextStyle(fontSize: 12.5, color: AppColors.red)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: info.danger ? FilledButton.styleFrom(backgroundColor: AppColors.red) : null,
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Text('送信'),
            ),
          ]),
        ),
      ),
    );
  }
}
