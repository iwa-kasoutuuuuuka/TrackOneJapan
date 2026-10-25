# TrackOne Japan アプリ（Flutter）

GPS 発信機の位置を日本語で確認する Android / Windows アプリです。設計は [docs/05_アプリ設計.md](../docs/05_アプリ設計.md) を参照してください。

![段階1の画面](../docs/screenshots/app-stage1.png)

## できること（段階1〜6）

| 機能 | 内容 |
|---|---|
| ログイン | サーバー URL・メール・パスワード。パスワードは保存せず、1年有効のトークンを暗号化保存して次回から自動ログイン |
| 地図 | 国土地理院（標準・淡色・航空写真）と OpenStreetMap（日本語）を切替。端末の種類別マーカー、前/次の端末への移動 |
| 一覧 | 全端末の状態・住所・電池・エンジン・最終更新。名前/IMEI で検索、引っ張って更新 |
| 端末カード | 走行中（速度）/ 停車中（停車時間）/ オフライン、住所、GPS・エンジン・電池、最終更新 |
| リアルタイム更新 | Traccar の WebSocket で位置・状態を即時反映。切れたら自動で再接続 |
| 端末の詳細 | IMEI・機種・SIM 番号・座標・速度など |
| 履歴再生（段階2） | 日付選択（今日・昨日・カレンダー）、ルート表示、停車地点（番号・時刻・停車時間・住所）、再生・一時停止・シーク・速度 1x〜16x、走行距離・走行時間・最高速度、GPX 書き出し・共有 |
| アラーム（段階3） | 過去 7 日間のアラーム一覧（日本語・種類別の色・絞り込み・未読の印）、詳細（発生地点の地図・時刻・住所・速度）、ホームのベルに未読数、WebSocket でリアルタイム追加 |
| 通知（段階3） | 通知の設定画面（受け取る種類をサーバーの Traccar 通知として登録、おすすめ設定）、スマホの通知欄に表示（オリジナルの通知アイコン、タップで詳細）。アプリを終了しているときのプッシュ通知（Firebase）は未対応 |
| エリア（段階4） | エリア（ジオフェンス）の一覧・作成・編集・削除（円：中心と半径 50 m〜5 km／多角形：頂点をタップ）、対象の端末の割り当て、エリアの出入りの通知のオン・オフ、ホームの地図に表示。Traccar の WKT（緯度 経度の順）で保存 |
| コマンド（段階5） | 端末が対応するコマンドの一覧（`/api/commands/types`）を日本語で表示、任意の文面・送信間隔・SOS 番号などの入力、エンジン停止など危険な操作は 2 回確認。オフライン時はサーバーで保留（HTTP 202）、過去 7 日間の結果を表示 |
| 位置共有（段階5） | 期限付き（1 時間／24 時間／7 日間）の共有リンクを `/api/share/device` で作成し、共有シートで送る・コピー。localhost／LAN の URL では注意を表示 |
| 端末の追加・設定（段階5） | 名前・IMEI・アイコン（カテゴリ）・SIM の電話番号・機種・速度制限（km/h で入力し、Traccar の単位ノットで保存）、削除 |
| SMS 設定（段階5） | GT06 系の文面のひな形（接続先の変更・状態確認・位置・設定確認・送信間隔・再起動）を編集して、SMS アプリを宛先・文面入りで開く（Windows はコピー） |
| マイページ | アカウント、サーバー、地図の種類、画面の明るさ、アプリ情報（ライセンス）、ログアウト |
| ダークモード（段階6） | 明るい／暗い／端末の設定に合わせる。色は `AppPalette`（`context.pal`）で明暗を切り替え |
| 通信断の表示（段階6） | 切れてからの時間と「今すぐ再接続」、アプリに戻ったときの即時再接続・更新 |
| オリジナルアイコン | ホーム画面アイコン（アダプティブ・テーマアイコン対応）、起動画面、地図マーカー |

