# 配布用のファイル（Android の APK と Windows 版の ZIP）を作るスクリプト
#
# 使い方（app フォルダで）:
#   powershell -ExecutionPolicy Bypass -File tool\build_release.ps1
#
# できるもの（app\dist フォルダ。Git には入れない）:
#   TrackOneJapan-<版>.apk           Android 用（リリース署名）
#   TrackOneJapan-<版>-windows.zip   Windows 用（展開して TrackOneJapan.exe を起動）
#   SHA256SUMS.txt                   ファイルが壊れていないか確かめるためのハッシュ
#
# リリース署名には android\key.properties と鍵ファイルが必要です（無いとデバッグ用の鍵で署名されます）。
# 鍵をなくすと、同じアプリとして更新できなくなります。必ず別の場所にも保管してください。

$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
Set-Location $app

$version = ((Get-Content pubspec.yaml -Encoding UTF8 | Where-Object { $_ -match '^version:' }) -replace '^version:\s*', '' -replace '\+.*$', '').Trim()
if (-not $version) { throw 'pubspec.yaml の version が読めません' }
if (-not (Test-Path android\key.properties)) { Write-Warning 'android\key.properties がないため、APK はデバッグ用の鍵で署名されます' }

$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = 'C:\dev\flutter\bin\flutter.bat' }

function Invoke-Step([string]$title, [scriptblock]$block) {
    Write-Host "== $title" -ForegroundColor Cyan
    & $block
    if ($LASTEXITCODE -ne 0) { throw "$title に失敗しました（終了コード $LASTEXITCODE）" }
}

# Android は pub get 込みでビルドする（リリース版からテスト用のプラグインを外すため）。
# Windows は、開発者モードがオフの PC でもビルドできるよう、ジャンクションを作ってから --no-pub でビルドする
Invoke-Step 'テスト' { & $flutter test --no-pub }
Invoke-Step 'Android（APK）' { & $flutter build apk --release }
Invoke-Step 'Windows のプラグインのリンク' { & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'windows_link_plugins.ps1') }
Invoke-Step 'Windows' { & $flutter build windows --release --no-pub }

$dist = Join-Path $app 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
Get-ChildItem $dist -File | Remove-Item -Force

$apk = Join-Path $dist "TrackOneJapan-$version.apk"
Copy-Item build\app\outputs\flutter-apk\app-release.apk $apk

$zip = Join-Path $dist "TrackOneJapan-$version-windows.zip"
$staging = Join-Path $env:TEMP "TrackOneJapan-$version-windows"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Copy-Item build\windows\x64\runner\Release $staging -Recurse
Compress-Archive -Path $staging -DestinationPath $zip -Force
Remove-Item $staging -Recurse -Force

$sums = Get-ChildItem $dist -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
}
[IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'), $sums)

Write-Host ''
Write-Host "できました: $dist" -ForegroundColor Green
Get-ChildItem $dist -File | ForEach-Object { '  {0,-40} {1,8:N1} MB' -f $_.Name, ($_.Length / 1MB) }
