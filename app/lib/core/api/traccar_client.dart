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
    // 応答は文字列で受け取り、成功したときだけ JSON として読む。
    // （Traccar のエラー応答は JSON として読めないことがあり、自動で読むと 401 などのエラーの種類が失われるため）
    _dio = Dio(BaseOptions(
      responseType: ResponseType.plain,
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

  /// セッション（Cookie）が切れたときに呼ばれ、保存済みトークンでログインし直す。
  /// true を返したら、失敗したリクエストを 1 回だけやり直す。
  Future<bool> Function()? onSessionExpired;
  Future<bool>? _refreshing; // 同時に何本 401 が来ても、ログインし直しは 1 回だけ

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

  /// http:// は PC 内・LAN 内のテスト用だけ許可する（ホスト名ではなく IP アドレスで判定）
  static bool isAllowedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    final h = uri.host;
    if (h == 'localhost') return true;
    final ip = InternetAddress.tryParse(h);
    if (ip == null || ip.type != InternetAddressType.IPv4) return ip?.isLoopback ?? false;
    final b = ip.rawAddress;
    return b[0] == 127 || b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31);
  }

  // ---------- 認証 ----------

  Future<User> login(String email, String password) async {
    final res = await _call(
        () => _dio.post('/api/session',
            data: {'email': email, 'password': password}, options: Options(contentType: Headers.formUrlEncodedContentType)),
        auth: _AuthKind.password);
    return User.fromJson(_json(res) as Map<String, dynamic>);
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
    final res = await _call(() => _dio.get('/api/session', queryParameters: {'token': token}), auth: _AuthKind.token);
    return User.fromJson(_json(res) as Map<String, dynamic>);
  }

  Future<void> logout({String? token}) async {
    if (token != null) {
      // トークンの無効化にはログイン中のセッションが必要なので、切れていたら先につなぎ直す
      try {
        await loginWithToken(token);
      } catch (_) {}
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
    return (_json(res) as List).map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Position>> getPositions() async {
    final res = await _call(() => _dio.get('/api/positions'));
    return (_json(res) as List).map((e) => Position.fromJson(e as Map<String, dynamic>)).toList();
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
    return (_json(res) as List).map((e) => TrackerEvent.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------- 履歴（段階2） ----------

  Map<String, dynamic> _range(int deviceId, DateTime from, DateTime to) => {
        'deviceId': deviceId,
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
      };

  Future<List<dynamic>> _report(String name, int deviceId, DateTime from, DateTime to) async {
    final res = await _call(() => _dio.get('/api/reports/$name', queryParameters: _range(deviceId, from, to)));
    return _json(res) as List;
  }

  /// 期間内の位置（走行ルート）
  Future<List<Position>> getRoute(int deviceId, DateTime from, DateTime to) async =>
      (await _report('route', deviceId, from, to)).map((e) => Position.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<StopReport>> getStops(int deviceId, DateTime from, DateTime to) async =>
      (await _report('stops', deviceId, from, to)).map((e) => StopReport.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<TripReport>> getTrips(int deviceId, DateTime from, DateTime to) async =>
      (await _report('trips', deviceId, from, to)).map((e) => TripReport.fromJson(e as Map<String, dynamic>)).toList();

  Future<SummaryReport?> getSummary(int deviceId, DateTime from, DateTime to) async {
    final list = await _report('summary', deviceId, from, to);
    return list.isEmpty ? null : SummaryReport.fromJson(list.first as Map<String, dynamic>);
  }

  // ---------- アラーム・通知（段階3） ----------

  /// 期間内のイベント（複数端末まとめて）
  Future<List<TrackerEvent>> getEvents(List<int> deviceIds, DateTime from, DateTime to) async {
    if (deviceIds.isEmpty) return [];
    final res = await _call(() => _dio.get('/api/reports/events',
        queryParameters: {'deviceId': deviceIds, 'from': from.toUtc().toIso8601String(), 'to': to.toUtc().toIso8601String()},
        options: Options(listFormat: ListFormat.multi)));
    return (_json(res) as List).map((e) => TrackerEvent.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Position?> getPosition(int positionId) async {
    if (positionId == 0) return null;
    final res = await _call(() => _dio.get('/api/positions', queryParameters: {'id': positionId}));
    final list = _json(res) as List;
    return list.isEmpty ? null : Position.fromJson(list.first as Map<String, dynamic>);
  }

  Future<List<Geofence>> getGeofences() async {
    final res = await _call(() => _dio.get('/api/geofences'));
    return (_json(res) as List).map((e) => Geofence.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------- エリア（段階4） ----------

  /// 端末に割り当てられているエリア
  Future<List<Geofence>> getGeofencesForDevice(int deviceId) async {
    final res = await _call(() => _dio.get('/api/geofences', queryParameters: {'deviceId': deviceId}));
    return (_json(res) as List).map((e) => Geofence.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Geofence> createGeofence({required String name, required String area}) async {
    final res = await _call(() => _dio.post('/api/geofences', data: {'name': name, 'area': area, 'attributes': <String, dynamic>{}}));
    return Geofence.fromJson(_json(res) as Map<String, dynamic>);
  }

  /// 名前と形だけを変える（説明・カレンダーなど管理画面で付けた項目はそのまま）
  Future<Geofence> updateGeofence(Geofence g, {required String name, required String area}) async {
    final body = {...g.raw, 'id': g.id, 'name': name, 'area': area};
    final res = await _call(() => _dio.put('/api/geofences/${g.id}', data: body));
    return Geofence.fromJson(_json(res) as Map<String, dynamic>);
  }

  Future<void> deleteGeofence(int id) async {
    await _call(() => _dio.delete('/api/geofences/$id'));
  }

  /// 端末にエリアを割り当てる／外す
  Future<void> linkGeofence(int deviceId, int geofenceId) async {
    await _call(() => _dio.post('/api/permissions', data: {'deviceId': deviceId, 'geofenceId': geofenceId}));
  }

  Future<void> unlinkGeofence(int deviceId, int geofenceId) async {
    await _call(() => _dio.delete('/api/permissions', data: {'deviceId': deviceId, 'geofenceId': geofenceId}));
  }

  Future<List<NotificationConfig>> getNotifications() async {
    final res = await _call(() => _dio.get('/api/notifications'));
    return (_json(res) as List).map((e) => NotificationConfig.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// サーバーで使える通知方法（web / mail / firebase など）
  Future<List<String>> getNotificators() async {
    final res = await _call(() => _dio.get('/api/notifications/notificators'));
    return (_json(res) as List).map((e) => (e as Map<String, dynamic>)['type'] as String).toList();
  }

  /// Traccar が定義している警報の種類（「警報」の通知は、ここに列挙した種類しか届かない）
  static const allAlarmKeys = [
    'general', 'sos', 'vibration', 'movement', 'lowspeed', 'overspeed', 'fallDown', 'lowPower', 'lowBattery', 'fault', //
    'powerOff', 'powerOn', 'door', 'lock', 'unlock', 'geofence', 'geofenceEnter', 'geofenceExit', 'gpsAntennaCut', //
    'accident', 'tow', 'idle', 'highRpm', 'hardAcceleration', 'hardBraking', 'hardCornering', 'laneChange', //
    'fatigueDriving', 'powerCut', 'powerRestored', 'jamming', 'temperature', 'parking', 'bonnet', 'footBrake', //
    'fuelLeak', 'tampering', 'removing',
  ];

  /// 全端末を対象にした通知設定を作る
  Future<NotificationConfig> createNotification(String type, List<String> notificators) async {
    final res = await _call(() => _dio.post('/api/notifications', data: {
          'type': type,
          'always': true,
          'notificators': notificators.join(','),
          'attributes': <String, dynamic>{if (type == 'alarm') 'alarms': allAlarmKeys.join(',')},
        }));
    return NotificationConfig.fromJson(_json(res) as Map<String, dynamic>);
  }

  /// 「警報」の通知に、届ける警報の種類（全種類）を設定し直す
  Future<void> repairAlarmNotification(NotificationConfig c) async {
    // サーバーから受け取った内容をそのまま送り返し、警報の種類だけを足す（他の項目を消さない）
    final body = c.toJson()..['attributes'] = {...c.attributes, 'alarms': allAlarmKeys.join(',')};
    await _call(() => _dio.put('/api/notifications/${c.id}', data: body));
  }

  Future<void> deleteNotification(int id) async {
    await _call(() => _dio.delete('/api/notifications/$id'));
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

  /// 成功した応答の本文を JSON として読む
  static dynamic _json(Response<dynamic> res) {
    final data = res.data;
    if (data is! String) return data;
    if (data.trim().isEmpty) return null;
    try {
      return jsonDecode(data);
    } on FormatException {
      throw ApiException('サーバーの応答を読み取れませんでした。サーバー URL が Traccar のものか確認してください');
    }
  }

  /// リクエストを実行し、失敗をわかりやすいエラーにする。
  /// ログイン以外で 401（セッション切れ）になったら、トークンでログインし直して 1 回だけやり直す。
  Future<Response<dynamic>> _call(Future<Response<dynamic>> Function() request, {_AuthKind auth = _AuthKind.none}) async {
    try {
      return await request();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && auth == _AuthKind.none && await _refreshSession()) {
        try {
          return await request();
        } on DioException catch (e2) {
          throw _toApiException(e2, auth);
        }
      }
      throw _toApiException(e, auth);
    }
  }

  Future<bool> _refreshSession() async {
    final refresh = onSessionExpired;
    if (refresh == null) return false;
    final running = _refreshing ??= refresh().catchError((_) => false).whenComplete(() => _refreshing = null);
    return running;
  }

  static ApiException _toApiException(DioException e, _AuthKind auth) {
    final code = e.response?.statusCode;
    if (code == 401) {
      return ApiException(
        auth == _AuthKind.password ? 'メールアドレスまたはパスワードが違います' : 'ログインの有効期限が切れました。もう一度ログインしてください',
        unauthorized: true,
      );
    }
    if (code != null) return ApiException('サーバーエラー（$code）');
    if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
      return ApiException('サーバーが応答しません。URL とネットワークを確認してください');
    }
    return ApiException('サーバーに接続できません。URL とネットワークを確認してください');
  }
}

/// 認証に関わるリクエストの種類（401 のときのメッセージとやり直しの判断に使う）
enum _AuthKind { none, password, token }
