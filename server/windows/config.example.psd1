# TrackOneJapan サーバー設定ファイル（ひな形）
# このファイルを config.psd1 という名前でコピーし、必要な箇所を書き換えてから install.ps1 を実行してください。
# パスワードやトークンはここに書かないでください（install.ps1 が別の安全な場所に保存します）。
@{
    # --- Traccar ---
    TraccarVersion   = '6.16.0'        # https://github.com/traccar/traccar/releases
    TraccarSha256    = ''              # 配布 ZIP の SHA-256（空なら GitHub のリリース情報と自動で照合）
    WebPort          = 8082            # 管理画面・API（PC 内だけで待ち受け）
    Gt06Port         = 5023            # 発信機（GT06 方式）の受信ポート
    OsmAndPort       = 5055            # テスト送信用（OsmAnd 方式。install.ps1 -TestMode の PC では自動で有効）
    EnabledProtocols = 'gt06'          # 使う通信方式（カンマ区切り）。OsmAnd は認証がなく偽の位置を送れるため、本番では入れない
    ServiceAccount   = 'NT SERVICE\traccar'   # Traccar を動かすアカウント（最小権限の専用アカウント）。
                                              # 動かないときだけ 'LocalSystem'（PC の最高権限。推奨しません）
    GeocoderEnabled  = $true           # 住所表示（OpenStreetMap Nominatim）
    GeocoderLanguage = 'ja'

    # --- PostgreSQL ---
    PostgresPackageId = 'PostgreSQL.PostgreSQL.17'
    PostgresMajor     = 17
    PostgresPort      = 5432
    DatabaseName      = 'traccar'
    DatabaseUser      = 'traccar'

    # --- DuckDNS（無料ドメイン）---
    # 例: 'myhome-tracker' と書くと myhome-tracker.duckdns.org になる。空なら DuckDNS を使わない。
    DuckDnsDomain = ''

    # --- バックアップ ---
    BackupTime     = '03:00'           # 毎日の実行時刻
    BackupKeepDays = 14                # 保持日数
    BackupCopyTo   = ''                # 追加のコピー先（例: 'D:\TrackOneBackup'）。空ならコピーしない
                                       # ※ .dump には全データ（位置の履歴など）が暗号化なしで入ります。コピーしたファイルは
                                       #   管理者と SYSTEM だけが読めるようにしますが、USB メモリ（FAT32/exFAT）では誰でも読め、
                                       #   OneDrive などのフォルダにするとクラウドにも暗号化なしで保存されます
                                       # ※ ジャンクション・シンボリックリンクのフォルダは使えません

    # --- 監視 ---
    HealthCheckIntervalMinutes = 5

    # --- Windows Update（この時間帯は自動再起動しない。最大18時間）---
    ActiveHoursStart = 7
    ActiveHoursEnd   = 23
}
