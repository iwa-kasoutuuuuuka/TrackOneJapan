# TrackerOne APK 解析結果（第2版：REA による静的解析）

作成日: 2026-10-24
解析対象: TrackerOne 1.66.1（versionCode 1661 / minSdk 23 / targetSdk 36）
取得方法: 自分のスマホ（Play ストア版）から `adb pull`
解析ツール: REA 6.7.0 + jadx-headless-mcp 0.7.1（JDK 21）
APK の SHA-256: `52e65cfe7758961df945c8903c4a3ca2fab32206f6a8c4e22b679d0a88dd1003`

> 静的解析（コードを読むだけ）の結果です。アプリを実行した結果ではありません。

---

## 1. 結論（第1版からの更新点）

| 項目 | 結果 |
|---|---|
| 通信先 | WanWay のクラウド `iopgps.com`（`www.iopgps.com` / `h5.iopgps.com` / 共有ページ `share.xogps.com`） |
| API 数 | **129個**（ログイン、端末一覧、履歴、アラーム、ジオフェンス、コマンド、課金など） |
| 地図 | **Google Maps SDK** ＋ Google Places（住所検索）。中国系の地図（高德・百度）は未使用 |
| 通知 | Firebase Cloud Messaging（FCM） |
| 課金 | Stripe / PayPal / Google Play（更新料・サブスクリプション） |
| エラー収集 | Sentry |
| ログイン | メール＋パスワード、Google ログイン |
| 日本語 | **アプリ内に日本語の文字列は見当たらない**（英語・ドイツ語・スペイン語・ポーランド語などは確認） |
| アラーム種類・コマンド | **アプリには持たず、サーバーから端末の機種ごとに受け取る**方式 |

### 最重要の発見: 発信機の送信先は SMS で変えられる

「サーバー切替（DeviceSwitchIpActivity）」画面のコードを読むと、次の動きをしています。

1. API `getIpPort` で、WanWay サーバーから **端末機種ごとの設定文**（`ip` 版と `domain` 版の2種類）を受け取る
2. ユーザーがボタンを押すと、**スマホの SMS アプリをその文面入りで開く**
3. ユーザーが発信機の SIM の電話番号あてに送信すると、発信機の接続先が変わる

つまり **同じ仕組みで、発信機の送信先を自分の Traccar サーバーに変えられる**ということです。
お手持ちの TrackerOne アプリでこの画面を開くと、実際の設定文（例: `SERVER,1,ドメイン,ポート,0#` のような形式）を確認できます。これが自前サーバーへの切替時の雛形になります。

---

## 2. 画面一覧（Activity 約100画面、主要なもの）

| 分類 | 画面（クラス名） | 内容 |
|---|---|---|
| ログイン | LoginActivity / RegisterActivity / ForgetPasswordActivity | ログイン、新規登録、パスワード再設定 |
| ホーム | HomeActivity | 地図・一覧（TrackerOne のメイン） |
| 端末 | BindDeviceActivity / SwitchDeviceActivity / DeviceInfoActivity / DeviceSettingActivity / SwitchDeviceIconActivity | 端末登録（IMEI、QR 読取）、切替、詳細、設定、地図アイコン変更 |
| 履歴 | ReplayActivity / ReplayActivityV2 | 走行履歴の再生 |
| ジオフェンス | ElectricFenceActivity / RegionalFenceActivity / RegionalChoiceActivity / CheckFenceActivity | 円・多角形のフェンス、都道府県単位のフェンス |
| アラーム | AlarmListSingleDeviceActivity / AlarmDetailActivity / AlarmSettingActivity / AlarmEmailSettingActivity / ReceiveAlarmTypeActivity | アラーム一覧・詳細、プッシュ・メール通知の種類設定 |
| コマンド | InstructActivity / InstructSendActivity / InstructHistoryActivity / InstructShortCutActivity / QueryHistoryActivity | コマンド送信、履歴、ショートカット |
| サーバー切替 | DeviceSwitchIpActivity / DeviceModelSwitchActivity | SMS で接続先変更（上記） |
| 共有 | （API: shareCreate / shareList / shareRedeem / deviceLocationShare） | 位置共有リンク（share.xogps.com） |
| マイページ | MineActivity / SettingActivity / LanguageSelectActivity / UnitSelectActivity / MapSelectActivity / AccountSecurityActivity / AccountCancellationActivity / FeedbackActivity / AboutActivity | 設定、言語、単位（km/mile）、地図種類、退会など |
| 課金 | RenewMealChooseActivity / PurchaseActivity / OrderRecordActivity / BatchRechargeActivity | 更新プラン選択、購入、注文履歴、一括更新 |
| ペット・OBD | HomeAnimalActivity / AnimalFenceActivity / ObdEngineInfoActivity / ObdFuelSettingActivity など | ペット用端末、車の OBD 端末向け（別製品用） |

---

## 3. API 一覧（129個を機能別に整理）

