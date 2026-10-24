# TrackOneJapan サーバー: 共通処理
# 各スクリプトの先頭で  . "$PSScriptRoot\common.ps1"  として読み込みます。
# Windows PowerShell 5.1 で動くように書いています。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TORoot        = 'C:\TrackOneServer'
$script:TOConfigDir   = Join-Path $TORoot 'config'
$script:TOSecretsDir  = Join-Path $TORoot 'secrets'
$script:TOScriptsDir  = Join-Path $TORoot 'scripts'
$script:TOBackupDir   = Join-Path $TORoot 'backup'
$script:TOLogDir      = Join-Path $TORoot 'logs'
$script:TOStateDir    = Join-Path $TORoot 'state'
$script:TOWebOverrideDir = Join-Path $TORoot 'web-override'
$script:TOIconPath    = Join-Path $TORoot 'trackone.ico'
$script:TOMaintenanceFlag   = Join-Path $TOStateDir 'maintenance.flag'     # install / restore / update の実行中
$script:TORestoreFailedFlag = Join-Path $TOStateDir 'restore-failed.flag'  # 復元に失敗して Traccar を止めている
$script:TraccarDir    = Join-Path $env:ProgramFiles 'Traccar'
$script:TraccarService = 'traccar'
$script:TONoFileLog   = $false

# 日本語版 Windows でも名前が変わらないよう、アカウントは SID で指定する
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidSystem         = 'S-1-5-18'
$script:SidUsers          = 'S-1-5-32-545'

# ---------- ログ ----------
function Write-TOLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')] [string] $Level = 'INFO',
        [string] $Name
    )
    if (-not $Name) {
        # 呼び出し元スクリプトの $LogName があればそれを使う
        $Name = Get-Variable -Name LogName -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if (-not $Name) { $Name = 'trackone' }
    }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    if ($script:TONoFileLog) { return }   # DryRun 中はファイルに書かない
    try {
        if (-not (Test-Path $TOLogDir)) { New-Item -ItemType Directory -Force $TOLogDir | Out-Null }
        $file = Join-Path $TOLogDir ('{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMM'))
        Add-Content -Path $file -Value $line -Encoding UTF8
    } catch { }
}

# ---------- 前提チェック ----------
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '管理者として実行してください（PowerShell を右クリック →「管理者として実行」）。'
    }
}

# ---------- 設定 ----------
function Get-TOConfig {
    param([string] $Path)
    if (-not $Path) {
        $installed = Join-Path $TOConfigDir 'config.psd1'
        $local = Join-Path $PSScriptRoot 'config.psd1'
        if (Test-Path $installed) { $Path = $installed }
        elseif (Test-Path $local) { $Path = $local }
        else { throw "config.psd1 が見つかりません。config.example.psd1 を config.psd1 にコピーして編集してください。" }
    }
    $cfg = Import-PowerShellDataFile -Path $Path
    $required = 'TraccarVersion', 'WebPort', 'Gt06Port', 'OsmAndPort', 'EnabledProtocols', 'PostgresPackageId',
                'PostgresMajor', 'PostgresPort', 'DatabaseName', 'DatabaseUser', 'BackupTime', 'BackupKeepDays'
    foreach ($k in $required) {
        if (-not $cfg.ContainsKey($k)) { throw "config.psd1 に $k がありません。" }
    }
    # 省略できる項目の既定値（古い config.psd1 でも動くように）
    $defaults = @{
        DuckDnsDomain              = ''
        BackupCopyTo               = ''
        HealthCheckIntervalMinutes = 5
        ActiveHoursStart           = 7
        ActiveHoursEnd             = 23
        GeocoderEnabled            = $true
        GeocoderLanguage           = 'ja'
    }
    foreach ($k in $defaults.Keys) {
        if (-not $cfg.ContainsKey($k) -or $null -eq $cfg[$k]) { $cfg[$k] = $defaults[$k] }
    }
    if ([string]$cfg.TraccarVersion -notmatch '^\d+\.\d+(\.\d+)?$') { throw "config.psd1 の TraccarVersion が正しくありません: $($cfg.TraccarVersion)" }
    $ranges = @{ HealthCheckIntervalMinutes = 1, 1440; BackupKeepDays = 1, 3650; ActiveHoursStart = 0, 23; ActiveHoursEnd = 0, 23 }
    foreach ($k in $ranges.Keys) {
        $n = 0
        if (-not [int]::TryParse([string]$cfg[$k], [ref]$n) -or $n -lt $ranges[$k][0] -or $n -gt $ranges[$k][1]) {
            throw "config.psd1 の $k は $($ranges[$k][0])〜$($ranges[$k][1]) の整数にしてください（現在: $($cfg[$k])）。"
        }
        $cfg[$k] = $n
    }
    return $cfg
}

