// Windows 版の動作確認（テスト用 Traccar サーバーにつないで、実際に操作する）
//
// ログイン情報はソースに書かず、実行時に --dart-define で渡します:
//   flutter test integration_test -d windows `
//     --dart-define=TRACCAR_URL=http://localhost:8082 `
//     --dart-define=TRACCAR_EMAIL=... --dart-define=TRACCAR_PASSWORD=... `
//     --dart-define=SCREENSHOT_DIR=E:\TrackOne\docs\screenshots   # 任意: 画面を PNG で保存
//
// 確認すること: ログイン → トークン保存 → 自動ログイン、広い画面のホーム（一覧＋地図）、
// 端末「テスト車」の履歴再生（停車地点・走行距離などの読み込み）、
// 位置共有のリンク作成・コマンド画面・端末の設定・SMS の文面コピー（PC は SMS を送れないのでコピー）
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:trackone_japan/app.dart';
import 'package:trackone_japan/core/state/auth.dart';
import 'package:trackone_japan/features/commands/commands_page.dart';
import 'package:trackone_japan/features/device/device_edit_page.dart';
import 'package:trackone_japan/features/home/device_card.dart';
import 'package:trackone_japan/features/home/device_list_view.dart';
import 'package:trackone_japan/features/home/home_page.dart';
import 'package:trackone_japan/features/home/wide_home_layout.dart';
import 'package:trackone_japan/features/login/login_page.dart';
import 'package:trackone_japan/features/replay/replay_page.dart';
import 'package:trackone_japan/features/sms/sms_setup_page.dart';

const _url = String.fromEnvironment('TRACCAR_URL', defaultValue: 'http://localhost:8082');
const _email = String.fromEnvironment('TRACCAR_EMAIL');
const _password = String.fromEnvironment('TRACCAR_PASSWORD');
const _screenshotDir = String.fromEnvironment('SCREENSHOT_DIR');
const _carName = 'テスト車';
const _carImei = '900001'; // テスト用サーバーの「テスト車」
const _osmandPort = 5055; // OsmAnd 方式（テスト位置の送信用）

final _shotKey = GlobalKey();

/// 実時間で待ちながら、見つかるまで画面を更新する
Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  // 原因を調べやすいよう、画面に出ている文字を書き出す
  final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().toList();
  fail('見つかりませんでした: $finder 画面の文字: $texts');
}

/// 地図タイルなどの読み込みを、実時間で少し待つ
Future<void> wait(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// 画面を PNG で保存（SCREENSHOT_DIR を指定したときだけ）
Future<void> screenshot(WidgetTester tester, String name) async {
  if (_screenshotDir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_screenshotDir${Platform.pathSeparator}$name.png');
    await file.writeAsBytes(png!.buffer.asUint8List());
    debugPrint('screenshot: ${file.path} (${image.width}x${image.height})');
  });
}

