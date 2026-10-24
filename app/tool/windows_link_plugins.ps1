# Windows 版をビルドするための補助スクリプト（開発者モードがオフの PC 用）
#
# Flutter は Windows 版のビルド時に、プラグインのフォルダへの「シンボリックリンク」を作ります。
# シンボリックリンクは Windows の開発者モードがオンでないと作れないため、
# 開発者モードをオンにできない場合は、代わりに「ジャンクション」（管理者権限不要）を作ります。
#
# 使い方（app フォルダで）:
#   flutter pub get                          # 「symlink support」の警告が出ても続行
#   powershell -ExecutionPolicy Bypass -File tool\windows_link_plugins.ps1
#   flutter build windows --release
#
# パッケージを追加・更新したら、もう一度実行してください。

$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$deps = Join-Path $app '.flutter-plugins-dependencies'
if (-not (Test-Path $deps)) { throw '.flutter-plugins-dependencies がありません。先に flutter pub get を実行してください' }

$json = Get-Content $deps -Raw -Encoding UTF8 | ConvertFrom-Json
$linkDir = Join-Path $app 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force $linkDir | Out-Null

foreach ($p in $json.plugins.windows) {
    $target = ($p.path -replace '\\+', '\').TrimEnd('\')
    $link = Join-Path $linkDir $p.name
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.Target -and ((@($item.Target)[0]).TrimEnd('\') -eq $target)) { Write-Host "OK      $($p.name)"; continue }
        # 古いリンク（バージョン違い）は作り直す。リンク先の中身は消さない
        cmd /c rmdir "$link" | Out-Null
    }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Host "linked  $($p.name) -> $target"
}