function Test-TOProtocolEnabled {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string] $Protocol)
    $list = @(([string]$Cfg.EnabledProtocols).Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() })
    return ($list -contains $Protocol.ToLowerInvariant())
}

function ConvertTo-TOVersion {
    # '6.16' と '6.16.0' を同じものとして比較できるようにする
    param([Parameter(Mandatory)] [string] $Text)
    $parts = @($Text.Trim().Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    return [version]($parts -join '.')
}

# ---------- 外部コマンドの実行 ----------
function Invoke-TONative {
    # PowerShell 5.1 では $ErrorActionPreference = 'Stop' のまま 2>&1 を使うと、
    # 終了コードが 0 でも標準エラーに 1 行出ただけで例外になる。
    # ここでは一時的に Continue にして実行し、成否は終了コードだけで判断する。
    param([Parameter(Mandatory)] [string] $FilePath, [string[]] $ArgumentList = @())
    # 見つからないと Continue のもとでは例外にならず、前回の終了コードが残ってしまうので先に確認する
    if (-not (Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue)) { throw "プログラムが見つかりません: $FilePath" }
    $global:LASTEXITCODE = $null
    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($_.Exception.Message) }
            else { $stdout.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
    }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = ($stdout -join "`r`n").Trim()
        Error    = ($stderr -join "`r`n").Trim()
    }
}

# ---------- アクセス権 ----------
function New-TOAccessRule {
    param(
        [Parameter(Mandatory)] [string] $Sid,
        [Parameter(Mandatory)] [string] $Rights,
        [string] $Inheritance = 'ContainerInherit, ObjectInherit',
        [string] $Propagation = 'None'
    )
    $id = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $id,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        [System.Security.AccessControl.InheritanceFlags]$Inheritance,
        [System.Security.AccessControl.PropagationFlags]$Propagation,
        [System.Security.AccessControl.AccessControlType]::Allow)
}

function Protect-TODirectory {
    # 親の権限を引き継がず、管理者と SYSTEM（と指定した SID の読み取り）だけにする。中のファイルにも反映される
    param([Parameter(Mandatory)] [string] $Path, [string[]] $ReadSids = @())
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force $Path | Out-Null }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $SidAdministrators, $SidSystem) { $acl.AddAccessRule((New-TOAccessRule $sid 'FullControl')) }
    foreach ($sid in $ReadSids) { $acl.AddAccessRule((New-TOAccessRule $sid 'ReadAndExecute')) }
    Set-Acl -Path $Path -AclObject $acl
}

function Protect-TOFile {
    param([Parameter(Mandatory)] [string] $Path)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $SidAdministrators, $SidSystem) { $acl.AddAccessRule((New-TOAccessRule $sid 'FullControl' 'None')) }
    Set-Acl -Path $Path -AclObject $acl
}

function Reset-TOItemAcl {
    # 個別に付いた権限を消し、親フォルダの権限だけを引き継ぐ状態に戻す
    param([Parameter(Mandatory)] [string] $Path, [string[]] $ReadSids = @())
    if (Test-Path -Path $Path -PathType Container) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        foreach ($sid in $ReadSids) { $acl.AddAccessRule((New-TOAccessRule $sid 'ReadAndExecute')) }
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($false, $false)
    Set-Acl -Path $Path -AclObject $acl
}