/// 「昨日」に停車を含む走行記録がなければ、テスト用サーバーに送って作る（日付が変わってもテストが通るように）
Future<void> ensureYesterdayRoute() async {
  final http = HttpClient();
  final auth = 'Basic ${base64.encode(utf8.encode('$_email:$_password'))}';
  Future<String> get(String path) async {
    final req = await http.getUrl(Uri.parse('$_url$path'));
    req.headers.set('Authorization', auth);
    req.headers.set('Accept', 'application/json');
    final res = await req.close();
    return res.transform(utf8.decoder).join();
  }

  try {
    final devices = jsonDecode(await get('/api/devices')) as List;
    final car = devices.firstWhere((d) => d['uniqueId'] == _carImei, orElse: () => null);
    if (car == null) return;
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day - 1);
    final from = day.add(const Duration(hours: 9)).toUtc().toIso8601String();
    final to = day.add(const Duration(hours: 12)).toUtc().toIso8601String();
    final stops = jsonDecode(await get('/api/reports/stops?deviceId=${car['id']}&from=$from&to=$to')) as List;
    if (stops.isNotEmpty) return;

    // 9:30 から東京駅 → 皇居の北で 8 分停車 → 新宿方面へ、30 秒ごとに送る
    var t = day.add(const Duration(hours: 9, minutes: 30));
    Future<void> send(double lat, double lon, double knots) async {
      final q = 'id=$_carImei&lat=$lat&lon=$lon&speed=$knots&timestamp=${t.millisecondsSinceEpoch ~/ 1000}';
      final res = await (await http.getUrl(Uri.parse('http://localhost:$_osmandPort/?$q'))).close();
      await res.drain<void>();
    }

    const start = (35.6812, 139.7671), mid = (35.6905, 139.7505), end = (35.6896, 139.7006);
    for (var i = 0; i <= 20; i++) {
      await send(start.$1 + (mid.$1 - start.$1) * i / 20, start.$2 + (mid.$2 - start.$2) * i / 20, i == 20 ? 0 : 15);
      t = t.add(const Duration(seconds: 30));
    }
    for (var i = 0; i < 8; i++) {
      await send(mid.$1, mid.$2, 0);
      t = t.add(const Duration(minutes: 1));
    }
    for (var i = 1; i <= 30; i++) {
      await send(mid.$1 + (end.$1 - mid.$1) * i / 30, mid.$2 + (end.$2 - mid.$2) * i / 30, 15);
      t = t.add(const Duration(seconds: 30));
    }
  } finally {
    http.close();
  }
}

