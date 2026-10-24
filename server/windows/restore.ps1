<#
.SYNOPSIS
  バックアップから Traccar のデータベースを復元します。現在のデータは上書きされます。
.PARAMETER BackupFile
  復元する .dump ファイル。省略すると最新のバックアップを使います。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\restore.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\restore.ps1 -BackupFile C:\TrackOneServer\backup\traccar-20261024-030000.dump
#>
[CmdletBinding()]
param([string] $BackupFile, [switch] $Force)

. "$PSScriptRoot\common.ps1"
$LogName = 'restore'
Assert-Admin
$cfg = Get-TOConfig

if (-not $BackupFile) {
    $latest = Get-ChildItem $TOBackupDir -File -Filter 'traccar-*.dump' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "バックアップが見つかりません: $TOBackupDir" }
    $BackupFile = $latest.FullName
}
if (-not (Test-Path $BackupFile)) { throw "ファイルがありません: $BackupFile" }

Write-Host "復元するバックアップ: $BackupFile ($((Get-Item $BackupFile).LastWriteTime))"
Write-Host '現在のデータはすべて上書きされます。' -ForegroundColor Yellow
if (-not $Force) {
    $answer = Read-Host '続けるには yes と入力してください'
    if ($answer -ne 'yes') { Write-Host '中止しました。'; exit 0 }
}

# 念のため、復元前の状態もバックアップしておく
& "$PSScriptRoot\backup.ps1"

Write-TOLog "復元開始: $BackupFile" -Name $LogName
Stop-Service $TraccarService -Force
$pgRestore = Join-Path (Get-PgBin $cfg) 'pg_restore.exe'
$env:PGPASSWORD = Get-TOSecret 'db-traccar-password'
try {
    $out = & $pgRestore -h 127.0.0.1 -p $cfg.PostgresPort -U $cfg.DatabaseUser -d $cfg.DatabaseName --clean --if-exists --no-owner $BackupFile 2>&1
    if ($LASTEXITCODE -ne 0) { Write-TOLog "pg_restore の警告/エラー: $out" -Level WARN -Name $LogName }
} finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}
Start-Service $TraccarService
if (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300) {
    Write-TOLog '復元が完了し、Traccar が起動しました' -Level OK -Name $LogName
} else {
    Write-TOLog "Traccar が起動しません。ログを確認してください: $TraccarDir\logs" -Level ERROR -Name $LogName
    exit 1
}
