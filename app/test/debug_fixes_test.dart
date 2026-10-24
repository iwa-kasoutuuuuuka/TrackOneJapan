import 'package:flutter_test/flutter_test.dart';
import 'package:trackone_japan/core/api/traccar_client.dart';
import 'package:trackone_japan/core/theme.dart';
import 'package:trackone_japan/features/home/device_status.dart';
import 'package:trackone_japan/models/models.dart';

Device _device() => Device(
    id: 1, name: '車', uniqueId: '1', status: 'online', lastUpdate: null, positionId: 0, category: 'car', phone: null, model: null, disabled: false);

Position _pos({required bool motion, DateTime? fix, double speed = 20, bool valid = true}) => Position(
    id: 1, deviceId: 1, fixTime: fix, valid: valid, latitude: 35, longitude: 139, speed: speed, course: 0, address: null, attributes: {'motion': motion});

void main() {
  group('http を許可する相手（ホスト名ではなく IP で判定）', () {
    test('LAN 内の IP は許可', () {
      expect(TraccarClient.isAllowedUrl('http://10.0.0.5:8082'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://192.168.1.20'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://172.16.0.1'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://127.0.0.1:8082'), isTrue);
      expect(TraccarClient.isAllowedUrl('http://localhost:8082'), isTrue);
    });
    test('IP に見えるだけのホスト名は拒否', () {
      expect(TraccarClient.isAllowedUrl('http://10.example.com'), isFalse);
      expect(TraccarClient.isAllowedUrl('http://192.168.evil.com'), isFalse);
      expect(TraccarClient.isAllowedUrl('http://172.20.attacker.net'), isFalse);
      expect(TraccarClient.isAllowedUrl('http://8.8.8.8'), isFalse);
    });
  });

  group('走行中の表示', () {
    final now = DateTime(2026, 10, 25, 12, 0);
    test('最近の位置で動いていれば走行中', () {
      final info = DeviceStatusInfo.of(_device(), _pos(motion: true, fix: now.subtract(const Duration(minutes: 1))), null, now: now);
      expect(info.label, '走行中 37 km/h');
    });
    test('最後の位置が 5 分以上前なら、走行中のまま残さず停車中にする', () {
      final info = DeviceStatusInfo.of(_device(), _pos(motion: true, fix: now.subtract(const Duration(minutes: 7))), null, now: now);
      expect(info.label, '停車中 7分');
    });
  });

  test('GPS データなしは灰色', () {
    expect(gpsColor(null), AppColors.gray);
    expect(gpsLabel(null), '—');
  });
}
