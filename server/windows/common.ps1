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
$script:TraccarVirtualAccount = 'NT SERVICE\traccar'   # Traccar 専用の最小権限アカウント（パスワード不要の仮想アカウント）
$script:TOTestModeFlag = Join-Path $TOStateDir 'test-mode.flag'   # install.ps1 -TestMode で入れた PC
$script:TONoFileLog   = $false
$script:TOPrivateTempReady = $false

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
        ServiceAccount             = $TraccarVirtualAccount
        TraccarSha256              = ''
    }
    foreach ($k in $defaults.Keys) {
        if (-not $cfg.ContainsKey($k) -or $null -eq $cfg[$k]) { $cfg[$k] = $defaults[$k] }
    }
    # ここで確かめる値は、パスやコマンドの組み立て（SYSTEM で動くバックアップ等）に使われるため、形式を厳しく確認する
    if ([string]$cfg.TraccarVersion -notmatch '^\d+\.\d+(\.\d+)?$') { throw "config.psd1 の TraccarVersion が正しくありません: $($cfg.TraccarVersion)" }
    if ([string]$cfg.PostgresMajor -notmatch '^\d+$') { throw "config.psd1 の PostgresMajor は数字だけにしてください（現在: $($cfg.PostgresMajor)）。" }
    if ([string]$cfg.PostgresPackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]*$') { throw "config.psd1 の PostgresPackageId が正しくありません: $($cfg.PostgresPackageId)" }
    if (([string]$cfg.EnabledProtocols).Replace(' ', '') -notmatch '^[a-z0-9]+(,[a-z0-9]+)*$') { throw "config.psd1 の EnabledProtocols は 'gt06' や 'gt06,osmand' の形にしてください（現在: $($cfg.EnabledProtocols)）。" }
    $cfg.EnabledProtocols = ([string]$cfg.EnabledProtocols).Replace(' ', '')
    if (@($TraccarVirtualAccount, 'LocalSystem') -notcontains [string]$cfg.ServiceAccount) {
        throw "config.psd1 の ServiceAccount は '$TraccarVirtualAccount'（推奨）か 'LocalSystem' にしてください（現在: $($cfg.ServiceAccount)）。"
    }
    if ([string]$cfg.TraccarSha256 -and [string]$cfg.TraccarSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "config.psd1 の TraccarSha256 は 64 文字の 16 進数にしてください（空なら GitHub のリリース情報で確認します）。" }
    # テスト用 PC（install.ps1 -TestMode）では、PC 自身からのテスト送信用に OsmAnd 方式も受け付ける
    if ((Test-Path $TOTestModeFlag) -and -not (Test-TOProtocolEnabled $cfg 'osmand')) { $cfg.EnabledProtocols = "$($cfg.EnabledProtocols),osmand" }
    $ranges = @{ HealthCheckIntervalMinutes = 1, 1440; BackupKeepDays = 1, 3650; ActiveHoursStart = 0, 23; ActiveHoursEnd = 0, 23
                 WebPort = 1, 65535; Gt06Port = 1, 65535; OsmAndPort = 1, 65535; PostgresPort = 1, 65535 }
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
    # 管理者と SYSTEM（と指定した SID の読み取り）だけにする
    param([Parameter(Mandatory)] [string] $Path, [string[]] $ReadSids = @())
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $SidAdministrators, $SidSystem) { $acl.AddAccessRule((New-TOAccessRule $sid 'FullControl' 'None')) }
    foreach ($sid in $ReadSids) { $acl.AddAccessRule((New-TOAccessRule $sid 'Read' 'None')) }
    Set-Acl -Path $Path -AclObject $acl
}

