import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/traccar_client.dart';
import '../../core/state/auth.dart';
import '../../core/theme.dart';
import '../../core/units.dart';

/// 位置共有（期限付きのリンクを作って送る）
Future<void> showShareSheet(BuildContext context, int deviceId, String deviceName) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(deviceId: deviceId, deviceName: deviceName),
    );

/// 共有リンク（Traccar の Web 画面がトークンでログインして、その端末だけを表示する）
String buildShareLink(String server, String token) => '$server/?token=${Uri.encodeQueryComponent(token)}';

/// 家の外からは開けないサーバー URL か（localhost・LAN 内の IP）
bool isLocalOnlyServer(String server) {
  final host = Uri.tryParse(server)?.host ?? '';
  if (host == 'localhost') return true;
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return false;
  final b = ip.rawAddress;
  return ip.isLoopback || (ip.type == InternetAddressType.IPv4 && (b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31)));
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.deviceId, required this.deviceName});
  final int deviceId;
  final String deviceName;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  static const _choices = <(String, Duration)>[('1 時間', Duration(hours: 1)), ('24 時間', Duration(hours: 24)), ('7 日間', Duration(days: 7))];
  int _choice = 0;
  bool _busy = false;
  String? _link;
  DateTime? _until;
  String? _error;
  bool _copied = false;

  Future<void> _create() async {
    final session = ref.read(authProvider).value;
    if (session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final until = DateTime.now().add(_choices[_choice].$2);
      final token = await session.client.shareDevice(widget.deviceId, until);
      if (!mounted) return;
      setState(() {
        _link = buildShareLink(session.server, token);
        _until = until;
        _busy = false;
      });
    } catch (e) {
      // シートの後ろにスナックバーを出しても見えないので、シートの中に表示する
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '共有リンクを作れませんでした（${e is ApiException ? e.message : e}）';
      });
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _link!));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  Future<void> _share() async {
    await SharePlus.instance.share(ShareParams(
      text: '${widget.deviceName}の現在地（${Units.dateTime(_until!)}まで見られます）\n$_link',
      subject: '${widget.deviceName}の現在地',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(authProvider).value?.server ?? '';
    final canShareSheet = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // 横向きのスマホや低いウィンドウでも下のボタンまで届くよう、スクロールできるようにする
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('「${widget.deviceName}」の位置を共有', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'リンクを受け取った人は、アカウントなしでブラウザからこの端末の現在地だけを見られます。期限が過ぎると見られなくなります。',
            style: TextStyle(fontSize: 12.5, color: context.pal.sub, height: 1.6),
          ),
          if (isLocalOnlyServer(server)) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: context.pal.warnBg, borderRadius: BorderRadius.circular(10)),
              child: Text('いまのサーバー URL（$server）は家の外からは開けません。家族などに送る場合は、Tailscale Funnel の https:// の URL でログインしてください。',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
          const SizedBox(height: 14),
          if (_link == null) ...[
            Text('見られる期間', style: TextStyle(fontSize: 12.5, color: context.pal.sub, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              for (var i = 0; i < _choices.length; i++)
                ChoiceChip(label: Text(_choices[i].$1), selected: _choice == i, onSelected: (_) => setState(() => _choice = i)),
            ]),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Icon(Icons.link),
              label: const Text('共有リンクを作る'),
              onPressed: _busy ? null : _create,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppColors.red)),
            ],
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: context.pal.surface, borderRadius: BorderRadius.circular(10)),
              child: SelectableText(_link!, style: const TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(height: 6),
            Text('${Units.dateTime(_until!)} まで見られます', style: TextStyle(fontSize: 12, color: context.pal.sub)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                icon: Icon(_copied ? Icons.check : Icons.copy),
                label: Text(_copied ? 'コピーしました' : 'コピー'),
                onPressed: _copy,
              )),
              if (canShareSheet) ...[
                const SizedBox(width: 10),
                Expanded(child: FilledButton.icon(icon: const Icon(Icons.share), label: const Text('送る'), onPressed: _share)),
              ],
            ]),
          ],
        ]),
      ),
    );
  }
}
