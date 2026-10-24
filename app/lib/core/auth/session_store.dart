import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// サーバー URL・ログイン用トークンを暗号化して保存する（パスワードは保存しない）
class SessionStore {
  SessionStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  static const _kServer = 'server_url';
  static const _kToken = 'token';
  static const _kEmail = 'email';
  static const _kMapType = 'map_type';

  Future<({String? server, String? token, String? email})> read() async {
    return (
      server: await _s.read(key: _kServer),
      token: await _s.read(key: _kToken),
      email: await _s.read(key: _kEmail),
    );
  }

  Future<void> save({required String server, required String token, required String email}) async {
    await _s.write(key: _kServer, value: server);
    await _s.write(key: _kToken, value: token);
    await _s.write(key: _kEmail, value: email);
  }

  /// ログアウト時はトークンだけ消す（次回のために URL とメールは残す）
  Future<void> clearToken() => _s.delete(key: _kToken);

  Future<String?> readMapType() => _s.read(key: _kMapType);
  Future<void> saveMapType(String value) => _s.write(key: _kMapType, value: value);

  static const _kLastSeenEvents = 'last_seen_events';
  static const _kPhoneNotify = 'phone_notify';

  /// アラームを最後に見た時刻（これより新しいものを未読とする）
  Future<DateTime?> readLastSeenEvents() async {
    final v = await _s.read(key: _kLastSeenEvents);
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<void> saveLastSeenEvents(DateTime t) => _s.write(key: _kLastSeenEvents, value: t.toUtc().toIso8601String());

  /// このスマホに通知を表示するか（初期値: する）
  Future<bool> readPhoneNotify() async => (await _s.read(key: _kPhoneNotify)) != 'off';
  Future<void> savePhoneNotify(bool on) => _s.write(key: _kPhoneNotify, value: on ? 'on' : 'off');
}
