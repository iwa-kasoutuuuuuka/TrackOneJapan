<#
.SYNOPSIS
  TrackOneJapan サーバー（Traccar + PostgreSQL）を Windows 11 に一括インストールします。

.DESCRIPTION
  何度実行しても安全です（入っているものは飛ばし、設定は作り直します）。
  管理者として実行した PowerShell で動かしてください。

.PARAMETER TestMode
  テスト用 PC 向け。電源設定・Windows Update 設定・ファイアウォール・タスクスケジューラ・Tailscale を変更しません。
  （C:\TrackOneServer のアクセス権の設定は行います）

.PARAMETER DryRun
  実際には何も変更せず、実行内容だけを表示します。

.PARAMETER ConfigPath
  設定ファイルのパス。
  省略時: インストール済みの C:\TrackOneServer\config\config.psd1 があればそれを使います（上書きしません）。
          まだ無ければ、このフォルダの config.psd1 を使い、C:\TrackOneServer\config にコピーします。
  指定時: 指定したファイルを C:\TrackOneServer\config\config.psd1 にコピーして使います。

.PARAMETER AllowDowngrade
  設定の TraccarVersion がインストール済みの Traccar より古い場合でも、古いバージョンを入れ直します。
  （通常は誤操作を防ぐため中止します）

.EXAMPLE
  # 本番 PC（初回）
  powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
  # テスト PC
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -TestMode

.EXAMPLE
  # 設定を変えたあとの再実行（インストール済みの設定を使う）
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\install.ps1
#>
[CmdletBinding()]
param(
    [switch] $TestMode,
    [switch] $DryRun,
    [string] $ConfigPath,
    [switch] $AllowDowngrade
)

. "$PSScriptRoot\common.ps1"
$LogName = 'install'
if ($DryRun) { $script:TONoFileLog = $true }
trap {
    Write-TOLog "インストール失敗: $($_.Exception.Message)" -Level ERROR -Name $LogName
    Write-TOLog "場所: $($_.InvocationInfo.PositionMessage)" -Level ERROR -Name $LogName
    exit 1
}

function Step {
    param([Parameter(Mandatory)] [string] $Title, [Parameter(Mandatory)] [scriptblock] $Action)
    if ($DryRun) { Write-TOLog "[DRY RUN] $Title" -Name $LogName; return }
    Write-TOLog $Title -Name $LogName
    & $Action
}

# ============================================================
# 0. 前提チェック
# ============================================================
if (-not $DryRun) { Assert-Admin }
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 22000) { Write-TOLog "Windows 11 ではありません（ビルド $build）。続行しますが動作保証外です。" -Level WARN -Name $LogName }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget がありません。Microsoft Store で「アプリ インストーラー」を更新してください。' }

# 設定ファイルの決定（インストール済みの設定を、うっかり古いもので上書きしないように）
$installedConfig = Join-Path $TOConfigDir 'config.psd1'
$copyConfig = $false
if ($ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { throw "設定ファイルがありません: $ConfigPath" }
    $ConfigPath = (Resolve-Path $ConfigPath).Path
    $copyConfig = ($ConfigPath -ne $installedConfig)
} elseif (Test-Path $installedConfig) {
    $ConfigPath = $installedConfig
} else {
    $ConfigPath = Join-Path $PSScriptRoot 'config.psd1'
    if (-not (Test-Path $ConfigPath)) {
        throw "設定ファイルがありません: $ConfigPath`nconfig.example.psd1 を config.psd1 にコピーして編集してから、もう一度実行してください。"
    }
    $copyConfig = $true
}
$cfg = Get-TOConfig -Path $ConfigPath
$mode = '本番'
if ($TestMode) { $mode = 'テスト' }
Write-TOLog "=== TrackOneJapan サーバーのインストール開始（$mode モード）===" -Name $LogName
if ($copyConfig) { Write-TOLog "設定ファイル: $ConfigPath（$installedConfig にコピーして使います）" -Name $LogName }
else { Write-TOLog "設定ファイル: $ConfigPath（インストール済みの設定を使います）" -Name $LogName }

