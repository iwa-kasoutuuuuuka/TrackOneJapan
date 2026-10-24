<#
.SYNOPSIS
  サービスの死活監視と自動復旧（タスクスケジューラから 5 分ごとに実行）。
.DESCRIPTION
  - PostgreSQL / Traccar / Tailscale のサービスが止まっていたら起動
  - Traccar の Web API か GT06 ポート（gt06 を使う設定の場合）が 2 回続けて応答しなければ Traccar を再起動
  - install / restore / update の実行中（state\maintenance.flag がある間）は何もしない
    （2 時間以上前の目印で、実行していた処理も終わっている場合は消し忘れとみなして無視する）
  - 復元に失敗した状態（state\restore-failed.flag がある間）は Traccar を起動しない
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"
$LogName = 'healthcheck'
$failFile = Join-Path $TOStateDir 'healthcheck-failures.txt'

try {
    $cfg = Get-TOConfig
    $pgService = Get-PgServiceName $cfg

    switch (Get-TOMaintenanceState) {
        'Active' {
            Write-TOLog 'メンテナンス中（install / restore / update の実行中）のため確認を省略します' -Name $LogName
            Set-Content $failFile '0' -Encoding ASCII
            exit 0
        }
        'Long' {
            Write-TOLog "メンテナンスが 2 時間以上続いています。処理が止まっていないか確認してください: $TOMaintenanceFlag" -Level WARN -Name $LogName
            Set-Content $failFile '0' -Encoding ASCII
            exit 0
        }
        'Stale' {
            Write-TOLog "古いメンテナンスの目印が残っていたため削除して、確認を続けます: $TOMaintenanceFlag" -Level WARN -Name $LogName
            Remove-Item $TOMaintenanceFlag -Force -ErrorAction SilentlyContinue
        }
    }
    $restoreFailed = Test-Path $TORestoreFailedFlag

    foreach ($name in $pgService, $TraccarService, 'Tailscale') {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) {
            if ($name -ne 'Tailscale') { Write-TOLog "サービス $name がありません" -Level ERROR -Name $LogName }
            continue
        }
        if ($name -eq $TraccarService -and $restoreFailed) { continue }
        if ($svc.Status -ne 'Running') {
            Write-TOLog "サービス $name が停止していたため起動します（状態: $($svc.Status)）" -Level WARN -Name $LogName
            Start-Service $name
        }
    }

    if ($restoreFailed) {
        Write-TOLog "復元に失敗した状態のため、Traccar は起動・監視しません。restore.ps1 をやり直してください（目印: $TORestoreFailedFlag）" -Level ERROR -Name $LogName
    } else {
        $apiOk = Test-TraccarApi -Cfg $cfg
        $gt06Ok = $true
        if (Test-TOProtocolEnabled $cfg 'gt06') { $gt06Ok = Test-TcpPort -Port $cfg.Gt06Port }
        $failures = 0
        if (Test-Path $failFile) { [void][int]::TryParse((Get-Content $failFile -Raw), [ref]$failures) }

        if ($apiOk -and $gt06Ok) {
            if ($failures -gt 0) { Write-TOLog '復旧を確認しました' -Level OK -Name $LogName }
            Set-Content $failFile '0' -Encoding ASCII
        } else {
            $failures++
            Set-Content $failFile ([string]$failures) -Encoding ASCII
            Write-TOLog "応答なし（API: $apiOk / GT06: $gt06Ok）連続 $failures 回目" -Level WARN -Name $LogName
            if ($failures -ge 2) {
                Write-TOLog 'Traccar を再起動します' -Level WARN -Name $LogName
                Set-Content $failFile '0' -Encoding ASCII
                # 2 分で止まらなければプロセスを強制終了してから起動する
                Restart-TOService -Name $TraccarService -TimeoutSec 120
            }
        }
    }

    # ディスクの空き容量
    $drive = Get-PSDrive -Name ($TORoot.Substring(0, 1))
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 5) { Write-TOLog "ディスクの空きが少なくなっています: $freeGb GB" -Level WARN -Name $LogName }
} catch {
    Write-TOLog "死活監視でエラー: $_" -Level ERROR -Name $LogName
    exit 1
}
exit 0