> **通知の仕組み**：Traccar は「web」方式の通知設定がある種類のイベントだけを WebSocket で配信します。アプリの通知設定画面は、全端末対象（`always: true`）・`web` の通知設定を作成／削除します。「警報（alarm）」の通知は `alarms` 属性に列挙した警報しか届けないため、全種類を列挙して作成し、属性がない既存の設定は自動で修復します。

## 開発環境（このリポジトリで使ったもの）

| ツール | 場所 |
|---|---|
| Flutter 3.47.8 | `C:\dev\flutter` |
| Android SDK（platform 36, build-tools 36.1.0, NDK 28.2） | `C:\dev\android-sdk`（環境変数 `ANDROID_HOME`） |
| Dart パッケージのキャッシュ | `C:\dev\pub-cache`（環境変数 `PUB_CACHE`） |
| JDK 21（Temurin） | 環境変数 `JAVA_HOME` |
| Android Studio | winget でインストール済み（任意） |

> E ドライブ（外付け HDD）は小さなファイルの書き込みが遅いため、ツール類は C ドライブに置いています。
> プロジェクトとライブラリが別ドライブのため、`android/gradle.properties` で `kotlin.incremental=false` にしています。

## ビルドと実行

```powershell
cd E:\TrackOne\app
flutter pub get
flutter test              # 単体テスト
flutter build apk --debug # → build\app\outputs\flutter-apk\app-debug.apk（開発版。配布版は下の「配布用のビルド」）
```

### テスト PC の Traccar とスマホをつないで試す

テスト PC の Traccar は PC の中（127.0.0.1:8082）でしか待ち受けていないので、USB 経由でスマホの `localhost:8082` を PC に転送します。

```powershell
adb devices                    # スマホが表示されることを確認（USB デバッグを許可）
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb reverse tcp:8082 tcp:8082  # スマホの localhost:8082 → PC の 8082
```

アプリのログイン画面で、サーバー URL に `http://localhost:8082` を入力します。
（`http://` は開発用ビルドでのみ使えます。リリース版は `https://` のみ）

位置の受信テスト（PC から送信。地図がすぐに動けば成功）:

```powershell
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:5055/?id=123456&lat=35.6905&lon=139.7005&speed=25&batt=76&sat=9&ignition=true&timestamp=$now"
```

### 履歴再生のテスト用データ

テスト用 Traccar に、古い時刻の位置を古い順に送ると履歴になります（OsmAnd 方式の `timestamp` に UNIX 時刻を指定）。
途中で 5 分以上同じ地点（速度 0）を送ると「停車」として記録されます。

### エミュレーターで試す

```powershell
$env:ANDROID_SDK_ROOT = 'C:\dev\android-sdk'
C:\dev\android-sdk\emulator\emulator.exe -avd TrackOneTest
```

## Windows 版（PC アプリ）

スマホ版と同じ機能（ログイン・地図・一覧・端末カード・リアルタイム更新・履歴再生・アラーム・通知の設定・マイページ）を、Windows のパソコンで使えます。
アイコンはスマホ版と同じオリジナルアイコン（`assets/icon/png/trackone.ico`）です。

![Windows 版のホーム](../docs/screenshots/windows-home.png)

![Windows 版の履歴再生](../docs/screenshots/windows-replay.png)

### ビルドのしかた

必要なもの: Flutter（上の表）と Visual Studio Build Tools 2022（「C++ によるデスクトップ開発」）。

```powershell
cd E:\TrackOne\app
flutter pub get
flutter build windows --release
```

できあがったアプリ: `app\build\windows\x64\runner\Release\TrackOneJapan.exe`

`Release` フォルダの中身（`TrackOneJapan.exe`・`data` フォルダ・`*.dll`）がまとめて 1 つのアプリです。
別の PC で使うときは、`Release` フォルダごとコピーして `TrackOneJapan.exe` を起動します（インストールは不要）。

