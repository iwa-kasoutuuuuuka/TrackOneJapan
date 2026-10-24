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
    final saved = await ref.read(sessionStoreProvider).read();
    if (saved.server == null || saved.token == null) return null;
    final client = TraccarClient(saved.server!);
    try {
      final user = await client.loginWithToken(saved.token!);
      return AuthSession(client: client, user: user, token: saved.token!, email: saved.email ?? user.email);
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await ref.read(sessionStoreProvider).clearToken();
        return null;
      }
      rethrow; // 通信エラーは再試行できるようにエラーとして返す
    }
  }

  Future<void> login({required String server, required String email, required String password}) async {
    final url = TraccarClient.normalizeServerUrl(server);
    if (!TraccarClient.isAllowedUrl(url)) {
      throw ApiException('URL は https:// で始まる必要があります（http:// は PC・LAN 内のテスト時のみ）');
    }
    final client = TraccarClient(url);
    final user = await client.login(email.trim(), password);
    final token = await client.createToken();
    await ref.read(sessionStoreProvider).save(server: url, token: token, email: email.trim());
    state = AsyncData(AuthSession(client: client, user: user, token: token, email: email.trim()));
  }

  /// セッション切れのとき、保存済みトークンでログインし直す
  Future<bool> refreshSession() async {
    final s = state.value;
    if (s == null) return false;
    try {
      await s.client.loginWithToken(s.token);
      return true;
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await ref.read(sessionStoreProvider).clearToken();
        state = const AsyncData(null);
      }
      return false;
    }
  }

  Future<void> logout() async {
    final s = state.value;
    if (s != null) await s.client.logout(token: s.token);
    await ref.read(sessionStoreProvider).clearToken();
    state = const AsyncData(null);
  }

  void retry() => ref.invalidateSelf();
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthSession?>(AuthNotifier.new);