function Set-TOServerAcl {
    # C:\TrackOneServer の権限を固める。C:\ の既定（Authenticated Users に変更権限）のままだと、
    # 一般ユーザーが SYSTEM で動くスクリプトを書き換えたり、バックアップ（DB パスワード入り）を読めてしまうため。
    #   ルート          : 管理者・SYSTEM はフル。Users はルート直下のファイル（アイコン）を読むだけ
    #   scripts / config / web-override : Users は読み取りのみ（traccar.xml は個別に管理者のみ）
    #   backup / secrets : 管理者・SYSTEM のみ（親の権限も引き継がない）
    #   state           : 管理者・SYSTEM のみ
    #   logs            : 管理者・SYSTEM と、インストールした人（管理者権限なしでもログを見られるように）
    param([string] $InstallerSid)
    if (-not (Test-Path $TORoot)) { New-Item -ItemType Directory -Force $TORoot | Out-Null }

    $root = New-Object System.Security.AccessControl.DirectorySecurity
    $root.SetAccessRuleProtection($true, $false)
    foreach ($sid in $SidAdministrators, $SidSystem) { $root.AddAccessRule((New-TOAccessRule $sid 'FullControl')) }
    # NoPropagateInherit: ルート直下のファイルだけに効き、サブフォルダの中には伝わらない
    $root.AddAccessRule((New-TOAccessRule $SidUsers 'ReadAndExecute' 'ObjectInherit' 'NoPropagateInherit'))
    Set-Acl -Path $TORoot -AclObject $root

    $explicit = @{}
    foreach ($d in $TOScriptsDir, $TOConfigDir, $TOWebOverrideDir) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
        Reset-TOItemAcl -Path $d -ReadSids @($SidUsers)
        $explicit[$d] = $true
    }
    if (-not (Test-Path $TOStateDir)) { New-Item -ItemType Directory -Force $TOStateDir | Out-Null }
    Reset-TOItemAcl -Path $TOStateDir
    $explicit[$TOStateDir] = $true

    $logReaders = @()
    if ($InstallerSid -and $InstallerSid -ne $SidSystem) { $logReaders = @($InstallerSid) }
    if (-not (Test-Path $TOLogDir)) { New-Item -ItemType Directory -Force $TOLogDir | Out-Null }
    Reset-TOItemAcl -Path $TOLogDir -ReadSids $logReaders
    $explicit[$TOLogDir] = $true

    Protect-TODirectory -Path $TOBackupDir
    $explicit[$TOBackupDir] = $true
    Initialize-SecretsDir

    # 既にあるファイル・フォルダに個別に付いている権限を消す（traccar.xml など保護済みのものはそのまま）
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier($SidAdministrators)
    $okOwners = @($SidAdministrators, $SidSystem, 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')   # TrustedInstaller
    $items = @(Get-ChildItem -Path $TORoot -Recurse -Force | Where-Object {
        $_.FullName -ne $TOSecretsDir -and -not $_.FullName.StartsWith($TOSecretsDir + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    $items += Get-Item $TORoot
    foreach ($item in $items) {
        $path = $item.FullName
        $acl = Get-Acl -Path $path
        # 一般ユーザーが作ったファイルは所有者として権限を戻せてしまうので、所有者を Administrators にする
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
        if ($null -eq $owner -or $okOwners -notcontains $owner.Value) {
            try {
                # Set-Acl は所有者だけを渡してもアクセス権まで書き換えてしまうため、.NET で所有者だけを書き込む
                if ($item.PSIsContainer) {
                    $o = New-Object System.Security.AccessControl.DirectorySecurity
                    $o.SetOwner($adminSid)
                    [System.IO.Directory]::SetAccessControl($path, $o)
                } else {
                    $o = New-Object System.Security.AccessControl.FileSecurity
                    $o.SetOwner($adminSid)
                    [System.IO.File]::SetAccessControl($path, $o)
                }
            } catch {
                Write-TOLog "所有者を変更できませんでした: $path（$($_.Exception.Message)）" -Level WARN
            }
        }
        if ($path -eq $TORoot -or $explicit.ContainsKey($path) -or $acl.AreAccessRulesProtected) { continue }
        $rules = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
        if ($rules.Count -gt 0) { Reset-TOItemAcl -Path $path }
    }
}

# ---------- 秘密情報（管理者と SYSTEM だけが読めるファイル） ----------
function Initialize-SecretsDir {
    Protect-TODirectory -Path $TOSecretsDir
}

function Get-TOSecret {
    param([Parameter(Mandatory)] [string] $Name)
    $file = Join-Path $TOSecretsDir "$Name.txt"
    if (Test-Path $file) { return (Get-Content -Path $file -Raw).Trim() }
    return $null
}

function Set-TOSecret {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Value)
    Initialize-SecretsDir
    Set-Content -Path (Join-Path $TOSecretsDir "$Name.txt") -Value $Value -Encoding ASCII -NoNewline
}

function Remove-TOSecret {
    param([Parameter(Mandatory)] [string] $Name)
    Remove-Item -Path (Join-Path $TOSecretsDir "$Name.txt") -Force -ErrorAction SilentlyContinue
}

function New-TOPassword {
    param([int] $Length = 32)
    # 記号を含めない（コマンドライン・XML・接続文字列で問題が起きないように）
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Find-TOSecretInLogs {
    # インストーラーのログなどにパスワードがそのまま残っていないか探す（見つかったファイル名だけを返す）
    # $Secret は複数指定可（どれか 1 つでも含むファイルを返す）
    param([Parameter(Mandatory)] [string[]] $Secret)
    $files = @()
    $diag = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    foreach ($dir in $diag, $env:TEMP, (Join-Path $env:SystemRoot 'Temp')) {
        if ($dir -and (Test-Path $dir)) { $files += @(Get-ChildItem -Path $dir -File -Filter '*.log' -ErrorAction SilentlyContinue) }
    }
    $wingetTemp = Join-Path $env:TEMP 'WinGet'
    if (Test-Path $wingetTemp) { $files += @(Get-ChildItem -Path $wingetTemp -File -Filter '*.log' -Recurse -ErrorAction SilentlyContinue) }
    $found = @()
    foreach ($f in $files) {
        $hit = Select-String -Path $f.FullName -Pattern $Secret -SimpleMatch -List -Quiet -ErrorAction SilentlyContinue
        if ($hit) { $found += $f.FullName }
    }
    return $found
}

# ---------- PostgreSQL ----------
function Get-PgServiceName { param($Cfg) return "postgresql-x64-$($Cfg.PostgresMajor)" }
function Get-PgBin { param($Cfg) return Join-Path $env:ProgramFiles "PostgreSQL\$($Cfg.PostgresMajor)\bin" }

function Invoke-Psql {
    param(
        [Parameter(Mandatory)] $Cfg,
        [Parameter(Mandatory)] [string] $Sql,
        [string] $User = 'postgres',
        [string] $Password,
        [string] $Database = 'postgres'
    )
    $psql = Join-Path (Get-PgBin $Cfg) 'psql.exe'
    # SQL はファイル経由で渡す（PowerShell 5.1 は外部コマンドの引数内の " を壊すため）
    $sqlFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($sqlFile, $Sql, (New-Object System.Text.UTF8Encoding($false)))
    $env:PGPASSWORD = $Password
    $env:PGCLIENTENCODING = 'UTF8'
    try {
        $r = Invoke-TONative -FilePath $psql -ArgumentList @('-h', '127.0.0.1', '-p', [string]$Cfg.PostgresPort, '-U', $User, '-d', $Database,
            '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-q', '-f', $sqlFile)
        if ($r.ExitCode -ne 0) { throw "psql エラー（終了コード $($r.ExitCode)）: $($r.Error) $($r.Output)" }
        return $r.Output
    } finally {
        Remove-Item Env:\PGPASSWORD, Env:\PGCLIENTENCODING -ErrorAction SilentlyContinue
        Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-TOPgLogin {
    # postgres ユーザーでログインできるか（起動直後に備えて何回か試す）
    param([Parameter(Mandatory)] $Cfg, [string] $Password, [int] $Tries = 6)
    for ($i = 1; $i -le $Tries; $i++) {
        try { Invoke-Psql -Cfg $Cfg -Sql 'SELECT 1' -Password $Password | Out-Null; return $true }
        catch { if ($i -lt $Tries) { Start-Sleep -Seconds 5 } }
    }
    return $false
}

function Set-TOPgRolePassword {
    # パスワードはログ・画面・PostgreSQL のログに出さない
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string] $Role, [Parameter(Mandatory)] [string] $NewPassword,
          [Parameter(Mandatory)] [string] $SuPassword)
    if ($Role -notmatch '^[a-z_][a-z0-9_]*$') { throw "ユーザー名が正しくありません: $Role" }
    if ($NewPassword -notmatch '^[A-Za-z0-9]+$') { throw '新しいパスワードに使えない文字が含まれています。' }
    $sql = "SET log_statement = 'none';`nSET log_min_error_statement = 'panic';`nALTER ROLE $Role WITH LOGIN PASSWORD '$NewPassword';"
    try {
        Invoke-Psql -Cfg $Cfg -Sql $sql -Password $SuPassword | Out-Null
    } catch {
        throw ("$Role のパスワード変更に失敗しました: " + $_.Exception.Message.Replace($NewPassword, '********'))
    }
}

function Update-TOPostgresPassword {
    # postgres（管理者ユーザー）のパスワードを新しくする。
    # 途中で止まっても分からなくならないよう、先に新しいパスワードを db-postgres-password-new に保存しておく。
    param([Parameter(Mandatory)] $Cfg)
    $old = Get-TOSecret 'db-postgres-password'
    if (-not $old) { throw 'postgres のパスワードがありません。' }
    $new = New-TOPassword
    Set-TOSecret 'db-postgres-password-new' $new
    Set-TOPgRolePassword -Cfg $Cfg -Role 'postgres' -NewPassword $new -SuPassword $old
    Set-TOSecret 'db-postgres-password' $new
    Remove-TOSecret 'db-postgres-password-new'
}

function Update-TOTraccarDbPassword {
    # Traccar 用ユーザーのパスワードを新しくし、traccar.xml を作り直す（Traccar の再起動は呼び出し側で行う）
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string] $TemplatePath)
    $su = Get-TOSecret 'db-postgres-password'
    $new = New-TOPassword
    Set-TOSecret 'db-traccar-password-new' $new
    Set-TOPgRolePassword -Cfg $Cfg -Role $Cfg.DatabaseUser -NewPassword $new -SuPassword $su
    Set-TOSecret 'db-traccar-password' $new
    Remove-TOSecret 'db-traccar-password-new'
    Install-TraccarConfig -Cfg $Cfg -TemplatePath $TemplatePath
}

function Test-TODatabaseHasTraccar {
    # Traccar のテーブルが既にあるか（データの入ったデータベースか）
    param([Parameter(Mandatory)] $Cfg)
    $r = Invoke-Psql -Cfg $Cfg -Sql "SELECT to_regclass('public.tc_servers') IS NOT NULL" -Password (Get-TOSecret 'db-postgres-password') -Database $Cfg.DatabaseName
    return ($r -eq 't')
}

# ---------- Traccar 設定ファイル ----------
function New-TraccarXml {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string] $TemplatePath)
    $dbPassword = Get-TOSecret 'db-traccar-password'
    if (-not $dbPassword) { throw 'DB パスワードがありません。install.ps1 を実行してください。' }
    $geo = 'false'
    if ($Cfg.ContainsKey('GeocoderEnabled') -and $Cfg.GeocoderEnabled) { $geo = 'true' }
    $lang = 'ja'
    if ($Cfg.ContainsKey('GeocoderLanguage') -and $Cfg.GeocoderLanguage) { $lang = $Cfg.GeocoderLanguage }
    $map = @{
        '{{POSTGRES_PORT}}'     = [string]$Cfg.PostgresPort
        '{{DATABASE_NAME}}'     = $Cfg.DatabaseName
        '{{DATABASE_USER}}'     = $Cfg.DatabaseUser
        '{{DATABASE_PASSWORD}}' = $dbPassword
        '{{WEB_PORT}}'          = [string]$Cfg.WebPort
        '{{PROTOCOLS}}'         = $Cfg.EnabledProtocols
        '{{GT06_PORT}}'         = [string]$Cfg.Gt06Port
        '{{OSMAND_PORT}}'       = [string]$Cfg.OsmAndPort
        '{{GEOCODER_ENABLED}}'  = $geo
        '{{GEOCODER_LANGUAGE}}' = $lang
        '{{WEB_OVERRIDE}}'      = $TOWebOverrideDir
    }
    $xml = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    foreach ($k in $map.Keys) { $xml = $xml.Replace($k, [System.Security.SecurityElement]::Escape($map[$k])) }
    if ($xml -match '\{\{[A-Z_]+\}\}') { throw "traccar.xml に未置換の項目があります: $($Matches[0])" }
    [xml]$null = $xml   # XML として正しいか確認
    return $xml
}