> **「Building with plugins requires symlink support」と表示されたとき**
> Windows の「開発者モード」がオフだと、この警告が出てビルドできません。次のどちらかで解決します。
> 1. 設定 → システム → 開発者向け → 「開発者モード」をオンにする
> 2. 開発者モードをオンにしたくない場合は、`flutter pub get` のあとに次を実行してからビルドする
>    （管理者権限は不要。パッケージを追加・更新したらもう一度実行）
>    ```powershell
>    powershell -ExecutionPolicy Bypass -File tool\windows_link_plugins.ps1
>    ```

> **「atlstr.h」「atlbase.h」が見つからないというエラーについて**
> 一部のプラグイン（ログイン情報の暗号化保存・通知）は、Visual Studio の「C++ ATL」部品のヘッダーを読み込みます。
> この PC の Build Tools には ATL が入っていないため、使っている文字列変換だけを実装した代わりのヘッダーを
> `windows/atl_shim/` に用意し、ATL がないときだけ自動で使うようにしています（`windows/CMakeLists.txt`）。
> Visual Studio Installer で「C++ ATL」を追加した PC では、本物のヘッダーが使われます。

### ログインのしかた

| 使う PC | サーバー URL |
|---|---|
| サーバー（Traccar）が動いている PC そのもの | `http://localhost:8082` |
| 別の PC（Tailscale 経由） | スマホと同じ `https://…ts.net` の URL |

メールアドレスとパスワードはスマホ版と同じです。スマホ版と同じく、パスワードは保存せず、
ログイン用のトークンだけを Windows の暗号化機能で保存し、次回からは自動でログインします
（保存場所: `%APPDATA%\TrackOne Japan\TrackOne Japan`）。

### スマホ版との違い

| 項目 | Windows 版 |
|---|---|
| 画面の並び | ウィンドウの幅が広い（900 ピクセル以上）ときは、左に端末一覧、右に地図と端末カードを並べて表示。狭くすると、スマホと同じ「地図／一覧」の切り替えになります |
| GPX 書き出し | 共有シートの代わりに「名前を付けて保存」の画面が開き、選んだ場所に保存します |
| アラームの通知 | Windows の通知センターに「TrackOne Japan」として表示（オリジナルアイコン）。アプリを起動している間だけ届きます |
| 一覧の更新 | 位置や状態はリアルタイムで自動更新。手動で更新したいときは、一覧をマウスで下に引っ張ります（広い画面のとき） |
| 地図の操作 | マウスのホイールで拡大・縮小、ドラッグで移動 |
| 起動画面 | なし（ウィンドウが開いてすぐログイン画面または地図） |
| 位置共有・SMS 設定 | 共有シート・SMS アプリの代わりに、リンクや文面をクリップボードにコピー |

### 動作確認テスト（テスト用 Traccar を使う）

テスト PC の Traccar に実際にログインして、ホーム（一覧＋地図）、「テスト車」の履歴再生、位置共有リンクの作成とコピー、コマンド画面、端末の設定、SMS の文面のコピーまで自動で操作します（コマンドの送信や設定の保存はしません）。
ログイン情報はソースに書かず、実行時に渡します。

```powershell
cd E:\TrackOne\app
$c = Get-Content ..\server\windows\test-admin.local.txt -Encoding UTF8
$email = (($c | Select-String '^email:') -replace '^email:\s*', '').Trim()
$pass  = (($c | Select-String '^password:') -replace '^password:\s*', '').Trim()
flutter test integration_test -d windows `
  --dart-define=TRACCAR_URL=http://localhost:8082 `
  --dart-define=TRACCAR_EMAIL=$email --dart-define=TRACCAR_PASSWORD=$pass `
  --dart-define=SCREENSHOT_DIR=$((Resolve-Path ..\docs\screenshots).Path)
```

`SCREENSHOT_DIR` を付けると、`docs/screenshots/windows-home.png` と `windows-replay.png` を撮り直します。

