import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/traccar_client.dart';
import '../../core/state/auth.dart';
import '../../core/theme.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 前回の URL とメールを入れておく
    ref.read(sessionStoreProvider).read().then((saved) {
      if (!mounted) return;
      if (saved.server != null) _server.text = saved.server!;
      if (saved.email != null) _email.text = saved.email!;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return; // Enter キーの連打などで二重にログインしない
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).login(server: _server.text, email: _email.text, password: _password.text);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'ログインできませんでした（$e）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF24569A), AppColors.navyDark]),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
                child: Column(children: [
                  Image.asset('assets/icon/icon-512.png', width: 96, height: 96),
                  const SizedBox(height: 14),
                  const Text('TrackOne Japan', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('GPS 発信機の位置をいつでも確認', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextFormField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'サーバー URL', hintText: 'https://xxxx.ts.net', prefixIcon: Icon(Icons.dns_outlined)),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'サーバー URL を入力してください' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.email, AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'メールアドレス', prefixIcon: Icon(Icons.mail_outline)),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'メールアドレスを入力してください' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: !_showPassword,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'パスワード',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _showPassword ? 'パスワードを隠す' : 'パスワードを表示',
                        icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? 'パスワードを入力してください' : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFFFDECEE), borderRadius: BorderRadius.circular(10)),
                      child: Text(_error!, style: const TextStyle(color: AppColors.red, fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('ログイン'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'サーバー URL は、サーバーの Tailscale Funnel の URL です。\nパスワードはこのアプリに保存しません。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: AppColors.gray, height: 1.6),
                  ),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