# Traccar のダウングレード防止（更新済みの Traccar を古い設定で入れ直すと、移行済みの DB が壊れることがある）
$installedVersion = Get-InstalledTraccarVersion
if ($installedVersion -and (ConvertTo-TOVersion $cfg.TraccarVersion) -lt (ConvertTo-TOVersion $installedVersion)) {
    $msg = "設定の TraccarVersion（$($cfg.TraccarVersion)）が、インストール済みの Traccar（$installedVersion）より古いです。"
    if ($AllowDowngrade) {
        Write-TOLog "$msg -AllowDowngrade が指定されたため、古いバージョンを入れ直します（入れ替え前にバックアップします）。" -Level WARN -Name $LogName
    } elseif ($DryRun) {
        Write-TOLog "$msg 実際に実行すると、ここで中止します。" -Level WARN -Name $LogName
    } else {
        throw "$msg`n設定ファイル（$ConfigPath）の TraccarVersion を $installedVersion に直してから再実行してください。どうしても古いバージョンに戻す場合は -AllowDowngrade を付けてください。"
    }
}

# ============================================================
# 1. フォルダとスクリプトの配置
# ============================================================
Step 'フォルダを作成し、スクリプトと設定をコピー（アクセス権を管理者と SYSTEM に限定）' {
    foreach ($d in $TORoot, $TOConfigDir, $TOScriptsDir, $TOBackupDir, $TOLogDir, $TOStateDir, $TOWebOverrideDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    }
    # 一般ユーザーが SYSTEM で動くスクリプトを書き換えたり、バックアップを読んだりできないようにする
    Set-TOServerAcl -InstallerSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $src = (Resolve-Path $PSScriptRoot).Path
    if ($src -ne (Resolve-Path $TOScriptsDir).Path) {
        Get-ChildItem -Path $src -File | Where-Object { $_.Extension -in '.ps1', '.template', '.ico' -or $_.Name -eq 'config.example.psd1' } |
            Copy-Item -Destination $TOScriptsDir -Force
        $webSrc = Join-Path $src 'web-override'
        $webDst = Join-Path $TOScriptsDir 'web-override'
        if (-not (Test-Path $webDst)) { New-Item -ItemType Directory -Force $webDst | Out-Null }
        Copy-Item -Path (Join-Path $webSrc '*') -Destination $webDst -Force
    }
    if ($copyConfig) { Copy-Item -Path $ConfigPath -Destination $installedConfig -Force }
}

