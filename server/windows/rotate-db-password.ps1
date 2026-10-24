<#
.SYNOPSIS
  PostgreSQL のパスワード（postgres と Traccar 用ユーザー）を新しいものに変更します。
.DESCRIPTION
  以前の install.ps1 では、PostgreSQL のインストール時に postgres のパスワードが winget のログ
  （%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir\WinGet-*.log）に
  そのまま残っていました。また、バックアップの traccar-*.xml（Traccar 用ユーザーのパスワード入り）を
  一般ユーザーも読める状態でした。このスクリプトでパスワードを変更すると、漏れた古いパスワードは使えなくなります。
  新しいパスワードは C:\TrackOneServer\secrets に保存され、画面やログには表示しません。
  Traccar 用ユーザーのパスワードを変えるときは、traccar.xml を作り直して Traccar を再起動します（1 分ほど止まります）。
.PARAMETER SkipTraccar
  postgres のパスワードだけを変更します（Traccar は再起動しません）。
.PARAMETER RemoveLeakedLogs
  変更前の postgres パスワードが書かれたログファイル（winget のログなど）を削除します。
  指定しない場合は、見つかったファイルの場所を表示するだけです。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\rotate-db-password.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\rotate-db-password.ps1 -RemoveLeakedLogs
#>
[CmdletBinding()]
param([switch] $SkipTraccar, [switch] $RemoveLeakedLogs)

. "$PSScriptRoot\common.ps1"
$LogName = 'rotate-password'
Assert-Admin
$cfg = Get-TOConfig
$template = Join-Path $PSScriptRoot 'traccar.xml.template'

$oldSu = Get-TOSecret 'db-postgres-password'
if (-not $oldSu) { throw "postgres のパスワードがありません: $TOSecretsDir\db-postgres-password.txt" }
if (-not (Test-TOPgLogin -Cfg $cfg -Password $oldSu -Tries 1)) {
    throw "今の postgres パスワードでログインできません。$TOSecretsDir\db-postgres-password.txt を確認してください。"
}

# 変更前のパスワードが残っているログを探す（パスワード自体は表示しない）
# 2 回目以降の実行でも見つかるよう、PostgreSQL のインストール時の「--superpassword」も探す
$leaked = @(Find-TOSecretInLogs -Secret @($oldSu, '--superpassword'))
$oldSu = $null

$ok = $false
Enter-TOMaintenance 'rotate-password'
try {
    Update-TOPostgresPassword -Cfg $cfg
    if (-not (Test-TOPgLogin -Cfg $cfg -Password (Get-TOSecret 'db-postgres-password') -Tries 1)) { throw '変更後の postgres パスワードでログインできません。' }
    Write-TOLog 'postgres のパスワードを変更しました' -Level OK -Name $LogName

    if (-not $SkipTraccar) {
        Write-TOLog 'Traccar 用ユーザーのパスワードを変更し、Traccar を再起動します' -Name $LogName
        Update-TOTraccarDbPassword -Cfg $cfg -TemplatePath $template
        Restart-TOService -Name $TraccarService
        if (-not (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300)) {
            throw "パスワード変更後に Traccar が応答しません。ログを確認してください: $TraccarDir\logs\tracker-server.log"
        }
        Write-TOLog "$($cfg.DatabaseUser) のパスワードを変更し、Traccar が起動しました" -Level OK -Name $LogName
        Write-TOLog '以前のバックアップの traccar-*.xml には古いパスワードが入っています（もう使えません）。復元時は install.ps1 が traccar.xml を作り直すので問題ありません。' -Name $LogName
    }
    $ok = $true
} catch {
    Write-TOLog "パスワード変更失敗: $($_.Exception.Message)" -Level ERROR -Name $LogName
    Write-TOLog "途中で止まった場合、新しいパスワードは $TOSecretsDir の *-new.txt に残っています。" -Level ERROR -Name $LogName
    $svc = Get-Service -Name $TraccarService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try { Start-Service $TraccarService } catch { Write-TOLog "Traccar を起動できませんでした: $($_.Exception.Message)" -Level ERROR -Name $LogName }
    }
} finally {
    Exit-TOMaintenance
}

if ($leaked.Count -eq 0) {
    Write-TOLog '古い postgres パスワードが書かれたログは見つかりませんでした（この PC のこのユーザーの一時フォルダと winget のログを確認）' -Name $LogName
} else {
    foreach ($f in $leaked) {
        if ($RemoveLeakedLogs) {
            try { Remove-Item -Path $f -Force; Write-TOLog "古いパスワードが書かれたログを削除: $f" -Name $LogName }
            catch { Write-TOLog "削除できませんでした: $f（$($_.Exception.Message)）" -Level WARN -Name $LogName }
        } else {
            Write-TOLog "古いパスワード（変更済みで今は使えません）が書かれたログ: $f" -Level WARN -Name $LogName
        }
    }
    if (-not $RemoveLeakedLogs) { Write-TOLog 'これらを削除するには -RemoveLeakedLogs を付けて再実行するか、手で削除してください。' -Name $LogName }
}
if (-not $ok) { exit 1 }
exit 0
