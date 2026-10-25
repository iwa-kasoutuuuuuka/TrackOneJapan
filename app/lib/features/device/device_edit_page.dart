import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/traccar_client.dart';
import '../../core/state/auth.dart';
import '../../core/state/tracking.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../home/device_status.dart';
import '../sms/sms_setup_page.dart';

/// アイコンの種類（Traccar の端末カテゴリ）
const deviceCategories = <(String, String)>[
  ('car', '車'),
  ('motorcycle', 'バイク'),
  ('person', '人'),
  ('animal', 'ペット'),
  ('default', '荷物・その他'),
];

/// 既存のカテゴリを、選択肢のどれかに寄せる（trucks なども「車」として扱う）
String normalizeCategory(String? c) {
  final kind = DeviceKind.of(c).asset;
  for (final (key, _) in deviceCategories) {
    if (DeviceKind.of(key).asset == kind) return key;
  }
  return 'default';
}

/// IMEI は通常 15 桁の数字
bool looksLikeImei(String s) => RegExp(r'^\d{15}$').hasMatch(s);

/// 端末の追加（device == null）と設定の変更（TrackerOne の BindDevice / DeviceSetting に相当）
class DeviceEditPage extends ConsumerStatefulWidget {
  const DeviceEditPage({super.key, this.device});
  final Device? device;

  @override
  ConsumerState<DeviceEditPage> createState() => _DeviceEditPageState();
}

class _DeviceEditPageState extends ConsumerState<DeviceEditPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _imei;
  late final TextEditingController _phone;
  late final TextEditingController _model;
  late final TextEditingController _speed;
  late String _category;
  bool _saving = false;

  bool get _isNew => widget.device == null;

  @override
  void initState() {
    super.initState();
    final d = widget.device;
    _name = TextEditingController(text: d?.name ?? '');
    _imei = TextEditingController(text: d?.uniqueId ?? '');
    _phone = TextEditingController(text: d?.phone ?? '');
    _model = TextEditingController(text: d?.model ?? '');
    _speed = TextEditingController(text: d?.speedLimitKmh == null ? '' : d!.speedLimitKmh!.round().toString());
    _category = d == null ? 'car' : normalizeCategory(d.category);
  }

  @override
  void dispose() {
    for (final c in [_name, _imei, _phone, _model, _speed]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final client = ref.read(authProvider).value?.client;
    if (client == null) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_isNew) {
        final created = await client.createDevice(
            name: _name.text.trim(), uniqueId: _imei.text.trim(), category: _category, phone: _phone.text.trim());
        await ref.read(trackingProvider.notifier).reload();
        ref.read(trackingProvider.notifier).select(created.id);
        messenger.showSnackBar(SnackBar(content: Text('「${created.name}」を追加しました。発信機から位置が届くと地図に表示されます')));
      } else {
        await client.updateDevice(
          widget.device!,
          name: _name.text.trim(),
          category: _category,
          phone: _phone.text.trim(),
          model: _model.text.trim(),
          speedLimitKmh: double.tryParse(_speed.text.trim()),
        );
        await ref.read(trackingProvider.notifier).reload();
        messenger.showSnackBar(const SnackBar(content: Text('保存しました')));
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // 同じ IMEI がすでに登録されているとサーバーエラーになる
      final hint = _isNew ? '（同じ IMEI がすでに登録されていないか確認してください）' : '';
      messenger.showSnackBar(SnackBar(content: Text('保存できませんでした：${e.message}$hint')));
    }
  }

  Future<void> _delete() async {
    final d = widget.device!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('「${d.name}」を削除しますか？'),
        content: const Text('この端末の位置の履歴やアラームも見られなくなります。元に戻せません。'),
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
    final client = ref.read(authProvider).value?.client;
    if (client == null) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await client.deleteDevice(d.id);
      await ref.read(trackingProvider.notifier).reload();
      messenger.showSnackBar(SnackBar(content: Text('「${d.name}」を削除しました')));
      navigator.popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('削除できませんでした：${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(_isNew ? '端末を追加' : '端末の設定'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('保存')), const SizedBox(width: 4)],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名前', hintText: '例：車、バイク、おばあちゃん'),
            validator: (v) => (v == null || v.trim().isEmpty) ? '名前を入力してください' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _imei,
            enabled: _isNew, // 登録後の IMEI の変更は管理画面で
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]'))],
            decoration: InputDecoration(
              labelText: 'IMEI（識別子）',
              helperText: _isNew ? '発信機本体のラベル、または TrackerOne の端末詳細に書かれた 15 桁の数字' : '変更は管理画面で行います',
              helperMaxLines: 2,
            ),
            validator: (v) {
              final s = (v ?? '').trim();
              if (s.isEmpty) return 'IMEI を入力してください';
              if (_isNew && !looksLikeImei(s) && !RegExp(r'^\d{6,20}$').hasMatch(s)) return '数字で入力してください（通常 15 桁）';
              return null;
            },
          ),
          const SizedBox(height: 18),
          const Text('地図のアイコン', style: TextStyle(fontSize: 12.5, color: AppColors.sub, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (key, label) in deviceCategories)
              ChoiceChip(
                avatar: Image.asset(DeviceKind.of(key).asset, width: 22, height: 22),
                label: Text(label),
                selected: _category == key,
                onSelected: (_) => setState(() => _category = key),
              ),
          ]),
          const SizedBox(height: 18),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'SIM の電話番号（任意）', helperText: 'SMS で発信機を設定するときに使います'),
          ),
          if (!_isNew) ...[
            const SizedBox(height: 14),
            TextFormField(controller: _model, decoration: const InputDecoration(labelText: '機種（任意）', hintText: '例：WanWay S20')),
            const SizedBox(height: 14),
            TextFormField(
              controller: _speed,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '速度制限（km/h・任意）',
                helperText: 'この速度を超えると「速度超過」のアラームになります。空欄なら使いません',
                helperMaxLines: 2,
                suffixText: 'km/h',
              ),
              validator: (v) {
                final s = (v ?? '').trim();
                if (s.isEmpty) return null;
                final n = int.tryParse(s);
                return (n == null || n < 5 || n > 300) ? '5〜300 km/h で入力してください' : null;
              },
            ),
            const SizedBox(height: 22),
            OutlinedButton.icon(
              icon: const Icon(Icons.sms_outlined),
              label: const Text('SMS で発信機を設定する'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SmsSetupPage(deviceId: widget.device!.id))),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              icon: const Icon(Icons.delete_outline),
              label: const Text('この端末を削除'),
              onPressed: _saving ? null : _delete,
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text(_isNew ? '追加' : '保存'),
          ),
        ]),
      ),
    );
  }
}