# ここから先は、死活監視（healthcheck.ps1）が Traccar を勝手に起動・再起動しないようにする
if (-not $DryRun) { Enter-TOMaintenance 'install' }
try {

# ============================================================
# 2. パスワードの用意（初回のみ自動生成）
# ============================================================
Step 'データベース用パスワードを用意' {
    if (-not (Get-TOSecret 'db-postgres-password')) { Set-TOSecret 'db-postgres-password' (New-TOPassword) }
    if (-not (Get-TOSecret 'db-traccar-password')) { Set-TOSecret 'db-traccar-password' (New-TOPassword) }
}

# ============================================================
# 3. PostgreSQL
# ============================================================
$pgService = Get-PgServiceName $cfg
Step "PostgreSQL $($cfg.PostgresMajor) をインストール（未導入の場合）" {
    $fresh = $false
    if (Get-Service -Name $pgService -ErrorAction SilentlyContinue) {
        Write-TOLog 'PostgreSQL は導入済み' -Name $LogName
    } else {
        $pw = Get-TOSecret 'db-postgres-password'
        # 注意: この初期パスワードは winget のログに残るため、インストール直後に別のパスワードへ変更する
        $override = "--mode unattended --unattendedmodeui none --superpassword $pw --serverport $($cfg.PostgresPort) --disable-components stackbuilder"
        & winget install --id $cfg.PostgresPackageId -e --silent --accept-package-agreements --accept-source-agreements --override $override
        if ($LASTEXITCODE -ne 0) { throw "PostgreSQL のインストールに失敗しました（winget 終了コード $LASTEXITCODE）。" }
        Start-Sleep -Seconds 5
        if (-not (Get-Service -Name $pgService -ErrorAction SilentlyContinue)) { throw "$pgService サービスが見つかりません。" }
        $fresh = $true
    }
    if ((Get-Service $pgService).Status -ne 'Running') { Start-Service $pgService }

    if ($fresh -or -not (Get-TOSecret 'db-postgres-password-verified')) {
        # 以前から入っていた PostgreSQL の場合、このスクリプトが生成したパスワードとは一致しない
        if (-not (Test-TOPgLogin -Cfg $cfg -Password (Get-TOSecret 'db-postgres-password'))) {
            $hint = ''
            if (Get-TOSecret 'db-postgres-password-new') { $hint = "（パスワード変更の途中で止まった場合は $TOSecretsDir\db-postgres-password-new.txt の内容が正しいパスワードです）" }
            throw "PostgreSQL の postgres パスワードが一致しません。$TOSecretsDir\db-postgres-password.txt に正しいパスワードを書いてから再実行してください。$hint"
        }
    }
    if ($fresh) {
        $leaked = @(Find-TOSecretInLogs -Secret (Get-TOSecret 'db-postgres-password'))
        Write-TOLog 'postgres のパスワードを変更します（初期パスワードは winget のログに残るため）' -Name $LogName
        Update-TOPostgresPassword -Cfg $cfg
        if (-not (Test-TOPgLogin -Cfg $cfg -Password (Get-TOSecret 'db-postgres-password'))) { throw '変更後の postgres パスワードでログインできません。' }
        foreach ($f in $leaked) {
            Write-TOLog "初期パスワード（変更済みで今は使えません）が残っているログ: $f  不要なら削除してください: Remove-Item `"$f`"" -Level WARN -Name $LogName
        }
    }
    Set-TOSecret 'db-postgres-password-verified' 'yes'
    Set-TOServiceRecovery -ServiceName $pgService
}

Step 'PostgreSQL を PC 内からの接続だけに制限' {
    $su = Get-TOSecret 'db-postgres-password'
    $current = Invoke-Psql -Cfg $cfg -Sql 'SHOW listen_addresses' -Password $su
    if ($current -ne 'localhost') {
        Invoke-Psql -Cfg $cfg -Sql "ALTER SYSTEM SET listen_addresses = 'localhost'" -Password $su | Out-Null
        Restart-Service $pgService -Force
        Start-Sleep -Seconds 5
    }
}

Step "Traccar 用のデータベース「$($cfg.DatabaseName)」とユーザー「$($cfg.DatabaseUser)」を作成" {
    $su = Get-TOSecret 'db-postgres-password'
    $user = $cfg.DatabaseUser
    $db = $cfg.DatabaseName
    if ($user -notmatch '^[a-z_][a-z0-9_]*$' -or $db -notmatch '^[a-z_][a-z0-9_]*$') { throw 'DatabaseUser / DatabaseName は英小文字・数字・_ のみ使えます。' }
    $exists = Invoke-Psql -Cfg $cfg -Sql "SELECT 1 FROM pg_roles WHERE rolname = '$user'" -Password $su
    if ($exists -ne '1') {
        Invoke-Psql -Cfg $cfg -Sql "CREATE ROLE $user WITH LOGIN" -Password $su | Out-Null
    }
    Set-TOPgRolePassword -Cfg $cfg -Role $user -NewPassword (Get-TOSecret 'db-traccar-password') -SuPassword $su
    $dbExists = Invoke-Psql -Cfg $cfg -Sql "SELECT 1 FROM pg_database WHERE datname = '$db'" -Password $su
    if ($dbExists -ne '1') {
        Invoke-Psql -Cfg $cfg -Sql "CREATE DATABASE $db OWNER $user ENCODING 'UTF8' TEMPLATE template0" -Password $su | Out-Null
    }
}

# ============================================================
# 4. Traccar
# ============================================================
Step "Traccar $($cfg.TraccarVersion) をインストール（未導入・別バージョンの場合）" {
    $installed = Get-InstalledTraccarVersion
    if ($installed -eq $cfg.TraccarVersion) {
        Write-TOLog "Traccar $installed は導入済み" -Name $LogName
    } else {
        # 先にダウンロードする（失敗しても Traccar は動いたまま）
        $pkg = Get-TraccarPackage -Version $cfg.TraccarVersion
        try {
            if (Test-TODatabaseHasTraccar -Cfg $cfg) {
                Write-TOLog '既存のデータがあるため、Traccar を入れ替える前にバックアップします' -Name $LogName
                & (Join-Path $PSScriptRoot 'backup.ps1') -NoPrune
                if ($LASTEXITCODE -ne 0) { throw 'バックアップに失敗したため、Traccar の入れ替えを中止しました。' }
            }
            Stop-TOService -Name $TraccarService
            Install-TraccarPackage -Package $pkg
        } finally {
            Remove-TraccarPackage $pkg
        }
    }
}

Step 'Traccar の設定（traccar.xml）とオリジナルアイコンを適用' {
    $template = Join-Path $PSScriptRoot 'traccar.xml.template'
    Stop-TOService -Name $TraccarService
    Install-TraccarConfig -Cfg $cfg -TemplatePath $template
    if (-not (Test-Path $TOWebOverrideDir)) { New-Item -ItemType Directory -Force $TOWebOverrideDir | Out-Null }
    Copy-Item -Path (Join-Path $PSScriptRoot 'web-override\*') -Destination $TOWebOverrideDir -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'trackone.ico') -Destination $TOIconPath -Force
    # Traccar は PostgreSQL の起動後に起動する
    Set-TOServiceRecovery -ServiceName $TraccarService -DependsOn $pgService
    if (Test-Path $TORestoreFailedFlag) {
        Write-TOLog "以前の復元失敗の目印を消して Traccar を起動します: $TORestoreFailedFlag" -Level WARN -Name $LogName
        Remove-Item $TORestoreFailedFlag -Force
    }
    Start-Service $TraccarService
}

Step 'Traccar の起動を確認（初回はデータベース作成のため 1〜3 分かかります）' {
    if (-not (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300)) {
        throw "Traccar が起動しません。ログを確認してください: $TraccarDir\logs\tracker-server.log"
    }
    if ((Test-TOProtocolEnabled $cfg 'gt06') -and -not (Test-TcpPort -Port $cfg.Gt06Port)) {
        Write-TOLog "GT06 ポート $($cfg.Gt06Port) が応答しません" -Level WARN -Name $LogName
    }
    Write-TOLog 'Traccar は正常に起動しています' -Level OK -Name $LogName
}

Step '管理画面にタイトル・テーマ色・ロゴを設定し、デスクトップにショートカットを作成' {
    Install-TOBranding -Cfg $cfg -SourceDir $PSScriptRoot
    Restart-TOService -Name $TraccarService
    if (-not (Wait-TraccarApi -Cfg $cfg -TimeoutSec 300)) { throw 'Traccar の再起動後に応答がありません。' }
    New-TOShortcut -Cfg $cfg
}

# ============================================================
# 5. 本番 PC 向けの Windows 設定（テストモードでは行わない）
# ============================================================
if ($TestMode) {
    Write-TOLog 'テストモードのため、電源・Windows Update・ファイアウォール・タスク・Tailscale の設定は行いません' -Name $LogName
} else {
    Step 'ファイアウォール: 発信機の受信ポートを許可' {
        $rules = @(
            @{ Name = 'TrackOne GT06';   Port = $cfg.Gt06Port;   Profile = 'Any' },
            @{ Name = 'TrackOne OsmAnd'; Port = $cfg.OsmAndPort; Profile = 'Private' }   # テスト送信は LAN 内だけ
        )
        foreach ($r in $rules) {
            Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP -LocalPort $r.Port -Action Allow -Profile $r.Profile | Out-Null
        }
    }

    Step '電源: スリープ・休止状態を無効化（AC 電源時）' {
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change hibernate-timeout-ac 0
    }

    Step "Windows Update: アクティブ時間を $($cfg.ActiveHoursStart):00〜$($cfg.ActiveHoursEnd):00 に設定" {
        $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'SmartActiveHoursState' -Value 0 -Type DWord
        Set-ItemProperty -Path $key -Name 'ActiveHoursStart' -Value ([int]$cfg.ActiveHoursStart) -Type DWord
        Set-ItemProperty -Path $key -Name 'ActiveHoursEnd' -Value ([int]$cfg.ActiveHoursEnd) -Type DWord
    }

    Step 'タスクスケジューラ: 死活監視・バックアップ・DuckDNS 更新を登録' {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew

        function Register-TOTask($Name, $Script, $Trigger) {
            $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$TOScriptsDir\$Script`""
            Register-ScheduledTask -TaskName $Name -TaskPath '\TrackOne\' -Action $action -Trigger $Trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
        }

        $interval = New-TimeSpan -Minutes ([int]$cfg.HealthCheckIntervalMinutes)
        $every = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $interval -RepetitionDuration (New-TimeSpan -Days 3650)
        Register-TOTask 'HealthCheck' 'healthcheck.ps1' $every

        $daily = New-ScheduledTaskTrigger -Daily -At $cfg.BackupTime
        Register-TOTask 'Backup' 'backup.ps1' $daily

        if ($cfg.DuckDnsDomain) {
            if (-not (Get-TOSecret 'duckdns-token')) {
                $sec = Read-Host -AsSecureString "DuckDNS のトークンを入力してください（https://www.duckdns.org でログイン後に表示）"
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
                if (-not $plain) { throw 'DuckDNS トークンが空です。' }
                Set-TOSecret 'duckdns-token' $plain
            }
            $every5 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
            Register-TOTask 'DuckDNS' 'duckdns-update.ps1' $every5
            & "$TOScriptsDir\duckdns-update.ps1"
        } else {
            Unregister-ScheduledTask -TaskName 'DuckDNS' -TaskPath '\TrackOne\' -Confirm:$false -ErrorAction SilentlyContinue
            Write-TOLog 'DuckDnsDomain が空のため DuckDNS は設定しません' -Level WARN -Name $LogName
        }
    }

    Step 'Tailscale をインストール（未導入の場合）' {
        $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (-not (Test-Path $ts)) {
            & winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { Write-TOLog "Tailscale のインストールに失敗しました（$LASTEXITCODE）。手動で入れてください。" -Level WARN -Name $LogName }
        } else {
            Write-TOLog 'Tailscale は導入済み' -Name $LogName
        }
    }
}

} finally {
    if (-not $DryRun) { Exit-TOMaintenance }
}