function Install-TraccarConfig {
    # 原本（config\traccar.xml）を作り直し、Traccar のインストール先へコピーする
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string] $TemplatePath)
    $xml = New-TraccarXml -Cfg $Cfg -TemplatePath $TemplatePath
    $master = Join-Path $TOConfigDir 'traccar.xml'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($master, $xml, $utf8)
    # DB パスワードが入るので、原本もコピー先も管理者と SYSTEM だけが読めるようにする
    Protect-TOFile -Path $master
    $target = Join-Path $TraccarDir 'conf\traccar.xml'
    Copy-Item -Path $master -Destination $target -Force
    Protect-TOFile -Path $target
}

function Set-TOServiceRecovery {
    # サービスが落ちたら 1 分後に自動再起動（3 回まで、1 日でリセット）
    param([Parameter(Mandatory)] [string] $ServiceName, [string] $DependsOn)
    & sc.exe config $ServiceName start= auto | Out-Null
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    if ($DependsOn) { & sc.exe config $ServiceName depend= $DependsOn | Out-Null }
}

# ---------- サービスの停止・再起動（固まったときは強制終了） ----------
function Stop-TOService {
    param([Parameter(Mandatory)] [string] $Name, [int] $TimeoutSec = 120)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Stopped') { return }
    try {
        if ($svc.Status -ne 'StopPending') { $svc.Stop() }
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSec))
    } catch {
        Write-TOLog "$Name が $TimeoutSec 秒以内に止まらないため、プロセスを強制終了します" -Level WARN
        $procId = [int](Get-CimInstance Win32_Service -Filter "Name='$Name'").ProcessId
        if ($procId -gt 0) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
        $svc.Refresh()
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
}

