<#
.SYNOPSIS
  Traccar のデータベースと設定をバックアップします（タスクスケジューラから毎日実行）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\backup.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"
$LogName = 'backup'

try {
    $cfg = Get-TOConfig
    if (-not (Test-Path $TOBackupDir)) { New-Item -ItemType Directory -Force $TOBackupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dump = Join-Path $TOBackupDir "traccar-$stamp.dump"

    $pgDump = Join-Path (Get-PgBin $cfg) 'pg_dump.exe'
    $env:PGPASSWORD = Get-TOSecret 'db-traccar-password'
    try {
        $out = & $pgDump -h 127.0.0.1 -p $cfg.PostgresPort -U $cfg.DatabaseUser -d $cfg.DatabaseName -Fc -Z 6 -f $dump 2>&1
        if ($LASTEXITCODE -ne 0) { throw "pg_dump に失敗しました: $out" }
    } finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }

    # 設定ファイル（DB パスワード入り）も一緒に保存
    $xml = Join-Path $TOConfigDir 'traccar.xml'
    if (Test-Path $xml) { Copy-Item $xml (Join-Path $TOBackupDir "traccar-$stamp.xml") -Force }
    Copy-Item (Join-Path $TOConfigDir 'config.psd1') (Join-Path $TOBackupDir "config-$stamp.psd1") -Force

    $sizeMb = [math]::Round((Get-Item $dump).Length / 1MB, 1)
    Write-TOLog "バックアップ作成: $dump ($sizeMb MB)" -Level OK -Name $LogName

    # 追加のコピー先
    if ($cfg.ContainsKey('BackupCopyTo') -and $cfg.BackupCopyTo) {
        if (-not (Test-Path $cfg.BackupCopyTo)) { New-Item -ItemType Directory -Force $cfg.BackupCopyTo | Out-Null }
        Copy-Item $dump $cfg.BackupCopyTo -Force
        Write-TOLog "コピー: $($cfg.BackupCopyTo)" -Name $LogName
    }

    # 古いバックアップを削除
    $limit = (Get-Date).AddDays(-[int]$cfg.BackupKeepDays)
    $targets = @(Get-ChildItem $TOBackupDir -File | Where-Object { $_.Name -match '^(traccar|config)-\d{8}-\d{6}\.' -and $_.LastWriteTime -lt $limit })
    if ($cfg.ContainsKey('BackupCopyTo') -and $cfg.BackupCopyTo -and (Test-Path $cfg.BackupCopyTo)) {
        $targets += @(Get-ChildItem $cfg.BackupCopyTo -File -Filter 'traccar-*.dump' | Where-Object { $_.LastWriteTime -lt $limit })
    }
    foreach ($f in $targets) { Remove-Item $f.FullName -Force; Write-TOLog "古いバックアップを削除: $($f.Name)" -Name $LogName }

    # スクリプトのログも 90 日で削除
    Get-ChildItem $TOLogDir -File -Filter '*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } | Remove-Item -Force
} catch {
    Write-TOLog "バックアップ失敗: $_" -Level ERROR -Name $LogName
    exit 1
}
