<#
.SYNOPSIS
  バックアップから Traccar のデータベースを復元します。現在のデータは置き換えられます。
.DESCRIPTION
  1. 復元前の状態をバックアップ（古いバックアップは消さない）
  2. Traccar を停止し、データベースを空の状態から作り直して復元
  3. Traccar を起動して動作確認
  復元に失敗した場合は Traccar を止めたままにします（空のデータで動き出さないように）。
.PARAMETER BackupFile
  復元する .dump ファイル（指定を推奨）。省略すると、ファイル名の日時がいちばん新しいバックアップを使います。
.PARAMETER Force
  確認の入力（yes）を省略します。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\restore.ps1 -BackupFile C:\TrackOneServer\backup\traccar-20261024-030000.dump
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\restore.ps1
#>
[CmdletBinding()]
param([string] $BackupFile, [switch] $Force)

. "$PSScriptRoot\common.ps1"
$LogName = 'restore'
Assert-Admin
$cfg = Get-TOConfig
$pgService = Get-PgServiceName $cfg

if ($BackupFile) {
    if (-not (Test-Path $BackupFile)) { throw "ファイルがありません: $BackupFile" }
    $BackupFile = (Resolve-Path $BackupFile).Path
    $info = @(Get-TOBackupFiles -Path (Split-Path $BackupFile -Parent) -Kind 'traccar' -Extension 'dump' | Where-Object { $_.File.FullName -eq $BackupFile })
    if ($info.Count -gt 0) { $when = $info[0].Stamp } else { $when = (Get-Item $BackupFile).LastWriteTime }
} else {
    $latest = Get-TOBackupFiles -Path $TOBackupDir -Kind 'traccar' -Extension 'dump' | Sort-Object Stamp -Descending | Select-Object -First 1
    if (-not $latest) { throw "バックアップが見つかりません: $TOBackupDir" }
    $BackupFile = $latest.File.FullName
    $when = $latest.Stamp
}

Write-Host "復元するバックアップ: $BackupFile（$($when.ToString('yyyy-MM-dd HH:mm:ss')) 作成）"
Write-Host '現在のデータはすべて消え、このバックアップの内容に置き換わります。' -ForegroundColor Yellow
if (-not $Force) {
    $answer = Read-Host '続けるには yes と入力してください'
    if ($answer -ne 'yes') { Write-Host '中止しました。'; exit 0 }
}

$user = $cfg.DatabaseUser
$db = $cfg.DatabaseName
if ($user -notmatch '^[a-z_][a-z0-9_]*$' -or $db -notmatch '^[a-z_][a-z0-9_]*$') { throw 'DatabaseUser / DatabaseName は英小文字・数字・_ のみ使えます。' }
$pgBin = Get-PgBin $cfg
$su = Get-TOSecret 'db-postgres-password'
$dbDropped = $false
$failed = $false
$before = $null

# 死活監視（healthcheck.ps1）が途中で Traccar を起動しないようにする
Enter-TOMaintenance 'restore'
try {
    Write-TOLog "復元開始: $BackupFile" -Name $LogName

    # 1. バックアップファイルが読めるか先に確認（ここで失敗しても何も変わらない）
    $check = Invoke-TONative -FilePath (Join-Path $pgBin 'pg_restore.exe') -ArgumentList @('--list', $BackupFile)
    if ($check.ExitCode -ne 0) { throw "バックアップファイルを読めません（壊れているか、形式が違います）: $($check.Error)" }

    # 2. 念のため、復元前の状態もバックアップしておく（復元しようとしているファイルを消さないよう -NoPrune）
    if (Get-Service -Name $pgService -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Running' }) { Start-Service $pgService }
    & "$PSScriptRoot\backup.ps1" -NoPrune
    if ($LASTEXITCODE -ne 0) { throw '復元前のバックアップに失敗したため、復元を中止しました（データは変更していません）。' }
    $before = Get-TOBackupFiles -Path $TOBackupDir -Kind 'traccar' -Extension 'dump' | Sort-Object Stamp -Descending | Select-Object -First 1
    if ($before) { Write-TOLog "復元前のバックアップ: $($before.File.FullName)" -Name $LogName }

    # 3. Traccar を止め、データベースを空の状態から作り直す
    Stop-TOService -Name $TraccarService
    $drop = "DROP DATABASE IF EXISTS $db"
    if ([int]$cfg.PostgresMajor -ge 13) { $drop += ' WITH (FORCE)' }
    $sql = @"
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();
$drop;
CREATE DATABASE $db OWNER $user ENCODING 'UTF8' TEMPLATE template0;
"@
    $dbDropped = $true   # ここから先で失敗したら、データベースは空か作りかけ
    Invoke-Psql -Cfg $cfg -Sql $sql -Password $su | Out-Null

    # 4. 復元（Traccar 用ユーザーで、1 つのトランザクションとして。エラーが 1 つでもあれば全体を取り消す）
    $env:PGPASSWORD = Get-TOSecret 'db-traccar-password'
    try {
        $r = Invoke-TONative -FilePath (Join-Path $pgBin 'pg_restore.exe') -ArgumentList @('-h', '127.0.0.1', '-p', [string]$cfg.PostgresPort,
            '-U', $user, '-d', $db, '--no-owner', '--no-privileges', '--exit-on-error', '--single-transaction', $BackupFile)
    } finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
    if ($r.ExitCode -ne 0) { throw "pg_restore に失敗しました（終了コード $($r.ExitCode)）: $($r.Error)" }
    Write-TOLog 'データベースの復元が完了しました。Traccar を起動します' -Name $LogName
    if (Test-Path $TORestoreFailedFlag) { Remove-Item $TORestoreFailedFlag -Force }

    # 5. 起動して確認
    Start-Service $TraccarService
    if (-not (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300)) {
        Write-TOLog "データは復元しましたが、Traccar が起動しません。ログを確認してください: $TraccarDir\logs" -Level ERROR -Name $LogName
        $failed = $true
    } else {
        Write-TOLog '復元が完了し、Traccar が起動しました' -Level OK -Name $LogName
    }
} catch {
    $failed = $true
    Write-TOLog "復元失敗: $($_.Exception.Message)" -Level ERROR -Name $LogName
    if ($dbDropped) {
        # 空のデータベースで Traccar が動き出すと、新しい空のデータが作られてしまうので止めたままにする
        try { Stop-TOService -Name $TraccarService } catch { }
        $note = "restore.ps1 failed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $BackupFile"
        try { Set-Content -Path $TORestoreFailedFlag -Value $note -Encoding UTF8 } catch { }
        $msg = "復元に失敗したため、Traccar は停止したままにしています（死活監視も Traccar を起動しません）。`n" +
               "  ・別のバックアップを指定して restore.ps1 をもう一度実行してください。"
        if ($before) { $msg += "`n  ・元に戻す場合: restore.ps1 -BackupFile `"$($before.File.FullName)`"" }
        $msg += "`n  ・原因を調べて Traccar を手動で起動する場合は、先に $TORestoreFailedFlag を削除してください。"
        Write-TOLog $msg -Level ERROR -Name $LogName
    } else {
        # データベースはまだ変更していないので、Traccar を元どおり起動する
        if ((Get-Service -Name $TraccarService -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Running' })) {
            try { Start-Service $TraccarService; Write-TOLog 'データは変更していません。Traccar を起動しました' -Name $LogName }
            catch { Write-TOLog "Traccar を起動できませんでした: $($_.Exception.Message)" -Level ERROR -Name $LogName }
        }
    }
} finally {
    Exit-TOMaintenance
}
if ($failed) { exit 1 }
exit 0
