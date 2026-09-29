param([ValidateSet('x64','arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rid = "win-$Architecture"
$rustTarget = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$probeDir = Join-Path $root 'dist/ffprobe-windows'
if (-not (Test-Path (Join-Path $probeDir 'ffprobe.exe'))) { throw 'Build ffprobe with build_ffprobe_windows.sh in the matching MSYS2 shell first.' }
Push-Location $root
try {
    rustup target add $rustTarget
    cargo test -p fillr-core
    cargo build --release -p fillr-core --target $rustTarget
    $publish = Join-Path $root "dist/windows-$Architecture"
    if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
    dotnet publish native/windows/FILLR.csproj -c Release -r $rid --self-contained true -o $publish
    if (-not (Test-Path (Join-Path $publish 'Assets/FILLR.ico'))) { throw 'Published Windows app is missing the FILLR icon.' }
    Copy-Item (Join-Path $root "target/$rustTarget/release/fillr_core.dll") $publish
    Copy-Item (Join-Path $probeDir '*') $publish
    & (Join-Path $publish 'ffprobe.exe') -v error -version | Out-Null
    $zip = Join-Path $root "dist/FILLR-$rid-unsigned.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
    Write-Output "Built $zip"
} finally { Pop-Location }