function Restart-TOService {
    param([Parameter(Mandatory)] [string] $Name, [int] $TimeoutSec = 120)
    Stop-TOService -Name $Name -TimeoutSec $TimeoutSec
    Start-Service -Name $Name
}

# ---------- メンテナンス中の目印（死活監視が Traccar を勝手に起動しないように） ----------
function Enter-TOMaintenance {
    param([Parameter(Mandatory)] [string] $Reason)
    if (-not (Test-Path $TOStateDir)) { New-Item -ItemType Directory -Force $TOStateDir | Out-Null }
    $text = "reason=$Reason`r`npid=$PID`r`nstarted=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Set-Content -Path $TOMaintenanceFlag -Value $text -Encoding ASCII
}

function Exit-TOMaintenance {
    # 自分が立てた目印だけを消す
    if (-not (Test-Path $TOMaintenanceFlag)) { return }
    $text = Get-Content -Path $TOMaintenanceFlag -Raw -ErrorAction SilentlyContinue
    if ($text -match 'pid=(\d+)' -and [int]$Matches[1] -ne $PID) { return }
    Remove-Item -Path $TOMaintenanceFlag -Force -ErrorAction SilentlyContinue
}

function Get-TOMaintenanceState {
    # None   : メンテナンス中ではない
    # Active : メンテナンス中
    # Long   : 2 時間以上続いているが、実行中の処理はまだ動いている
    # Stale  : 2 時間以上前の目印で、実行していた処理も終わっている（消し忘れ）
    param([int] $MaxAgeHours = 2)
    if (-not (Test-Path $TOMaintenanceFlag)) { return 'None' }
    $item = Get-Item -Path $TOMaintenanceFlag
    if ($item.LastWriteTime -gt (Get-Date).AddHours(-$MaxAgeHours)) { return 'Active' }
    $text = Get-Content -Path $TOMaintenanceFlag -Raw -ErrorAction SilentlyContinue
    if ($text -match 'pid=(\d+)') {
        $p = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -match '^(powershell|pwsh)$') { return 'Long' }
    }
    return 'Stale'
}

