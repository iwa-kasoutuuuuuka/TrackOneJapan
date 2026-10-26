import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notifications/phone_notifier.dart';

import '../../models/models.dart';
import '../api/traccar_client.dart';
import '../auth/session_store.dart';

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// ログイン中の情報
class AuthSession {
  AuthSession({required this.client, required this.user, required this.token, required this.email});
  final TraccarClient client;
  final User user;
  String token; // 期限が近づくと作り直す
  final String email;
  String get server => client.baseUrl;
}

/// ログイン状態。null = 未ログイン
class AuthNotifier extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() async {
    // 起動時: 保存済みトークンで自動ログイン
    final store = ref.read(sessionStoreProvider);
    ({String? server, String? token, String? email, DateTime? tokenExpires}) saved;
    try {
      saved = await store.read();
    } catch (_) {
      // 端末の暗号化データが読めない（機種変更・バックアップからの復元など）→ ログインし直してもらう
      try {
        await store.clearToken();
      } catch (_) {}
      return null;
    }
    if (saved.server == null || saved.token == null) return null;
    // 保存済みの URL も毎回確かめる（古い版で保存した LAN 内の http:// などに、鍵を送らない）
    if (!TraccarClient.isAllowedUrl(saved.server!)) {
      await store.clearToken();
      return null;
    }
    final client = TraccarClient(saved.server!);
    try {
      final user = await client.loginWithToken(saved.token!);
      final session = _attach(AuthSession(client: client, user: user, token: saved.token!, email: saved.email ?? user.email));
      _renewTokenIfNeeded(session, saved.tokenExpires);
      _revokePending(session);
      return session;
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await store.clearToken();
        return null;
      }
      rethrow; // 通信エラーは「もう一度試す」か「別のサーバーでログイン」を選べる画面になる
    }
  }

  /// トークンの期限が近い（30 日未満・不明）なら、新しいトークンを作って古いものを無効にする。
  /// 有効期間を短くしておき、使っている間だけ自動で延ばす（漏れた鍵が長く使えないように）
  Future<void> _renewTokenIfNeeded(AuthSession s, DateTime? expires) async {
    if (expires != null && expires.difference(DateTime.now()) > const Duration(days: 30)) return;
    try {
      final old = s.token;
      final token = await s.client.createToken();
      if (state.value != s && state.value != null) return; // その間に別のアカウントに切り替わった
      await ref.read(sessionStoreProvider).saveToken(token, DateTime.now().add(TraccarClient.tokenLifetime));
      s.token = token;
      await s.client.revokeToken(old);
    } catch (_) {
      // 通信できなければ次回の起動でやり直す
    }
  }

  /// 前回ログアウトしたときに通信できず、無効にできなかったトークンを無効にする（同じサーバーの分だけ）
  Future<void> _revokePending(AuthSession s) async {
    final store = ref.read(sessionStoreProvider);
    try {
      final pending = await store.readPendingRevokes();
      if (pending.isEmpty) return;
      final left = <({String server, String token})>[];
      for (final p in pending) {
        if (p.server != s.server || !await s.client.revokeToken(p.token)) left.add(p);
      }
      await store.savePendingRevokes(left);
    } catch (_) {}
  }

  /// 無効にできなかったトークンを覚えておく（最大 10 件）
  Future<void> _rememberPendingRevoke(String server, String token) async {
    final store = ref.read(sessionStoreProvider);
    try {
      final pending = [...await store.readPendingRevokes(), (server: server, token: token)];
      await store.savePendingRevokes(pending.length > 10 ? pending.sublist(pending.length - 10) : pending);
    } catch (_) {}
  }

  /// セッション切れのとき、保存済みトークンで自動的にログインし直すようにする
  AuthSession _attach(AuthSession s) {
    s.client.onSessionExpired = () async {
      try {
        await s.client.loginWithToken(s.token);
        return true;
      } on ApiException catch (e) {
        if (e.unauthorized && state.value == s) {
          // トークン自体が無効（管理画面で削除された・期限切れ）→ ログイン画面へ
          await ref.read(sessionStoreProvider).clearToken();
          state = const AsyncData(null);
        }
        return false;
      }
    };
    return s;
  }

  /// [code] は 2 段階認証の確認コード（必要なときだけ）
  Future<void> login({required String server, required String email, required String password, String? code}) async {
    final url = TraccarClient.normalizeServerUrl(server);
    final problem = TraccarClient.urlProblem(url);
    if (problem != null) throw ApiException(problem);
    final client = TraccarClient(url);
    final user = await client.login(email.trim(), password, code: code?.trim());
    String? token;
    try {
      token = await client.createToken();
      await ref.read(sessionStoreProvider).save(
            server: url,
            token: token,
            email: email.trim(),
            tokenExpires: DateTime.now().add(TraccarClient.tokenLifetime),
          );
    } catch (_) {
      // ログインはできたがトークンの発行・保存に失敗 → サーバー側に残さないよう後始末
      await client.logout(token: token);
      rethrow;
    }
    final session = _attach(AuthSession(client: client, user: user, token: token, email: email.trim()));
    state = AsyncData(session);
    _revokePending(session);
  }

  /// セッション切れのとき、保存済みトークンでログインし直す
  Future<bool> refreshSession() async {
    final s = state.value;
    if (s == null) return false;
    return await s.client.onSessionExpired?.call() ?? false;
  }

  /// ログアウト。サーバー側でもログイン用の鍵を無効にできたら true
  Future<bool> logout() async {
    final s = state.value;
    var revoked = true;
    if (s != null) {
      s.client.onSessionExpired = null;
      revoked = await s.client.logout(token: s.token);
      if (!revoked) await _rememberPendingRevoke(s.server, s.token);
    }
    await ref.read(sessionStoreProvider).clearToken();
    await PhoneNotifier.instance.cancelAll(); // 家族で使い回すスマホに、前の人の通知を残さない
    state = const AsyncData(null);
    return revoked;
  }

  /// 自動ログインできないとき、保存したログイン情報を消してログイン画面に戻る
  Future<void> forgetSavedLogin() async {
    final store = ref.read(sessionStoreProvider);
    try {
      final saved = await store.read();
      final server = saved.server, token = saved.token;
      if (server != null && token != null && TraccarClient.isAllowedUrl(server)) {
        // つながらないことが多いので待たずに、次にログインしたときに無効にする
        await _rememberPendingRevoke(server, token);
      }
      await store.clearToken();
    } catch (_) {}
    await PhoneNotifier.instance.cancelAll();
    state = const AsyncData(null);
  }

  void retry() => ref.invalidateSelf();
}

// 自動ログインに失敗したら、Riverpod の自動やり直しはせず、すぐに
// 「もう一度試す／別のサーバーでログイン」を選べる画面を出す
final authProvider = AsyncNotifierProvider<AuthNotifier, AuthSession?>(AuthNotifier.new, retry: (_, _) => null);
