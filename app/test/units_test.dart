import 'package:flutter_test/flutter_test.dart';
import 'package:trackone_japan/core/api/traccar_client.dart';
import 'package:trackone_japan/core/state/tracking.dart';
import 'package:trackone_japan/core/units.dart';
import 'package:trackone_japan/features/home/device_status.dart';
import 'package:trackone_japan/models/models.dart';

void main() {
  group('Units', () {
    test('ノットを km/h に換算', () {
      expect(Units.knotsToKmh(10), closeTo(18.52, 0.001));
      expect(Units.speedKmh(20), '37 km/h');
    });

    test('長さの表示', () {
      expect(Units.duration(const Duration(seconds: 30)), '1分未満');
      expect(Units.duration(const Duration(minutes: 23)), '23分');
      expect(Units.duration(const Duration(hours: 2, minutes: 5)), '2時間5分');
      expect(Units.duration(const Duration(hours: 3)), '3時間');
      expect(Units.duration(const Duration(days: 2, hours: 1)), '2日');
    });

    test('何分前の表示', () {
      final now = DateTime(2026, 10, 24, 12, 0);
      expect(Units.ago(now.subtract(const Duration(seconds: 10)), now: now), 'たった今');
      expect(Units.ago(now.subtract(const Duration(minutes: 5)), now: now), '5分前');
      expect(Units.ago(now.subtract(const Duration(hours: 3)), now: now), '3時間前');
      expect(Units.ago(now.subtract(const Duration(days: 2)), now: now), '2日前');
    });

    test('日時の表示（今日は時刻のみ、それ以外は日付と曜日）', () {
      final now = DateTime(2026, 10, 24, 12, 0);
      expect(Units.dateTime(DateTime(2026, 10, 24, 9, 5), now: now), '09:05');
      expect(Units.dateTime(DateTime(2026, 10, 23, 21, 47), now: now), '10月23日（金）21:47');
    });

    test('距離の表示', () {
      expect(Units.distanceKm(850), '850 m');
      expect(Units.distanceKm(42300), '42.3 km');
    });
  });

  group('サーバー URL', () {
    test('整形', () {
      expect(TraccarClient.normalizeServerUrl(' tracker.example.ts.net/ '), 'https://tracker.example.ts.net');
      expect(TraccarClient.normalizeServerUrl('http://localhost:8082//'), 'http://localhost:8082');
    });

    test('http は PC・LAN 内だけ許可', () {
      expect(TraccarClient.isAllowedUrl('https://tracker.example.ts.net'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://localhost:8082'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://192.168.1.20:8082'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://172.20.0.5:8082'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://example.com'), isFalse);
      expect(TraccarClient.isAllowedUrl('http://172.40.0.5'), isFalse);
      expect(TraccarClient.isAllowedUrl('ftp://localhost'), isFalse);
      // Android の配布版では http:// は使えない
      expect(TraccarClient.isAllowedUrl('http://localhost:8082', policy: HttpPolicy.none), isFalse);
      expect(TraccarClient.isAllowedUrl('https://tracker.example.ts.net', policy: HttpPolicy.none), isTrue);
      // 配布版の Windows: PC 内だけ。LAN 内の http:// には鍵を送らない
      expect(TraccarClient.isAllowedUrl('http://localhost:8082', policy: HttpPolicy.loopback), isTrue);
      expect(TraccarClient.isAllowedUrl('http://127.0.0.1:8082', policy: HttpPolicy.loopback), isTrue);
      expect(TraccarClient.isAllowedUrl('http://[::1]:8082', policy: HttpPolicy.loopback), isTrue);
      expect(TraccarClient.isAllowedUrl('http://192.168.1.20:8082', policy: HttpPolicy.loopback), isFalse);
      expect(TraccarClient.isAllowedUrl('http://10.0.0.5:8082', policy: HttpPolicy.loopback), isFalse);
      // ユーザー名・パスワード入りや ?・# 付きは受け付けない
      expect(TraccarClient.isAllowedUrl('https://user:pass@tracker.example.ts.net'), isFalse);
      expect(TraccarClient.isAllowedUrl('https://tracker.example.ts.net/?a=1'), isFalse);
      expect(TraccarClient.isAllowedUrl('https://tracker.example.ts.net/#x'), isFalse);
    });
  });

  test('住所の整形（Nominatim → 日本式の順番）', () {
    expect(formatAddress('エレベーター;2階, 千代田区, JP'), '千代田区 2階 エレベーター');
    expect(formatAddress('1丁目, 丸の内, 千代田区, 東京都, 100-0005, 日本'), '東京都 千代田区 丸の内 1丁目');
  });

  group('端末の状態', () {
    Device device({String status = 'online'}) => Device(
        id: 1, name: '車', uniqueId: '123', status: status, lastUpdate: null, positionId: 0, category: 'car', phone: null, model: null, disabled: false);
    Position position({bool? motion, double speed = 0}) => Position(
        id: 1,
        deviceId: 1,
        fixTime: null,
        valid: true,
        latitude: 35,
        longitude: 139,
        speed: speed,
        course: 0,
        address: null,
        attributes: {'motion': ?motion});

    test('オフライン', () {
      expect(DeviceStatusInfo.of(device(status: 'offline'), position(), null).label, 'オフライン');
    });
    test('走行中は速度を表示', () {
      expect(DeviceStatusInfo.of(device(), position(motion: true, speed: 20), null).label, '走行中 37 km/h');
    });
    test('停車中は停車時間を表示', () {
      final now = DateTime(2026, 10, 24, 12, 0);
      final info = DeviceStatusInfo.of(device(), position(motion: false), now.subtract(const Duration(minutes: 23)), now: now);
      expect(info.label, '停車中 23分');
    });
    test('停車開始が不明なら「停車中」のみ', () {
      expect(DeviceStatusInfo.of(device(), position(motion: false), null).label, '停車中');
    });
  });
}
