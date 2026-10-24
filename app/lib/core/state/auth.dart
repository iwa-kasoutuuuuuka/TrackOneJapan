import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../api/traccar_client.dart';
import '../auth/session_store.dart';

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// ログイン中の情報
class AuthSession {
  AuthSession({required this.client, required this.user, required this.token, required this.email});
  final TraccarClient client;
  final User user;
  final String token;
  final String email;
  String get server => client.baseUrl;
}

/// ログイン状態。null = 未ログイン
class AuthNotifier extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() async {
    // 起動時: 保存済みトークンで自動ログイン
    final store = ref.read(sessionStoreProvider);
    ({String? server, String? token, String? email}) saved;
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
    final client = TraccarClient(saved.server!);
    try {
      final user = await client.loginWithToken(saved.token!);
      return _attach(AuthSession(client: client, user: user, token: saved.token!, email: saved.email ?? user.email));
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await store.clearToken();
        return null;
      }
      rethrow; // 通信エラーは「もう一度試す」か「別のサーバーでログイン」を選べる画面になる
    }
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

  Future<void> login({required String server, required String email, required String password}) async {
    final url = TraccarClient.normalizeServerUrl(server);
    if (!TraccarClient.isAllowedUrl(url)) {
      throw ApiException('URL は https:// で始まる必要があります（http:// は PC・LAN 内のテスト時のみ）');
    }
    final client = TraccarClient(url);
    final user = await client.login(email.trim(), password);
    String? token;
    try {
      token = await client.createToken();
      await ref.read(sessionStoreProvider).save(server: url, token: token, email: email.trim());
    } catch (_) {
      // ログインはできたがトークンの発行・保存に失敗 → サーバー側に残さないよう後始末
      await client.logout(token: token);
      rethrow;
    }
    state = AsyncData(_attach(AuthSession(client: client, user: user, token: token, email: email.trim())));
  }

  /// セッション切れのとき、保存済みトークンでログインし直す
  Future<bool> refreshSession() async {
    final s = state.value;
    if (s == null) return false;
    return await s.client.onSessionExpired?.call() ?? false;
  }

  Future<void> logout() async {
    final s = state.value;
    if (s != null) {
      s.client.onSessionExpired = null;
      await s.client.logout(token: s.token);
    }
    await ref.read(sessionStoreProvider).clearToken();
    state = const AsyncData(null);
  }

  /// 自動ログインできないとき、保存したログイン情報を消してログイン画面に戻る
  Future<void> forgetSavedLogin() async {
    try {
      await ref.read(sessionStoreProvider).clearToken();
    } catch (_) {}
    state = const AsyncData(null);
  }

  void retry() => ref.invalidateSelf();
}

// 自動ログインに失敗したら、Riverpod の自動やり直しはせず、すぐに
// 「もう一度試す／別のサーバーでログイン」を選べる画面を出す
final authProvider = AsyncNotifierProvider<AuthNotifier, AuthSession?>(AuthNotifier.new, retry: (_, _) => null);