# ---------- バックアップファイル ----------
function Get-TOBackupFiles {
    # ファイル名の日時（traccar-20261024-030000.dump など）で判断する。
    # コピーしたファイルは更新日時が元のままなので、更新日時は使わない。
    param([Parameter(Mandatory)] [string] $Path, [string] $Kind = 'traccar|config', [string] $Extension = 'dump|xml|psd1')
    if (-not (Test-Path $Path)) { return @() }
    $regex = "^(?:$Kind)-(?<stamp>\d{8}-\d{6})\.(?:$Extension)$"
    $result = @()
    foreach ($f in @(Get-ChildItem -Path $Path -File)) {
        $m = [regex]::Match($f.Name, $regex, 'IgnoreCase')
        if (-not $m.Success) { continue }
        $stamp = [datetime]::MinValue
        if ([datetime]::TryParseExact($m.Groups['stamp'].Value, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$stamp)) {
            $result += [pscustomobject]@{ File = $f; Stamp = $stamp }
        }
    }
    return $result
}

# ---------- オリジナルアイコン・ロゴ ----------
function Install-TOBranding {
    # アイコン類を配置し、Traccar のサーバー属性（タイトル・色・ロゴ）をデータベースに設定する
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string] $SourceDir)
    $srcWeb = Join-Path $SourceDir 'web-override'
    if (-not (Test-Path $TOWebOverrideDir)) { New-Item -ItemType Directory -Force $TOWebOverrideDir | Out-Null }
    if ((Resolve-Path $srcWeb).Path -ne (Resolve-Path $TOWebOverrideDir).Path) {
        Copy-Item -Path (Join-Path $srcWeb '*') -Destination $TOWebOverrideDir -Force
    }
    $srcIco = Join-Path $SourceDir 'trackone.ico'
    if ((Test-Path $srcIco) -and ((Resolve-Path $srcIco).Path -ne $TOIconPath)) { Copy-Item $srcIco $TOIconPath -Force }

    $branding = @{
        title          = 'TrackOne Japan'
        description    = 'TrackOne Japan - GPS 追跡システム'
        colorPrimary   = '#1F4A85'
        colorSecondary = '#E63946'
        logo           = '/trackone-logo.svg'
        logoInverted   = '/trackone-logo-inverted.svg'
    }
    $json = ($branding | ConvertTo-Json -Compress).Replace("'", "''")
    $sql = "UPDATE tc_servers SET attributes = (COALESCE(NULLIF(attributes, ''), '{}')::jsonb || '$json'::jsonb)::text"
    Invoke-Psql -Cfg $Cfg -Sql $sql -User $Cfg.DatabaseUser -Password (Get-TOSecret 'db-traccar-password') -Database $Cfg.DatabaseName | Out-Null
}

