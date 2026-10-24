import 'package:flutter_test/flutter_test.dart';
import 'package:trackone_japan/core/event_labels.dart';
import 'package:trackone_japan/models/models.dart';

TrackerEvent _e(String type, [Map<String, dynamic> attrs = const {}]) =>
    TrackerEvent(id: 1, type: type, deviceId: 1, eventTime: DateTime(2026, 10, 24, 12), attributes: attrs);

void main() {
  test('警報の日本語化と分類', () {
    final sos = describeEvent(_e('alarm', {'alarm': 'sos'}));
    expect(sos.title, 'SOS');
    expect(sos.category, EventCategory.emergency);

    final cut = describeEvent(_e('alarm', {'alarm': 'powerCut'}));
    expect(cut.title, '電源が切断されました');
    expect(cut.category, EventCategory.power);

    expect(describeEvent(_e('alarm', {'alarm': 'unknownThing'})).title, '警報（unknownThing）');
  });

  test('エリアの出入り（エリア名あり・なし）', () {
    expect(describeEvent(_e('geofenceExit'), geofenceName: '自宅').title, '「自宅」エリアから出ました');
    expect(describeEvent(_e('geofenceEnter')).title, 'エリアに入りました');
  });

  test('速度超過は km/h で表示', () {
    expect(describeEvent(_e('deviceOverspeed', {'speed': 45.9})).title, '速度超過（85 km/h）');
  });

  test('通信・エンジン', () {
    expect(describeEvent(_e('deviceOffline')).title, '通信が途絶えました');
    expect(describeEvent(_e('ignitionOn')).category, EventCategory.engine);
  });

  test('移動開始・停車はアラームに含めない', () {
    expect(isQuietEvent('deviceMoving'), isTrue);
    expect(isQuietEvent('deviceStopped'), isTrue);
    expect(isQuietEvent('alarm'), isFalse);
  });

  test('日付の見出し', () {
    final now = DateTime(2026, 10, 24, 20);
    expect(dayHeader(DateTime(2026, 10, 24, 9), now: now), '今日　10月24日（土）');
    expect(dayHeader(DateTime(2026, 10, 23, 21), now: now), '昨日　10月23日（金）');
    expect(dayHeader(DateTime(2026, 10, 20, 8), now: now), '10月20日（火）');
  });

  test('おすすめの通知設定', () {
    final rec = notificationTypes.where((t) => t.recommended).map((t) => t.type).toSet();
    expect(rec, containsAll(['alarm', 'geofenceEnter', 'geofenceExit', 'deviceOverspeed', 'deviceOffline']));
  });

  test('「警報」の通知に警報の種類がないと修復対象になる', () {
    NotificationConfig c(String type, Map<String, dynamic> attrs) =>
        NotificationConfig(id: 1, type: type, always: true, notificators: 'web', attributes: attrs);
    expect(c('alarm', {}).missingAlarms, isTrue);
    expect(c('alarm', {'alarms': 'sos,vibration'}).missingAlarms, isFalse);
    expect(c('geofenceExit', {}).missingAlarms, isFalse);
    expect(c('alarm', {}).hasWeb, isTrue);
  });
}