Widget _app() => RepaintBoundary(key: _shotKey, child: const ProviderScope(child: TrackOneApp()));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows: ログイン・自動ログイン・広い画面のホーム・履歴再生', (tester) async {
    expect(_email.isNotEmpty && _password.isNotEmpty, isTrue, reason: '--dart-define で TRACCAR_EMAIL / TRACCAR_PASSWORD を渡してください');
    await tester.runAsync(ensureYesterdayRoute);

    // 1) 保存済みのログイン情報を消してから起動 → ログイン画面
    await const FlutterSecureStorage().deleteAll();
    await tester.pumpWidget(_app());
    await pumpUntil(tester, find.byType(LoginPage));

    // 2) ログイン
    await tester.enterText(find.widgetWithText(TextFormField, 'サーバー URL'), _url);
    await tester.enterText(find.widgetWithText(TextFormField, 'メールアドレス'), _email);
    await tester.enterText(find.widgetWithText(TextFormField, 'パスワード'), _password);
    await tester.tap(find.widgetWithText(FilledButton, 'ログイン'));
    await pumpUntil(tester, find.byType(HomePage));
    await pumpUntil(tester, find.text(_carName));

    // 3) トークンが暗号化保存されている（パスワードは保存しない）
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored['token'], isNotEmpty);
    expect(stored['server_url'], _url);
    expect(stored.values.any((v) => v == _password), isFalse);

    // 4) アプリを作り直す（起動し直しと同じ）→ ログイン画面を出さずに自動ログイン
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(_app());
    await pumpUntil(tester, find.byType(HomePage));
    expect(find.byType(LoginPage), findsNothing);
    await pumpUntil(tester, find.text(_carName));

    // 5) PC の広い画面: 一覧と地図が並ぶ
    expect(find.byType(WideHomeLayout), findsOneWidget);
    expect(find.descendant(of: find.byType(DeviceListView), matching: find.text('Test phone')), findsOneWidget);

    // 一覧で「テスト車」を選ぶ → 端末カードに表示
    await tester.tap(find.descendant(of: find.byType(DeviceListView), matching: find.text(_carName)));
    await wait(tester, const Duration(seconds: 1));
    expect(find.descendant(of: find.byType(DeviceCard), matching: find.text(_carName)), findsOneWidget);
    await wait(tester, const Duration(seconds: 4)); // 地図タイルの読み込み
    await screenshot(tester, 'windows-home');

    // 6) 履歴再生（今日）: ルート・停車地点・走行距離などが読み込まれる
    await tester.tap(find.descendant(of: find.byType(DeviceCard), matching: find.text('履歴再生')));
    await pumpUntil(tester, find.byType(ReplayPage));
    // テスト用の走行記録は特定の日にしかないので、今日に記録がなければ「昨日」を見る
    // （今日に停車のある記録がなければ「昨日」を見る）
    final hasStops = find.textContaining(RegExp(r'^停車 [1-9]\d* 回'));
    final loading = find.descendant(of: find.byType(ReplayPage), matching: find.byType(CircularProgressIndicator));
    Future<void> waitLoaded() async {
      await wait(tester, const Duration(seconds: 1));
      await pumpUntil(tester, find.byWidgetPredicate((_) => loading.evaluate().isEmpty));
    }

    await waitLoaded();
    if (hasStops.evaluate().isEmpty) {
      await tester.tap(find.text('昨日'));
      await waitLoaded();
      await pumpUntil(tester, hasStops);
    }
    expect(find.text('この日の走行記録はありません'), findsNothing);
    expect(find.textContaining(RegExp(r'^\d+(\.\d+)? (km|m)$')), findsWidgets, reason: '走行距離');
    expect(find.text('走行時間'), findsOneWidget);
    expect(find.text('最高速度'), findsOneWidget);

    // 再生ボタンが押せる（2 地点以上ある）
    final play = find.byTooltip('再生');
    expect(play, findsOneWidget);
    await tester.tap(play);
    await wait(tester, const Duration(seconds: 2));
    expect(find.byTooltip('一時停止'), findsOneWidget);
    await tester.tap(find.byTooltip('一時停止'));
    await wait(tester, const Duration(seconds: 3)); // 地図タイルの読み込み
    await screenshot(tester, 'windows-replay');

    // 7) GPX 書き出し: Windows は保存ダイアログ（ここではダイアログの代わりに保存先を返す）
    final dir = await Directory.systemTemp.createTemp('trackone_gpx_');
    FileSelectorPlatform.instance = _FakeSaveDialog('${dir.path}${Platform.pathSeparator}route');
    await tester.tap(find.byTooltip('GPX ファイルで書き出し'));
    await pumpUntil(tester, find.textContaining('保存しました'));
    final gpx = File('${dir.path}${Platform.pathSeparator}route.gpx'); // 拡張子 .gpx を自動で付ける
    expect(gpx.existsSync(), isTrue);
    final text = gpx.readAsStringSync();
    expect(text, contains('<gpx'));
    expect('<trkpt'.allMatches(text).length, greaterThan(1));
    await dir.delete(recursive: true);

    // 8) ウィンドウを狭くすると、スマホと同じ「地図／一覧」の切り替えになる
    Navigator.of(tester.element(find.byType(ReplayPage))).pop();
    await pumpUntil(tester, find.byType(WideHomeLayout));
    tester.view.physicalSize = Size(600 * tester.view.devicePixelRatio, 800 * tester.view.devicePixelRatio);
    await wait(tester, const Duration(seconds: 1));
    expect(find.byType(WideHomeLayout), findsNothing);
    expect(find.text('地図'), findsOneWidget);
    expect(find.text('一覧'), findsOneWidget);
    tester.view.resetPhysicalSize();
    await wait(tester, const Duration(seconds: 1));
    expect(find.byType(WideHomeLayout), findsOneWidget);

    // 9) 端末の詳細（ボトムシート）。「保存しました」の表示がボタンに重なるので先に消す
    ScaffoldMessenger.of(tester.element(find.byType(HomePage))).removeCurrentSnackBar();
    await wait(tester, const Duration(milliseconds: 300));
    await tester.tap(find.descendant(of: find.byType(DeviceCard), matching: find.text('詳細')));
    await pumpUntil(tester, find.text('端末の詳細'));
    Navigator.of(tester.element(find.text('端末の詳細'))).pop();
    await wait(tester, const Duration(milliseconds: 600));

    // 10) 位置共有: リンクを作ってコピー（PC には「送る」ボタンが無い）
    await tester.tap(find.descendant(of: find.byType(DeviceCard), matching: find.text('共有')));
    await pumpUntil(tester, find.text('共有リンクを作る'));
    await wait(tester, const Duration(milliseconds: 600)); // シートが下から出てくるのを待つ
    await tester.ensureVisible(find.text('共有リンクを作る'));
    await tester.pump();
    await tester.tap(find.text('共有リンクを作る'));
    await pumpUntil(tester, find.text('コピー'));
    expect(find.widgetWithText(FilledButton, '送る'), findsNothing);
    await tester.ensureVisible(find.text('コピー'));
    await tester.pump();
    await tester.tap(find.text('コピー'));
    await pumpUntil(tester, find.text('コピーしました'));
    final shared = await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain));
    expect(shared?.text, startsWith('$_url/?token='));
    Navigator.of(tester.element(find.text('コピーしました'))).pop();
    await wait(tester, const Duration(milliseconds: 600));

    // 11) コマンド画面が開く（送信はしない）
    await tester.tap(find.descendant(of: find.byType(DeviceCard), matching: find.text('コマンド')));
    await pumpUntil(tester, find.byType(CommandsPage));
    await pumpUntil(tester, find.text('任意のコマンド'));
    Navigator.of(tester.element(find.byType(CommandsPage))).pop();
    await wait(tester, const Duration(milliseconds: 600));

    // 12) 端末の設定 → SMS の文面は PC ではコピーになる
    await tester.tap(find.descendant(of: find.byType(DeviceCard), matching: find.text('詳細')));
    await pumpUntil(tester, find.text('端末の設定を変更'));
    await wait(tester, const Duration(milliseconds: 600));
    await tester.ensureVisible(find.text('端末の設定を変更'));
    await tester.pump();
    await tester.tap(find.text('端末の設定を変更'));
    await pumpUntil(tester, find.byType(DeviceEditPage));
    expect(find.widgetWithText(TextFormField, _carName), findsOneWidget);
    await tester.ensureVisible(find.text('SMS で発信機を設定する'));
    await tester.tap(find.text('SMS で発信機を設定する'));
    await pumpUntil(tester, find.byType(SmsSetupPage));
    await tester.tap(find.text('状態の確認'));
    await pumpUntil(tester, find.widgetWithText(FilledButton, 'コピー'));
    await wait(tester, const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, 'コピー'));
    await pumpUntil(tester, find.textContaining('文面をコピーしました'));
    final sms = await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain));
    expect(sms?.text, 'STATUS#');
    Navigator.of(tester.element(find.byType(SmsSetupPage))).pop();
    await wait(tester, const Duration(milliseconds: 600));
    Navigator.of(tester.element(find.byType(DeviceEditPage))).pop();
    await wait(tester, const Duration(milliseconds: 600));

    // 13) マイページ: アプリのバージョン（package_info_plus）が Windows でも取れる
    await tester.tap(find.byTooltip('マイページ'));
    await pumpUntil(tester, find.textContaining(RegExp(r'^TrackOne Japan \d+\.\d+\.\d+')));
    expect(find.text('http://localhost:8082'), findsWidgets);
    expect(tester.takeException(), isNull);

    // 14) 後片付け: ログアウトして、テストで作ったログイン用の鍵をサーバー側でも無効にする
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    final revoked = await tester.runAsync(() => container.read(authProvider.notifier).logout());
    expect(revoked, isTrue);
  });
}

/// 保存ダイアログの代わりに、決まった保存先を返す
class _FakeSaveDialog extends FileSelectorPlatform {
  _FakeSaveDialog(this.path);
  final String path;

  @override
  Future<FileSaveLocation?> getSaveLocation({List<XTypeGroup>? acceptedTypeGroups, SaveDialogOptions options = const SaveDialogOptions()}) async {
    expect(options.suggestedName, endsWith('.gpx'));
    expect(acceptedTypeGroups?.first.extensions, contains('gpx'));
    return FileSaveLocation(path);
  }
}
