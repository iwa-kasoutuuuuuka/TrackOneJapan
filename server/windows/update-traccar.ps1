<#
.SYNOPSIS
  Traccar を新しいバージョンに更新します。
.DESCRIPTION
  ダウンロード → バックアップ → 停止 → インストール → 設定の再適用 → 起動 → 動作確認 を自動で行います。
  ダウンロードに失敗した場合は Traccar を止めずに中止します。途中で失敗した場合も Traccar の起動を試みます。
  失敗した場合は restore.ps1 で更新前のデータに戻せます。
.PARAMETER Version
  新しいバージョン（例: 6.17.0）。https://github.com/traccar/traccar/releases で確認。
.PARAMETER AllowDowngrade
  インストール済みより古いバージョンを入れる場合に指定します（通常は誤操作を防ぐため中止します）。
.PARAMETER Sha256
  配布 ZIP（traccar-windows-64-<版>.zip）の SHA-256。省略時は GitHub のリリース情報と照合します。
.PARAMETER AllowUnverifiedDownload
  ハッシュを確認できなかった場合でも続けます（通常は中止します）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\update-traccar.ps1 -Version 6.17.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+(\.\d+)?$')] [string] $Version,
    [switch] $AllowDowngrade,
    [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $Sha256,
    [switch] $AllowUnverifiedDownload
)

. "$PSScriptRoot\common.ps1"
$LogName = 'update'
Assert-Admin
$cfg = Get-TOConfig
$pgService = Get-PgServiceName $cfg
$template = Join-Path $PSScriptRoot 'traccar.xml.template'

$current = Get-InstalledTraccarVersion
if ($current) {
    $cmp = (ConvertTo-TOVersion $Version).CompareTo((ConvertTo-TOVersion $current))
    if ($cmp -eq 0) { Write-TOLog "Traccar $current は導入済みです。更新は不要です。" -Level OK -Name $LogName; exit 0 }
    if ($cmp -lt 0 -and -not $AllowDowngrade) {
        Write-TOLog "指定した $Version はインストール済みの $current より古いため中止しました。戻す場合は -AllowDowngrade を付けてください（データベースが新しい形式に移行済みだと起動しないことがあります）。" -Level ERROR -Name $LogName
        exit 1
    }
}
Write-TOLog "Traccar を更新: $current → $Version" -Name $LogName

$pkg = $null
$stopped = $false
$ok = $false
try {
    # 1. 先にダウンロード（失敗しても Traccar は動いたまま）
    $pkg = Get-TraccarPackage -Version $Version -ExpectedSha256 $Sha256 -AllowUnverified:$AllowUnverifiedDownload

    # 2. バックアップ
    & "$PSScriptRoot\backup.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'バックアップに失敗したため更新を中止しました（Traccar は変更していません）。' }

    # 3. 停止 → インストール（ここからは死活監視に Traccar を触らせない）
    Enter-TOMaintenance 'update'
    $stopped = $true
    Stop-TOService -Name $TraccarService
    Install-TraccarPackage -Package $pkg

    # 設定ファイルのバージョン番号も更新（install.ps1 を再実行したときに古い版に戻らないように）
    $cfgFile = Join-Path $TOConfigDir 'config.psd1'
    $text = Get-Content $cfgFile -Raw -Encoding UTF8
    $pattern = "(?m)^(\s*TraccarVersion\s*=\s*)(['`"])[^'`"]*\2"
    if ($text -match $pattern) {
        $text = [regex]::Replace($text, $pattern, ('${1}' + "'$Version'"))
        # TraccarSha256 を書いている場合は、確認済みの新しい版のハッシュに置き換える（古い版のハッシュが残らないように）
        $shaPattern = "(?m)^(\s*TraccarSha256\s*=\s*)(['`"])[^'`"]*\2"
        if ($text -match $shaPattern) { $text = [regex]::Replace($text, $shaPattern, ('${1}' + "'$($pkg.ZipSha256)'")) }
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($cfgFile, $text, $utf8Bom)
    }
    $check = Get-TOConfig -Path $cfgFile
    if ($check.TraccarVersion -ne $Version) {
        Write-TOLog "config.psd1 の TraccarVersion を書き換えられませんでした。手で $Version に直してください: $cfgFile" -Level ERROR -Name $LogName
    }

    # 4. インストーラーが traccar.xml とサービス設定を初期化するので、作り直してから起動
    Stop-TOService -Name $TraccarService
    Install-TraccarConfig -Cfg $cfg -TemplatePath $template
    Set-TOServiceRecovery -ServiceName $TraccarService -DependsOn $pgService
    # インストーラーがサービスを LocalSystem に戻すので、最小権限の専用アカウントに設定し直す
    Set-TOTraccarServiceAccount -Cfg $cfg
    Start-Service $TraccarService

    if (-not (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300)) {
        throw ("更新後に Traccar が応答しません。ログを確認し、必要なら restore.ps1 で戻してください: $TraccarDir\logs" + (Get-TOTraccarStartHint -Cfg $cfg))
    }
    $ok = $true
    Write-TOLog "Traccar $Version への更新が完了しました" -Level OK -Name $LogName
} catch {
    Write-TOLog "更新失敗: $($_.Exception.Message)" -Level ERROR -Name $LogName
    if ($stopped) {
        # インストーラーが traccar.xml を初期状態に戻している可能性があるので、設定を入れ直してから起動を試みる
        try {
            if (Test-Path (Join-Path $TraccarDir 'conf')) { Install-TraccarConfig -Cfg $cfg -TemplatePath $template }
        } catch { Write-TOLog "traccar.xml を再適用できませんでした: $($_.Exception.Message)" -Level ERROR -Name $LogName }
        try {
            # LocalSystem のまま動き出さないよう、専用アカウントに設定し直してから起動する
            Set-TOTraccarServiceAccount -Cfg $cfg
        } catch { Write-TOLog "Traccar のサービスアカウントを設定できませんでした: $($_.Exception.Message)" -Level ERROR -Name $LogName }
        try {
            $svc = Get-Service -Name $TraccarService -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                Start-Service $TraccarService
                Write-TOLog 'Traccar を起動しました。画面で動作を確認してください' -Level WARN -Name $LogName
            }
        } catch { Write-TOLog "Traccar を起動できませんでした: $($_.Exception.Message)" -Level ERROR -Name $LogName }
    }
} finally {
    Remove-TraccarPackage $pkg
    Exit-TOMaintenance
}
if (-not $ok) { exit 1 }
exit 0