## 配布用のビルド（リリース）

```powershell
cd E:\TrackOne\app
powershell -ExecutionPolicy Bypass -File tool\build_release.ps1
```

テスト → リリース版 APK → Windows 版の順にビルドし、`app\dist`（Git には入れない）に次のファイルを作ります。
これを GitHub の Releases に添付して配布します。

| ファイル | 内容 |
|---|---|
| `TrackOneJapan-<版>.apk` | Android 用。リリース鍵で署名（arm64・armv7・x86_64 入り） |
| `TrackOneJapan-<版>-windows.zip` | Windows 用。展開して `TrackOneJapan.exe` を起動 |
| `SHA256SUMS.txt` | ファイルのハッシュ（壊れていないかの確認用） |

### 版を上げるとき

`pubspec.yaml` の `version: 1.0.0+1` を上げます。`+` の後ろの数字（Android の versionCode）は **毎回必ず増やして** ください（同じか小さいと、スマホで上書き更新できません）。

### リリース用の署名鍵（大切）

| ファイル | 内容 |
|---|---|
| `E:\TrackOne\secrets\trackone-release.jks` | 署名鍵（Git には入れない） |
| `app\android\key.properties` | 鍵のパスワードと場所（Git には入れない） |

- **この 2 つを USB メモリやパスワード管理アプリなど、別の場所にも必ず保管してください。** 鍵をなくすと、同じアプリとして更新できなくなり、利用者全員にアンインストールしてもらう必要があります
- `key.properties` が無い PC でビルドすると、デバッグ用の鍵で署名されます（動作はしますが、配布版とは別のアプリ扱い）
- 鍵を別の PC に移すときは、`key.properties` の `storeFile` をその PC での鍵の場所に書き換えます

### 開発版と配布版の違い

| | 開発版（`flutter build apk --debug`） | 配布版（`build_release.ps1`） |
|---|---|---|
| 署名 | デバッグ用の鍵 | リリース鍵 |
| `http://` の URL | localhost・LAN 内なら使える（テスト用） | 使えない（`https://` のみ） |
| 速さ・サイズ | 遅い・大きい | 速い・小さい |

同じスマホに両方は入りません（署名が違うため）。切り替えるときはアンインストールしてから入れます。

## アイコンの作り直し

アイコン画像（`assets/icon/`）を差し替えたら:

```powershell
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

## フォルダ構成

```
lib/
  main.dart / app.dart        起動、テーマ、ログイン状態で画面を切替
  core/
    api/traccar_client.dart    Traccar の REST・WebSocket
    auth/session_store.dart    トークンの暗号化保存
    state/                     ログイン状態・端末と位置・地図の種類
    theme.dart / units.dart    配色、単位換算と日本語表記
  models/models.dart           Device / Position / Event / User
  features/
    login/                     ログイン画面
    home/                      地図・一覧・端末カード・詳細
    replay/                    履歴再生（画面と、日付範囲・再生・GPX の計算）
    alarms/                    アラーム一覧・詳細・通知の設定
    geofence/                  エリア（ジオフェンス）の一覧・作成・編集
    settings/                  マイページ
    commands/                  コマンドの一覧・送信・結果
    share/                     位置共有リンクの作成
    device/                    端末の追加・設定の変更・削除
    sms/                       SMS で発信機を設定（文面のひな形）
test/                          単体テスト（単位・URL・住所・状態・履歴再生の計算・アラームの日本語化・エリアの形・コマンド・共有リンク・SMS の文面）
core/event_labels.dart         イベント → 日本語・分類・色
core/geofence_shape.dart       エリアの形（円・多角形）と Traccar の WKT 形式の読み書き
core/command_labels.dart       コマンドの種類 → 日本語・説明・入力項目・危険な操作の印
core/notifications/            スマホの通知欄への表示（flutter_local_notifications）
widgets/base_map.dart          地図の背景タイルと出典表示（共通部品）
```