function Set-TOOwnerToAdministrators {
    # 一般ユーザーが作ったファイル・フォルダは、所有者として権限を戻せてしまうので、所有者を Administrators にする
    # （管理者・SYSTEM・TrustedInstaller が所有者ならそのまま）
    param([Parameter(Mandatory)] $Item)
    $okOwners = @($SidAdministrators, $SidSystem, 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')   # TrustedInstaller
    $path = $Item.FullName
    $owner = (Get-Acl -Path $path).GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($null -ne $owner -and $okOwners -contains $owner.Value) { return }
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier($SidAdministrators)
    try {
        # Set-Acl は所有者だけを渡してもアクセス権まで書き換えてしまうため、.NET で所有者だけを書き込む
        if ($Item.PSIsContainer) {
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

function Get-TOServiceSid {
    # サービス専用アカウント（NT SERVICE\<名前>）の SID。サービス名から決まるので、サービスが無くても計算できる
    # （sc.exe showsid と同じ値: S-1-5-80- + 大文字のサービス名（UTF-16LE）の SHA-1 を 4 バイトずつ区切った数）
    param([Parameter(Mandatory)] [string] $Name)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $h = $sha.ComputeHash([System.Text.Encoding]::Unicode.GetBytes($Name.ToUpperInvariant())) } finally { $sha.Dispose() }
    $parts = @(0..4 | ForEach-Object { [BitConverter]::ToUInt32($h, $_ * 4) })
    return 'S-1-5-80-' + ($parts -join '-')
}

function Find-TOLinkInPath {
    # パス（とその途中のフォルダ）にジャンクション・シンボリックリンクがあれば、その場所を返す（なければ $null）。
    # SYSTEM で動く処理が、一般ユーザーの仕掛けたリンクをたどって別の場所に書き込んだり削除したりしないようにする
    param([Parameter(Mandatory)] [string] $Path)
    $p = [System.IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force
            if ($item.PSObject.Properties['LinkType'] -and @('Junction', 'SymbolicLink') -contains [string]$item.LinkType) { return $p }
        }
        $parent = [System.IO.Path]::GetDirectoryName($p)
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $null
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
        $readers = @($SidUsers)
        # web-override は Traccar（専用アカウント）が読んで配信する
        if ($d -eq $TOWebOverrideDir) { $readers += Get-TOServiceSid $TraccarService }
        Reset-TOItemAcl -Path $d -ReadSids $readers
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
    # secrets は Initialize-SecretsDir で所有者・権限を直している
    $items = @(Get-ChildItem -Path $TORoot -Recurse -Force | Where-Object {
        $_.FullName -ne $TOSecretsDir -and -not $_.FullName.StartsWith($TOSecretsDir + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    $items += Get-Item $TORoot
    foreach ($item in $items) {
        $path = $item.FullName
        Set-TOOwnerToAdministrators -Item $item
        $acl = Get-Acl -Path $path
        if ($path -eq $TORoot -or $explicit.ContainsKey($path) -or $acl.AreAccessRulesProtected) { continue }
        $rules = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
        if ($rules.Count -gt 0) { Reset-TOItemAcl -Path $path }
    }
}

# ---------- 秘密情報（管理者と SYSTEM だけが読めるファイル） ----------
function Initialize-SecretsDir {
    Protect-TODirectory -Path $TOSecretsDir
    # 移設のときに一般ユーザーの権限で作ったフォルダ・コピーしたファイルは、所有者がその人のままだと
    # 後から権限を戻してパスワードを読めてしまう。所有者を Administrators にし、個別の権限も外す
    $items = @(Get-Item -LiteralPath $TOSecretsDir -Force) + @(Get-ChildItem -LiteralPath $TOSecretsDir -Recurse -Force)
    foreach ($item in $items) {
        Set-TOOwnerToAdministrators -Item $item
        if ($item.FullName -eq $TOSecretsDir) { continue }
        $acl = Get-Acl -Path $item.FullName
        if ($acl.AreAccessRulesProtected -or $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]).Count -gt 0) {
            Reset-TOItemAcl -Path $item.FullName
        }
    }
}

function Get-TOPrivateTempDir {
    # パスワード入りの SQL などを一時的に置くフォルダ（管理者と SYSTEM だけが読める）
    $dir = Join-Path $TOStateDir 'tmp'
    if (-not $script:TOPrivateTempReady -or -not (Test-Path $dir)) {
        Protect-TODirectory -Path $dir
        $script:TOPrivateTempReady = $true
    }
    return $dir
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
    # SQL はファイル経由で渡す（PowerShell 5.1 は外部コマンドの引数内の " を壊すため）。
    # パスワード変更の SQL も入るので、ユーザーの %TEMP% ではなく管理者と SYSTEM だけが読める場所に置き、必ず消す
    $sqlFile = Join-Path (Get-TOPrivateTempDir) ([guid]::NewGuid().ToString('N') + '.sql')
    $env:PGPASSWORD = $Password
    $env:PGCLIENTENCODING = 'UTF8'
    try {
        [System.IO.File]::WriteAllText($sqlFile, $Sql, (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-TONative -FilePath $psql -ArgumentList @('-h', '127.0.0.1', '-p', [string]$Cfg.PostgresPort, '-U', $User, '-d', $Database,
            '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-q', '-f', $sqlFile)
        if ($r.ExitCode -ne 0) { throw "psql エラー（終了コード $($r.ExitCode)）: $($r.Error) $($r.Output)" }
        return $r.Output
    } finally {
        Remove-Item Env:\PGPASSWORD, Env:\PGCLIENTENCODING -ErrorAction SilentlyContinue
        Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
    }
}

function Remove-TOPgDataUserAccess {
    # PostgreSQL のインストーラーは、インストールした人のアカウントにデータフォルダのフルコントロールを付ける。
    # そのままだと、管理者権限なしで動く不正なプログラムが pg_hba.conf を書き換えたり、データを直接読んだりできる。
    # 一般ユーザーのアカウント（S-1-5-21-…）に個別に付いた権限だけを外す（PostgreSQL のサービスと管理者の権限はそのまま）
    param([Parameter(Mandatory)] $Cfg)
    $data = Join-Path $env:ProgramFiles "PostgreSQL\$($Cfg.PostgresMajor)\data"
    if (-not (Test-Path $data)) { Write-TOLog "PostgreSQL のデータフォルダが見つかりません: $data（権限の見直しを飛ばします）" -Level WARN; return }

    # PostgreSQL のサービスのアカウント（通常は NETWORK SERVICE）が書き込めることを先に確認する
    $svc = Get-CimInstance Win32_Service -Filter "Name='$(Get-PgServiceName $Cfg)'" -ErrorAction SilentlyContinue
    $svcSid = 'S-1-5-20'
    if ($svc -and $svc.StartName -and $svc.StartName -ne 'NT AUTHORITY\NetworkService') {
        try { $svcSid = (New-Object System.Security.Principal.NTAccount($svc.StartName)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { Write-TOLog "PostgreSQL のサービスアカウント（$($svc.StartName)）を確認できないため、データフォルダの権限は変更しません" -Level WARN; return }
    }
    $rules = @((Get-Acl -Path $data).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $write = [System.Security.AccessControl.FileSystemRights]::WriteData
    $svcCanWrite = @($rules | Where-Object { $_.IdentityReference.Value -eq $svcSid -and $_.AccessControlType -eq 'Allow' -and (($_.FileSystemRights -band $write) -eq $write) })
    if ($svcCanWrite.Count -eq 0) {
        Write-TOLog "PostgreSQL のサービス（$svcSid）の書き込み権限が見つからないため、データフォルダの権限は変更しません: $data" -Level WARN
        return
    }
    $userSids = @($rules | Where-Object { -not $_.IsInherited -and $_.IdentityReference.Value -match '^S-1-5-21-' } |
        ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique)
    foreach ($sid in $userSids) {
        $r = Invoke-TONative -FilePath 'icacls.exe' -ArgumentList @($data, '/remove:g', "*$sid", '/T', '/C', '/Q')
        if ($r.ExitCode -ne 0) { throw "PostgreSQL のデータフォルダの権限を変更できませんでした（$sid）: $($r.Error) $($r.Output)" }
        Write-TOLog "PostgreSQL のデータフォルダから、一般ユーザーに個別に付いた権限を外しました: $sid"
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
    # コピー先は Traccar（専用アカウント NT SERVICE\traccar）にも読み取りだけ許可する
    Protect-TOFile -Path $target -ReadSids @(Get-TOServiceSid $TraccarService)
}

function Set-TOServiceRecovery {
    # サービスが落ちたら 1 分後に自動再起動（3 回まで、1 日でリセット）
    param([Parameter(Mandatory)] [string] $ServiceName, [string] $DependsOn)
    & sc.exe config $ServiceName start= auto | Out-Null
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    if ($DependsOn) { & sc.exe config $ServiceName depend= $DependsOn | Out-Null }
}

function Set-TOTraccarServiceAccount {
    # Traccar を、最小限の権限だけを持つ専用アカウント（NT SERVICE\traccar、パスワード不要の仮想アカウント）で動かす。
    # LocalSystem（PC の最高権限）のままだと、インターネットから届く通信を処理する Traccar に脆弱性が見つかったとき、
    # PC 全体を乗っ取られるおそれがあるため。何度実行しても同じ結果になる。起動・再起動は呼び出し側で行う。
    # Traccar のインストーラーはサービスを LocalSystem に戻すので、インストール・更新のたびに呼ぶ。
    param([Parameter(Mandatory)] $Cfg)
    if (-not (Get-Service -Name $TraccarService -ErrorAction SilentlyContinue)) { throw 'traccar サービスがありません。' }
    $account = [string]$Cfg.ServiceAccount
    if ($account -eq 'LocalSystem') {
        $r = Invoke-TONative -FilePath 'sc.exe' -ArgumentList @('config', $TraccarService, 'obj=', 'LocalSystem')
        if ($r.ExitCode -ne 0) { throw "traccar サービスのアカウントを LocalSystem に設定できませんでした: $($r.Output) $($r.Error)" }
        Write-TOLog 'config.psd1 の ServiceAccount が LocalSystem のため、Traccar を PC の最高権限で動かします（推奨しません）' -Level WARN
        return
    }

    $sid = Get-TOServiceSid $TraccarService
    # 読み取り: インストール先（プログラム・Java・テンプレート・画面）。
    # 書き込み: ログ（logs）・データ（data）・端末の画像など（media。Traccar の media.path の既定値 ./media）だけ
    $grants = @(
        @{ Path = $TraccarDir;                      Rights = '(OI)(CI)RX' },
        @{ Path = (Join-Path $TraccarDir 'logs');   Rights = '(OI)(CI)M' },
        @{ Path = (Join-Path $TraccarDir 'data');   Rights = '(OI)(CI)M' },
        @{ Path = (Join-Path $TraccarDir 'media');  Rights = '(OI)(CI)M' }
    )
    foreach ($g in $grants) {
        if (-not (Test-Path $g.Path)) { New-Item -ItemType Directory -Force $g.Path | Out-Null }
        $r = Invoke-TONative -FilePath 'icacls.exe' -ArgumentList @($g.Path, '/grant:r', "*${sid}:$($g.Rights)", '/C', '/Q')
        if ($r.ExitCode -ne 0) { throw "Traccar 用アカウントの権限を設定できませんでした: $($g.Path) / $($r.Error) $($r.Output)" }
    }
    # traccar.xml（DB パスワード入り）と web-override（アイコン・ロゴ）は読み取りだけ
    $conf = Join-Path $TraccarDir 'conf\traccar.xml'
    if (Test-Path $conf) { Protect-TOFile -Path $conf -ReadSids @($sid) }
    if (Test-Path $TOWebOverrideDir) { Reset-TOItemAcl -Path $TOWebOverrideDir -ReadSids @($SidUsers, $sid) }

    $r = Invoke-TONative -FilePath 'sc.exe' -ArgumentList @('config', $TraccarService, 'obj=', $TraccarVirtualAccount)
    if ($r.ExitCode -ne 0) { throw "traccar サービスのアカウントを $TraccarVirtualAccount に設定できませんでした: $($r.Output) $($r.Error)" }
    $now = (Get-CimInstance Win32_Service -Filter "Name='$TraccarService'").StartName
    if ($now -ne $TraccarVirtualAccount) { throw "traccar サービスのアカウントが $TraccarVirtualAccount になっていません（現在: $now）。" }
    Write-TOLog "Traccar を専用アカウント $TraccarVirtualAccount で動かします（最小権限）"
}

function Get-TOTraccarStartHint {
    # Traccar が起動しないときの案内（専用アカウントにしたことが原因かもしれない場合）
    param([Parameter(Mandatory)] $Cfg)
    if ([string]$Cfg.ServiceAccount -ne $TraccarVirtualAccount) { return '' }
    return "`n専用アカウント（$TraccarVirtualAccount）で動かしたことが原因の可能性があります。ログに AccessDenied などがあれば、" +
        "config.psd1 に ServiceAccount = 'LocalSystem' を書いて install.ps1 を再実行すると、以前の動かし方に戻せます。"
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
function Get-TraccarReleaseSha256 {
    # GitHub のリリース情報に載っている、配布ファイルの SHA-256（取れなければ $null）
    param([Parameter(Mandatory)] [string] $Version, [Parameter(Mandatory)] [string] $AssetName)
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Uri "https://api.github.com/repos/traccar/traccar/releases/tags/v$Version" `
            -Headers @{ 'User-Agent' = 'TrackOneJapan'; 'Accept' = 'application/vnd.github+json' }
    } catch {
        Write-TOLog "GitHub のリリース情報を取得できませんでした: $($_.Exception.Message)" -Level WARN
        return $null
    }
    $asset = @($rel.assets | Where-Object { $_.name -eq $AssetName }) | Select-Object -First 1
    if ($asset -and $asset.PSObject.Properties['digest'] -and ([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$')) {
        return $Matches[1].ToLowerInvariant()
    }
    return $null
}

function Test-TOSha256 {
    # ファイルの SHA-256 が期待した値と一致するか（大文字・小文字は区別しない）
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual -eq $Expected.Trim().ToUpperInvariant())
}

function Get-TraccarPackage {
    # ダウンロード・ハッシュの確認・展開・署名の確認だけを行う（Traccar は止めない）。
    # 一般ユーザーがインストーラーを差し替えられないよう、管理者と SYSTEM だけが使えるフォルダで作業する。
    #   ExpectedSha256 : 配布 ZIP の SHA-256（config.psd1 の TraccarSha256 など）。空なら GitHub のリリース情報で確認する
    #   AllowUnverified: ハッシュを確認できなかった場合でも続ける（通常は中止）
    param([Parameter(Mandatory)] [string] $Version, [string] $ExpectedSha256, [switch] $AllowUnverified)
    $downloadRoot = Join-Path $TOStateDir 'download'
    Protect-TODirectory -Path $downloadRoot
    $work = Join-Path $downloadRoot "traccar-$Version"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $assetName = "traccar-windows-64-$Version.zip"
    $zip = Join-Path $work $assetName
    $url = "https://github.com/traccar/traccar/releases/download/v$Version/$assetName"
    Write-TOLog "Traccar $Version をダウンロード: $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    try {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
        } catch {
            throw "Traccar $Version のダウンロードに失敗しました（バージョン番号とネット接続を確認してください）: $($_.Exception.Message)"
        }

        # 改ざん・破損の確認（ZIP の SHA-256）
        $source = 'config.psd1 の TraccarSha256'
        $expected = [string]$ExpectedSha256
        if (-not $expected) {
            $source = 'GitHub のリリース情報'
            $expected = Get-TraccarReleaseSha256 -Version $Version -AssetName $assetName
        }
        $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected) {
            if (-not (Test-TOSha256 -Path $zip -Expected $expected)) {
                throw "ダウンロードした Traccar のハッシュが一致しません（$source と比較）。改ざんや破損の可能性があるため中止しました。"
            }
            Write-TOLog "ダウンロードしたファイルのハッシュを確認しました（$source と一致）" -Level OK
        } elseif ($AllowUnverified) {
            Write-TOLog "ダウンロードしたファイルのハッシュを確認できませんでしたが、-AllowUnverifiedDownload のため続けます（SHA-256: $zipHash）" -Level WARN
        } else {
            throw ("ダウンロードした Traccar のハッシュを確認できませんでした（GitHub のリリース情報にハッシュがありません）。`n" +
                "https://github.com/traccar/traccar/releases で SHA-256 を確認して config.psd1 の TraccarSha256 に書くか、" +
                "確認せずに進める場合は -AllowUnverifiedDownload を付けて再実行してください。")
        }

        Expand-Archive -Path $zip -DestinationPath $work -Force
        $setup = Get-ChildItem -Path $work -Filter 'traccar-setup*.exe' -Recurse | Select-Object -First 1
        if (-not $setup) { throw 'traccar-setup.exe が見つかりません。' }
        $sig = Get-AuthenticodeSignature -FilePath $setup.FullName
        $sigLevel = 'INFO'
        if ($sig.Status -ne 'Valid') { $sigLevel = 'WARN' }
        Write-TOLog "インストーラー署名: $($sig.Status)" -Level $sigLevel
        $setupHash = (Get-FileHash -LiteralPath $setup.FullName -Algorithm SHA256).Hash
    } catch {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    return [pscustomobject]@{ Version = $Version; SetupPath = $setup.FullName; WorkDir = $work; ZipSha256 = $zipHash; SetupSha256 = $setupHash }
}

function Install-TraccarPackage {
    # Get-TraccarPackage で用意したインストーラーを実行する（Traccar は呼び出し側で止めておく）
    param([Parameter(Mandatory)] $Package)
    # 実行の直前に、確認したときのインストーラーから変わっていないかを確かめる
    if (-not (Test-TOSha256 -Path $Package.SetupPath -Expected $Package.SetupSha256)) {
        throw 'Traccar のインストーラーが、確認した後に変更されています。安全のため中止しました。'
    }
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
