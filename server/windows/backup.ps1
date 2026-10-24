<#
.SYNOPSIS
  Traccar のデータベースと設定をバックアップします（タスクスケジューラから毎日実行）。
.DESCRIPTION
  保存先: C:\TrackOneServer\backup（管理者と SYSTEM だけが読めます）
  古いバックアップは、ファイル名の日時で判断して BackupKeepDays 日より前のものを削除します。
  スクリプトのログ（90 日）、Traccar のログ（30 日）、PostgreSQL のログ（30 日）も削除します。
.PARAMETER NoPrune
  古いバックアップやログを削除しません（restore.ps1 / update-traccar.ps1 / install.ps1 が復元前・更新前に使います）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\backup.ps1
#>
[CmdletBinding()]
param([switch] $NoPrune)

. "$PSScriptRoot\common.ps1"
$LogName = 'backup'

try {
    $cfg = Get-TOConfig
    # バックアップには DB パスワード入りの traccar.xml と全データが入るので、管理者と SYSTEM だけが読めるようにする
    try { Protect-TODirectory -Path $TOBackupDir }
    catch { Write-TOLog "バックアップフォルダのアクセス権を設定できませんでした: $($_.Exception.Message)" -Level WARN -Name $LogName }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dump = Join-Path $TOBackupDir "traccar-$stamp.dump"

    $pgDump = Join-Path (Get-PgBin $cfg) 'pg_dump.exe'
    $env:PGPASSWORD = Get-TOSecret 'db-traccar-password'
    try {
        $r = Invoke-TONative -FilePath $pgDump -ArgumentList @('-h', '127.0.0.1', '-p', [string]$cfg.PostgresPort, '-U', $cfg.DatabaseUser,
            '-d', $cfg.DatabaseName, '-Fc', '-Z', '6', '-f', $dump)
        if ($r.ExitCode -ne 0) { throw "pg_dump に失敗しました（終了コード $($r.ExitCode)）: $($r.Error)" }
    } finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $dump) -or (Get-Item $dump).Length -eq 0) { throw "バックアップファイルが作られていません: $dump" }

    # 設定ファイル（DB パスワード入り）も一緒に保存
    $xml = Join-Path $TOConfigDir 'traccar.xml'
    if (Test-Path $xml) { Copy-Item $xml (Join-Path $TOBackupDir "traccar-$stamp.xml") -Force }
    Copy-Item (Join-Path $TOConfigDir 'config.psd1') (Join-Path $TOBackupDir "config-$stamp.psd1") -Force

    $sizeMb = [math]::Round((Get-Item $dump).Length / 1MB, 1)
    Write-TOLog "バックアップ作成: $dump ($sizeMb MB)" -Level OK -Name $LogName
} catch {
    Write-TOLog "バックアップ失敗: $_" -Level ERROR -Name $LogName
    exit 1
}

# 追加のコピー先（ドライブが外れている等で失敗しても、ここで止めない）
$copyTo = [string]$cfg.BackupCopyTo
if ($copyTo) {
    try {
        if (-not (Test-Path $copyTo)) { New-Item -ItemType Directory -Force $copyTo | Out-Null }
        Copy-Item $dump $copyTo -Force
        Write-TOLog "コピー: $copyTo" -Name $LogName
    } catch {
        Write-TOLog "追加のコピー先に保存できませんでした（ドライブの接続を確認してください）: $copyTo / $($_.Exception.Message)" -Level WARN -Name $LogName
    }
}

if ($NoPrune) {
    Write-TOLog '-NoPrune のため、古いバックアップは削除しません' -Name $LogName
    exit 0
}

# 古いバックアップを削除（ファイル名の日時で判断。コピーしたファイルは更新日時が元のままのため）
try {
    $limit = (Get-Date).AddDays(-[int]$cfg.BackupKeepDays)
    $targets = @(Get-TOBackupFiles -Path $TOBackupDir | Where-Object { $_.Stamp -lt $limit })
    if ($copyTo -and (Test-Path $copyTo)) {
        # コピー先は TrackOne 以外のファイルもあり得るので、同じ名前の形式の .dump だけを対象にする
        $targets += @(Get-TOBackupFiles -Path $copyTo -Kind 'traccar' -Extension 'dump' | Where-Object { $_.Stamp -lt $limit })
    }
    foreach ($t in $targets) {
        Remove-Item $t.File.FullName -Force
        Write-TOLog "古いバックアップを削除: $($t.File.FullName)" -Name $LogName
    }
} catch {
    Write-TOLog "古いバックアップの削除でエラー: $($_.Exception.Message)" -Level WARN -Name $LogName
}

# ログの削除: スクリプトのログ 90 日、Traccar・PostgreSQL のログ 30 日
try {
    Get-ChildItem $TOLogDir -File -Filter '*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } | Remove-Item -Force
    $traccarLogs = Join-Path $TraccarDir 'logs'
    if (Test-Path $traccarLogs) {
        # logger.rotate=true で日ごとに分かれた tracker-server.log.YYYYMMDD だけを対象にする
        Get-ChildItem $traccarLogs -File -Filter 'tracker-server.log.*' |
            Where-Object { $_.Name -match '^tracker-server\.log\.\d{8}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
    }
    $pgLogs = Join-Path $env:ProgramFiles "PostgreSQL\$($cfg.PostgresMajor)\data\log"
    if (Test-Path $pgLogs) {
        Get-ChildItem $pgLogs -File -Filter 'postgresql-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-TOLog "古いログの削除でエラー: $($_.Exception.Message)" -Level WARN -Name $LogName
}
exit 0
