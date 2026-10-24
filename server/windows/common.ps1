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
$script:TraccarDir    = Join-Path $env:ProgramFiles 'Traccar'
$script:TraccarService = 'traccar'
$script:TONoFileLog   = $false

# ---------- ログ ----------
function Write-TOLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')] [string] $Level = 'INFO',
        [string] $Name = 'trackone'
    )
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
    return $cfg
}

# ---------- 秘密情報（管理者と SYSTEM だけが読めるファイル） ----------
function Initialize-SecretsDir {
    if (-not (Test-Path $TOSecretsDir)) { New-Item -ItemType Directory -Force $TOSecretsDir | Out-Null }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {   # Administrators, SYSTEM
        $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'FullControl', $inherit, $none, 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $TOSecretsDir -AclObject $acl
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

function New-TOPassword {
    param([int] $Length = 32)
    # 記号を含めない（コマンドライン・XML・接続文字列で問題が起きないように）
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
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
    $env:PGPASSWORD = $Password
    try {
        $out = & $psql -h 127.0.0.1 -p $Cfg.PostgresPort -U $User -d $Database -v ON_ERROR_STOP=1 -t -A -c $Sql 2>&1
        if ($LASTEXITCODE -ne 0) { throw "psql エラー: $out" }
        return ($out | Out-String).Trim()
    } finally {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
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

function Protect-TOFile {
    param([Parameter(Mandatory)] [string] $Path)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {   # Administrators, SYSTEM
        $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'Allow')))
    }
    Set-Acl -Path $Path -AclObject $acl
}

function Set-TOServiceRecovery {
    # サービスが落ちたら 1 分後に自動再起動（3 回まで、1 日でリセット）
    param([Parameter(Mandatory)] [string] $ServiceName, [string] $DependsOn)
    & sc.exe config $ServiceName start= auto | Out-Null
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    if ($DependsOn) { & sc.exe config $ServiceName depend= $DependsOn | Out-Null }
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
        description    = 'TrackOne Japan GPS Tracking'   # コマンドライン経由の文字化けを避けるため英語のみ
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
function Install-TraccarPackage {
    param([Parameter(Mandatory)] [string] $Version)
    $work = Join-Path $env:TEMP "trackone-traccar-$Version"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $zip = Join-Path $work "traccar-windows-64-$Version.zip"
    $url = "https://github.com/traccar/traccar/releases/download/v$Version/traccar-windows-64-$Version.zip"
    Write-TOLog "Traccar $Version をダウンロード: $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $work -Force
    $setup = Get-ChildItem -Path $work -Filter 'traccar-setup*.exe' -Recurse | Select-Object -First 1
    if (-not $setup) { throw 'traccar-setup.exe が見つかりません。' }
    $sig = Get-AuthenticodeSignature -FilePath $setup.FullName
    Write-TOLog "インストーラー署名: $($sig.Status)"
    Write-TOLog 'Traccar をインストール中（数分かかります）'
    $p = Start-Process -FilePath $setup.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Traccar のインストールに失敗しました（終了コード $($p.ExitCode)）。" }
    if (-not (Get-Service -Name $TraccarService -ErrorAction SilentlyContinue)) { throw 'traccar サービスが作成されていません。' }
    Set-Content -Path (Join-Path $TOStateDir 'traccar-version.txt') -Value $Version -Encoding ASCII
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-InstalledTraccarVersion {
    $f = Join-Path $TOStateDir 'traccar-version.txt'
    if ((Test-Path $f) -and (Test-Path (Join-Path $TraccarDir 'tracker-server.jar'))) { return (Get-Content $f -Raw).Trim() }
    return $null
}
