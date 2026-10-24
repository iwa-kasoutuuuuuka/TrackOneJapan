<#
.SYNOPSIS
  DuckDNS のドメインを、この PC の現在のグローバル IP に更新します（タスクスケジューラから 5 分ごとに実行）。
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\common.ps1"
$LogName = 'duckdns'

try {
    $cfg = Get-TOConfig
    if (-not $cfg.DuckDnsDomain) { exit 0 }
    $token = Get-TOSecret 'duckdns-token'
    if (-not $token) { throw "DuckDNS トークンがありません: $TOSecretsDir\duckdns-token.txt" }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # ip を空にすると DuckDNS 側が接続元の IP を自動で使う
    $url = "https://www.duckdns.org/update?domains=$($cfg.DuckDnsDomain)&token=$token&ip="
    $res = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30).Content.Trim()

    $stateFile = Join-Path $TOStateDir 'duckdns-last.txt'
    $last = ''
    if (Test-Path $stateFile) { $last = (Get-Content $stateFile -Raw).Trim() }
    if ($res -eq 'OK') {
        if ($last -ne 'OK') { Write-TOLog "$($cfg.DuckDnsDomain).duckdns.org を更新しました" -Level OK -Name $LogName }
    } else {
        Write-TOLog "DuckDNS の更新に失敗しました（応答: $res）。ドメイン名とトークンを確認してください" -Level ERROR -Name $LogName
    }
    Set-Content $stateFile $res -Encoding ASCII
} catch {
    Write-TOLog "DuckDNS 更新でエラー: $_" -Level ERROR -Name $LogName
    exit 1
}
