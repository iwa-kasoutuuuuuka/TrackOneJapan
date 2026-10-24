<#
.SYNOPSIS
  サービスの死活監視と自動復旧（タスクスケジューラから 5 分ごとに実行）。
.DESCRIPTION
  - PostgreSQL / Traccar / Tailscale のサービスが止まっていたら起動
  - Traccar の Web API か GT06 ポートが 2 回続けて応答しなければ Traccar を再起動
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"
$LogName = 'healthcheck'
$failFile = Join-Path $TOStateDir 'healthcheck-failures.txt'

try {
    $cfg = Get-TOConfig
    $pgService = Get-PgServiceName $cfg

    foreach ($name in $pgService, $TraccarService, 'Tailscale') {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) {
            if ($name -ne 'Tailscale') { Write-TOLog "サービス $name がありません" -Level ERROR -Name $LogName }
            continue
        }
        if ($svc.Status -ne 'Running') {
            Write-TOLog "サービス $name が停止していたため起動します（状態: $($svc.Status)）" -Level WARN -Name $LogName
            Start-Service $name
        }
    }

    $apiOk = Test-TraccarApi -Cfg $cfg
    $gt06Ok = Test-TcpPort -Port $cfg.Gt06Port
    $failures = 0
    if (Test-Path $failFile) { $failures = [int](Get-Content $failFile -Raw) }

    if ($apiOk -and $gt06Ok) {
        if ($failures -gt 0) { Write-TOLog '復旧を確認しました' -Level OK -Name $LogName }
        Set-Content $failFile '0' -Encoding ASCII
    } else {
        $failures++
        Set-Content $failFile ([string]$failures) -Encoding ASCII
        Write-TOLog "応答なし（API: $apiOk / GT06: $gt06Ok）連続 $failures 回目" -Level WARN -Name $LogName
        if ($failures -ge 2) {
            Write-TOLog 'Traccar を再起動します' -Level WARN -Name $LogName
            Restart-Service $TraccarService -Force
            Set-Content $failFile '0' -Encoding ASCII
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