# ============================================================
# 6. 完了
# ============================================================
Write-TOLog '=== インストール完了 ===' -Level OK -Name $LogName
$next = @"

次にやること:
  1. デスクトップの「TrackOne 管理画面」（または http://localhost:$($cfg.WebPort)）を開き、最初のアカウントを登録
     （最初のアカウントが管理者になります。2 人目以降は自由に登録できない設定が初期状態です）
  2. 端末を追加（名前と IMEI）
"@
if (-not $TestMode) {
    $next += "`r`n" + @"
  3. Tailscale にログインし、アプリ用の HTTPS 公開を有効化（--unattended は、再起動後に誰もログインしなくても接続を保つため）:
       & "`$env:ProgramFiles\Tailscale\tailscale.exe" up --unattended
       & "`$env:ProgramFiles\Tailscale\tailscale.exe" funnel --bg http://127.0.0.1:$($cfg.WebPort)
  4. ルーターでポート転送: 外部ポート → この PC の $($cfg.Gt06Port)/TCP
  5. 発信機に SMS で接続先を設定（docs/04_サーバー構築手順.md 参照）
"@
}
$next += "`r`n" + @"

設定を変えたときは C:\TrackOneServer\config\config.psd1 を（管理者として開いたメモ帳で）編集し、次を実行:
  powershell -ExecutionPolicy Bypass -File C:\TrackOneServer\scripts\install.ps1$(if ($TestMode) { ' -TestMode' })
"@
Write-Host $next