| 機能 | 主な API 名 |
|---|---|
| アカウント | loginOverSea, registerOverSea, sendCodeOverSea, forgetPwdOverSea, updatePwdOverSea, userInfoOverSea, loginOutOverSea, accountCancellation, updateAppLanguage |
| 端末 | deviceListOverSea, deviceListCommon, deviceDetailCommon, getDeviceBrief, bindDeviceOverSea, deviceUnbindOverSea, deviceUpdateInfoCommon, changeIcon, getSupportDeviceModel |
| 位置・履歴 | getHomeInfoList, getReplayLocation, getReplayLastTime, getTrackList, getMileage, getTravelData, exportTracking2Email, queryAddressFromImei, poiList |
| アラーム | getAlarmList, getAlarmInfo, getDeviceAlarmInfo, queryDeviceAlarmCount, clearDeviceAlarmCount, getAlarmSettingTypes, saveAlarmSettingTypes, getServerAlarmSetting, saveAlarmSetting, (Email 版も同様), setSpeedLimit |
| ジオフェンス | getAllFence, addCityFence, deleteCityFence, getProvince, getCity |
| コマンド | instructionViewList, instructionShortCutViewList, instructionSend, commonInstructSend, instructionHistory, getDeviceModelInstruct, getIpPort |
| 端末設定 | getDeviceSettingInfo, setDeviceSettingInfo, deviceWifiList |
| 共有 | shareCreate, shareList, shareRedeem, deviceLocationShare |
| 課金 | renewalPriceList, createOrderNo, payOrder, payStatus, orderList, renewalSubScriptionList, renewalRefund ほか多数 |
| その他 | getAppVersion, feedbackV2, getCommonAd, ペット・OBD 関連 |

---

## 4. 端末から取得しているデータ項目

`DeviceDetailBean`（端末詳細）の主な項目:

- IMEI、端末名、機種（typeName）、ファームウェア、SIM の電話番号（deviceMobile）
- 住所（gpsAddress）、走行距離（mileage）
- 電池残量（batteryCapacity）、充電状態（chargeStatus）、内蔵電池の有無
- ドア状態（doorStatus / carDoorStatus）、エアコン状態（acStatus）、燃料（fuelLevel / fuelVolume / instantOil）
- 車両情報（ナンバー、VIN、所有者）
- 契約期限（platformEndtime / simEndTime / cloudEndTime）← 自作では不要

`AlarmInfoBean`（アラーム）: アラーム名、発生時刻、GPS 時刻、住所、IMEI、フェンス名
`AlarmTypeBean`: アラーム種類 ID と名前（**サーバーが機種ごとに返す**）
`FenceBean`: フェンス名、種類（円・多角形・地域）、トリガー（入る/出る/両方）、有効/無効、1回のみ

アプリ内の英語文字列から確認できたアラーム例:
ジオフェンス出入り、速度超過、SOS、ドア開閉、燃料レベル、振動、電源切断、低電池

---

## 5. 自作アプリへの反映

| TrackerOne の機能 | Traccar での対応 | 自作アプリでやること |
|---|---|---|
| 地図・端末一覧 | `/api/devices` + `/api/positions` + WebSocket（リアルタイム） | 地図（OpenStreetMap）に表示、日本語 UI |
| GPS強度・ACC・電池 | 位置データの `attributes`（sat / ignition / batteryLevel など） | 下部カードに表示 |
| 停車時間（Static 23min） | `motion` 属性と位置時刻から計算 | 表示ロジックを自作 |
| 走行履歴の再生 | `/api/reports/route`, `/api/reports/stops`, `/api/reports/trips` | 再生 UI（速度切替・シークバー） |
| ジオフェンス | `/api/geofences`（円・多角形） | 地図上で作成・編集 |
| アラーム | Traccar のイベント（geofenceEnter/Exit, overspeed, alarm=sos/vibration/powerCut/lowBattery 等） | 一覧・詳細・通知設定 |
| プッシュ通知 | Traccar の通知機能 → FCM | 受信して表示 |
| コマンド送信 | `/api/commands/send`（GT06: engineStop / engineResume / custom 等） | コマンド画面 |
| 位置共有 | Traccar の共有リンク（`/api/session/token` 等） | 共有ボタン |
| 端末登録（Binding） | `/api/devices` に IMEI を登録 | QR/IMEI 入力画面 |
| 課金（Renewal） | 不要 | 作らない（完全無料） |
| サーバー切替 | 不要（最初に1回 SMS で設定） | 設定手順を案内する画面があると便利 |

---

## 6. 次にやること

1. **お手持ちの発信機の機種名を確認**（本体ラベル、または TrackerOne の端末詳細画面）
2. TrackerOne の「サーバー切替」画面で **SMS 設定文の形式を確認**（送信はまだしない）
3. Traccar サーバーを用意（まずは PC 上で試す → 後で無料クラウドへ）
4. 発信機に SMS を送り、送信先を Traccar に変更 → 位置が届くか確認
   - ※ 切り替えると TrackerOne では見られなくなります。元に戻す設定文も控えておくこと
5. 位置が届いたら、日本語アプリ（Flutter 想定）の開発に着手

---

## 補足: 解析中に気づいた点

- アプリ内に、開発元の通知用トークン（DingTalk）やエラー収集用の接続情報が埋め込まれていました。他社の認証情報なので、**使用・公開はしません**。
- 取り出した APK（`apk/` フォルダ）は WanWay 社の著作物です。解析用に手元に置くだけにし、再配布はしないでください。
