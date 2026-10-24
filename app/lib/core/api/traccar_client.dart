import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:web_socket_channel/io.dart';

import '../../models/models.dart';

/// アプリ向けのわかりやすいエラー
class ApiException implements Exception {
  ApiException(this.message, {this.unauthorized = false});
  final String message;
  final bool unauthorized;
  @override
  String toString() => message;
}

/// Traccar サーバーとの通信（REST + WebSocket）
class TraccarClient {
  TraccarClient(String serverUrl)
      : baseUrl = normalizeServerUrl(serverUrl),
        _cookies = CookieJar() {
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'application/json'},
    ));
    _dio.interceptors.add(CookieManager(_cookies));
  }

  final String baseUrl;
  final CookieJar _cookies;
  late final Dio _dio;

  /// 入力された URL を整える（末尾の / を除く、スキーム省略時は https）
  static String normalizeServerUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.contains('://')) url = 'https://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// http:// は PC 内・LAN 内のテスト用だけ許可する
  static bool isAllowedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    final h = uri.host;
    return h == 'localhost' ||
        h == '127.0.0.1' ||
        h.startsWith('192.168.') ||
        h.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h);
  }

  // ---------- 認証 ----------

  Future<User> login(String email, String password) async {
    final res = await _call(() => _dio.post('/api/session',
        data: {'email': email, 'password': password},
        options: Options(contentType: Headers.formUrlEncodedContentType)));
    return User.fromJson(res.data as Map<String, dynamic>);
  }

  /// 長期ログイン用トークンを発行（パスワードは保存しない）
  Future<String> createToken({Duration validFor = const Duration(days: 365)}) async {
    final expiration = DateTime.now().toUtc().add(validFor).toIso8601String();
    final res = await _call(() => _dio.post('/api/session/token',
        data: {'expiration': expiration},
        options: Options(contentType: Headers.formUrlEncodedContentType, responseType: ResponseType.plain)));
    return (res.data as String).trim();
  }

  Future<User> loginWithToken(String token) async {
    final res = await _call(() => _dio.get('/api/session', queryParameters: {'token': token}));
    return User.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> logout({String? token}) async {
    if (token != null) {
      try {
        await _dio.post('/api/session/token/revoke',
            data: {'token': token}, options: Options(contentType: Headers.formUrlEncodedContentType));
      } catch (_) {}
    }
    try {
      await _dio.delete('/api/session');
    } catch (_) {}
  }

  // ---------- データ ----------

  Future<List<Device>> getDevices() async {
    final res = await _call(() => _dio.get('/api/devices'));
    return (res.data as List).map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Position>> getPositions() async {
    final res = await _call(() => _dio.get('/api/positions'));
    return (res.data as List).map((e) => Position.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<String?> geocode(double lat, double lon) async {
    final res = await _call(() => _dio.get('/api/server/geocode',
        queryParameters: {'latitude': lat, 'longitude': lon}, options: Options(responseType: ResponseType.plain)));
    final text = (res.data as String?)?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// 停車時間の計算用に、移動開始・停車イベントを取得
  Future<List<TrackerEvent>> getMotionEvents(int deviceId, {Duration lookBack = const Duration(days: 7)}) async {
    final to = DateTime.now().toUtc();
    final from = to.subtract(lookBack);
    final res = await _call(() => _dio.get('/api/reports/events',
        queryParameters: {
          'deviceId': deviceId,
          'from': from.toIso8601String(),
          'to': to.toIso8601String(),
          'type': ['deviceMoving', 'deviceStopped'],
        },
        options: Options(listFormat: ListFormat.multi))); // type=a&type=b の形式
    return (res.data as List).map((e) => TrackerEvent.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------- リアルタイム ----------

  /// /api/socket に接続し、受信した JSON をそのまま流す
  Future<Stream<Map<String, dynamic>>> openSocket() async {
    final httpUri = Uri.parse(baseUrl);
    final wsUri = httpUri.replace(scheme: httpUri.scheme == 'https' ? 'wss' : 'ws', path: '${httpUri.path}/api/socket');
    final cookies = await _cookies.loadForRequest(httpUri);
    final channel = IOWebSocketChannel.connect(
      wsUri,
      headers: {if (cookies.isNotEmpty) HttpHeaders.cookieHeader: cookies.map((c) => '${c.name}=${c.value}').join('; ')},
      pingInterval: const Duration(seconds: 30),
    );
    await channel.ready;
    return channel.stream.map((data) {
      try {
        final decoded = jsonDecode(data as String);
        return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    });
  }

  // ---------- 共通 ----------

  Future<Response<dynamic>> _call(Future<Response<dynamic>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401) {
        throw ApiException('メールアドレスまたはパスワードが違います', unauthorized: true);
      }
      if (code != null) {
        throw ApiException('サーバーエラー（$code）');
      }
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
        throw ApiException('サーバーが応答しません。URL とネットワークを確認してください');
      }
      throw ApiException('サーバーに接続できません。URL とネットワークを確認してください');
    }
  }
}
