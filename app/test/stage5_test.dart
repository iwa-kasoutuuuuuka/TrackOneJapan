import 'package:flutter_test/flutter_test.dart';
import 'package:trackone_japan/core/command_labels.dart';
import 'package:trackone_japan/features/device/device_edit_page.dart';
import 'package:trackone_japan/features/share/share_sheet.dart';
import 'package:trackone_japan/features/sms/sms_setup_page.dart';
import 'package:trackone_japan/models/models.dart';

void main() {
  group('コマンド', () {
    test('日本語の名前と危険なコマンドの印', () {
      expect(describeCommand('engineStop').label, 'エンジン停止');
      expect(describeCommand('engineStop').danger, isTrue);
      expect(describeCommand('factoryReset').danger, isTrue);
      expect(describeCommand('positionSingle').danger, isFalse);
      expect(describeCommand('unknownType').label, 'unknownType');
    });
    test('危険なコマンドは一覧の最後', () {
      final types = ['engineStop', 'custom', 'positionSingle', 'factoryReset', 'engineResume'];
      types.sort((a, b) => commandOrder(a).compareTo(commandOrder(b)));
      expect(types.first, 'positionSingle');
      expect(types.sublist(types.length - 2).toSet(), {'engineStop', 'factoryReset'});
    });
    test('一覧にない種類と、危険に見える任意のコマンドは危険として扱う', () {
      expect(describeCommand('outputControl').danger, isTrue);
      expect(isDangerousCommand('custom', text: 'STATUS#'), isFalse);
      expect(isDangerousCommand('custom', text: 'relay,1#'), isTrue);
      expect(isDangerousCommand('custom', text: 'DYD,000000#'), isTrue);
      expect(isDangerousCommand('custom', text: 'FACTORY#'), isTrue);
      expect(isDangerousCommand('positionSingle'), isFalse);
      expect(isDangerousCommand('engineStop'), isTrue);
    });
    test('送るときの属性', () {
      expect(commandAttributes('custom', text: 'STATUS#'), {'data': 'STATUS#'});
      expect(commandAttributes('positionPeriodic', seconds: 30), {'frequency': 30});
      expect(commandAttributes('engineStop'), isEmpty);
    });
  });

  group('位置共有', () {
    test('リンクの形（トークンは URL 用に変換）', () {
      expect(buildShareLink('https://pc.example.ts.net', 'ab+c/d'), 'https://pc.example.ts.net/?token=ab%2Bc%2Fd');
    });
    test('家の外から開けないサーバーを見分ける', () {
      expect(isLocalOnlyServer('http://localhost:8082'), isTrue);
      expect(isLocalOnlyServer('http://192.168.1.10:8082'), isTrue);
      expect(isLocalOnlyServer('https://pc.example.ts.net'), isFalse);
    });
  });

  group('端末の設定', () {
    test('カテゴリを選択肢に寄せる', () {
      expect(normalizeCategory('truck'), 'car');
      expect(normalizeCategory('scooter'), 'motorcycle');
      expect(normalizeCategory('animal'), 'animal');
      expect(normalizeCategory(null), 'default');
    });
    test('IMEI は 15 桁', () {
      expect(looksLikeImei('123456789012345'), isTrue);
      expect(looksLikeImei('12345'), isFalse);
    });
    test('速度制限はノットから km/h に換算', () {
      final d = Device(
        id: 1,
        name: '車',
        uniqueId: '1',
        status: 'online',
        lastUpdate: null,
        positionId: 0,
        category: 'car',
        phone: null,
        model: null,
        disabled: false,
        attributes: const {'speedLimit': 26.997840172786177},
      );
      expect(d.speedLimitKmh!.round(), 50);
    });
  });

  test('SMS の接続先の文面', () {
    final t = smsTemplates.first;
    expect(t.build('myhome.duckdns.org', '12345'), 'SERVER,1,myhome.duckdns.org,12345,0#');
    expect(t.build('', ''), 'SERVER,1,<ドメイン>,5023,0#');
    expect(t.warning, isNotNull);
  });
}
