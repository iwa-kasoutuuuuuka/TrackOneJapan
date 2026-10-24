<p align="center">
  <img src="assets/icon/png/icon-256.png" width="128" alt="TrackOne Japan アイコン">
</p>

<h1 align="center">TrackOne Japan</h1>

<p align="center">GPS 発信機の位置を、自分のサーバーで・日本語で・無料で見るためのシステム</p>

---

## これは何？

WanWay 社の GPS 発信機（TrackerOne アプリで使う端末）を、**メーカーのクラウドではなく自分で用意したサーバー**につなぎ、日本語の画面で位置を確認できるようにするプロジェクトです。

- 完全無料（オープンソースのソフトと無料サービスのみ。発信機の SIM 通信費は別）
- 日本語対応
- 常時起動の Windows 11 PC 1台で動作
- オリジナルアイコン

```
[GPS 発信機] ──(GT06)──▶ [Windows 11 PC: Traccar + PostgreSQL] ◀──(HTTPS)── [スマホ / ブラウザ]
```

## 現在の状況

| 段階 | 状態 |
|---|---|
| TrackerOne の解析 | 完了（[01](docs/01_TrackerOne解析レポート.md)、[02](docs/02_APK解析結果.md)） |
| サーバー設計・構築スクリプト | 完了（[03](docs/03_サーバー設計.md)、[04](docs/04_サーバー構築手順.md)） |
| テスト PC での動作確認（install.ps1 -TestMode） | 完了（Traccar 起動・位置受信・アイコン反映・バックアップ・死活監視） |
| 実機（発信機）での接続確認 | 未実施 |
| 日本語スマホアプリ | 未着手 |

## サーバーの構築（概要）

詳しくは **[docs/04_サーバー構築手順.md](docs/04_サーバー構築手順.md)** を参照してください。

1. 回線がポート転送できるか確認
2. `server\windows\config.example.psd1` を `config.psd1` にコピーして編集
3. 管理者 PowerShell で実行
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\server\windows\install.ps1
   ```
4. ブラウザで http://localhost:8082 を開き、管理者アカウントと発信機を登録
5. Tailscale Funnel でスマホからアクセスできるようにし、発信機に SMS で接続先を設定

テスト用 PC では `install.ps1 -TestMode`（電源・ファイアウォール等を変更しない）、内容の確認だけなら `-DryRun` が使えます。

## フォルダ構成

```
docs/              解析レポート・設計書・構築手順
server/windows/    Windows 用のインストール・運用スクリプト
assets/icon/       オリジナルアイコン（SVG 原本と各サイズの PNG / ICO）
```

## 使用しているもの

| ソフト / サービス | ライセンス・料金 |
|---|---|
| [Traccar](https://www.traccar.org/) | Apache License 2.0 |
| [PostgreSQL](https://www.postgresql.org/) | PostgreSQL License |
| [Tailscale](https://tailscale.com/) | 個人利用は無料プラン |
| [DuckDNS](https://www.duckdns.org/) | 無料 |
| [OpenStreetMap](https://www.openstreetmap.org/) / Nominatim | ODbL / 利用規約に従い低頻度で利用 |

## 注意

- 本プロジェクトは WanWay 社・TrackerOne とは関係ありません。
- TrackerOne の APK は解析のためにのみ使用し、このリポジトリには含めていません。