function New-TOShortcut {
    # 管理画面を開くショートカット（オリジナルアイコン付き）を全ユーザーのデスクトップに作る
    param([Parameter(Mandatory)] $Cfg)
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $lnk = Join-Path $desktop 'TrackOne 管理画面.url'
    $content = @"
[InternetShortcut]
URL=http://localhost:$($Cfg.WebPort)/
IconFile=$TOIconPath
IconIndex=0
"@
    Set-Content -Path $lnk -Value $content -Encoding Default
}

# ---------- 動作確認 ----------
function Test-TcpPort {
    param([string] $HostName = '127.0.0.1', [Parameter(Mandatory)] [int] $Port, [int] $TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

function Test-TraccarApi {
    param([Parameter(Mandatory)] $Cfg, [int] $TimeoutSec = 10)
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($Cfg.WebPort)/api/server" -TimeoutSec $TimeoutSec
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Wait-TraccarApi {
    param([Parameter(Mandatory)] $Cfg, [int] $TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TraccarApi -Cfg $Cfg -TimeoutSec 5) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

# ---------- Traccar のダウンロード・インストール ----------
function Get-TraccarPackage {
    # ダウンロード・展開・署名の確認だけを行う（Traccar は止めない）
    param([Parameter(Mandatory)] [string] $Version)
    $work = Join-Path $env:TEMP "trackone-traccar-$Version"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $zip = Join-Path $work "traccar-windows-64-$Version.zip"
    $url = "https://github.com/traccar/traccar/releases/download/v$Version/traccar-windows-64-$Version.zip"
    Write-TOLog "Traccar $Version をダウンロード: $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $work -Force
        $setup = Get-ChildItem -Path $work -Filter 'traccar-setup*.exe' -Recurse | Select-Object -First 1
        if (-not $setup) { throw 'traccar-setup.exe が見つかりません。' }
        $sig = Get-AuthenticodeSignature -FilePath $setup.FullName
        $sigLevel = 'INFO'
        if ($sig.Status -ne 'Valid') { $sigLevel = 'WARN' }
        Write-TOLog "インストーラー署名: $($sig.Status)" -Level $sigLevel
    } catch {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "Traccar $Version のダウンロードに失敗しました（バージョン番号とネット接続を確認してください）: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ Version = $Version; SetupPath = $setup.FullName; WorkDir = $work }
}

function Install-TraccarPackage {
    # Get-TraccarPackage で用意したインストーラーを実行する（Traccar は呼び出し側で止めておく）
    param([Parameter(Mandatory)] $Package)
    Write-TOLog "Traccar $($Package.Version) をインストール中（数分かかります）"
    $p = Start-Process -FilePath $Package.SetupPath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Traccar のインストールに失敗しました（終了コード $($p.ExitCode)）。" }
    if (-not (Get-Service -Name $TraccarService -ErrorAction SilentlyContinue)) { throw 'traccar サービスが作成されていません。' }
    if (-not (Test-Path $TOStateDir)) { New-Item -ItemType Directory -Force $TOStateDir | Out-Null }
    Set-Content -Path (Join-Path $TOStateDir 'traccar-version.txt') -Value $Package.Version -Encoding ASCII
}

function Remove-TraccarPackage {
    param($Package)
    if ($Package -and (Test-Path $Package.WorkDir)) { Remove-Item $Package.WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-InstalledTraccarVersion {
    $f = Join-Path $TOStateDir 'traccar-version.txt'
    if ((Test-Path $f) -and (Test-Path (Join-Path $TraccarDir 'tracker-server.jar'))) { return (Get-Content $f -Raw).Trim() }
    return $null
}
