<#
.SYNOPSIS
  Traccar を新しいバージョンに更新します。
.DESCRIPTION
  バックアップ → ダウンロード → 停止 → インストール → 設定の再適用 → 起動 → 動作確認 を自動で行います。
  失敗した場合は restore.ps1 で更新前のデータに戻せます。
.PARAMETER Version
  新しいバージョン（例: 6.17.0）。https://github.com/traccar/traccar/releases で確認。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\update-traccar.ps1 -Version 6.17.0
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+(\.\d+)?$')] [string] $Version)

. "$PSScriptRoot\common.ps1"
$LogName = 'update'
Assert-Admin
$cfg = Get-TOConfig
$pgService = Get-PgServiceName $cfg

$current = Get-InstalledTraccarVersion
Write-TOLog "Traccar を更新: $current → $Version" -Name $LogName

& "$PSScriptRoot\backup.ps1"
if ($LASTEXITCODE -ne 0) { throw 'バックアップに失敗したため更新を中止しました。' }

Stop-Service $TraccarService -Force
Install-TraccarPackage -Version $Version

# インストーラーが traccar.xml とサービス設定を初期化するので、作り直す
Stop-Service $TraccarService -Force -ErrorAction SilentlyContinue
Install-TraccarConfig -Cfg $cfg -TemplatePath (Join-Path $PSScriptRoot 'traccar.xml.template')
Set-TOServiceRecovery -ServiceName $TraccarService -DependsOn $pgService
Start-Service $TraccarService

if (-not (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300)) {
    Write-TOLog "更新後に Traccar が起動しません。ログを確認し、必要なら restore.ps1 で戻してください: $TraccarDir\logs" -Level ERROR -Name $LogName
    exit 1
}

# 設定ファイルのバージョン番号も更新
$cfgFile = Join-Path $TOConfigDir 'config.psd1'
$text = Get-Content $cfgFile -Raw -Encoding UTF8
$text = [regex]::Replace($text, "TraccarVersion\s*=\s*'[^']*'", "TraccarVersion   = '$Version'")
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($cfgFile, $text, $utf8Bom)

Write-TOLog "Traccar $Version への更新が完了しました" -Level OK -Name $LogName
