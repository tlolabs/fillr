param([ValidateSet('x64','arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rid = "win-$Architecture"
$rustTarget = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$probeDir = Join-Path $root 'dist/ffprobe-windows'
if (-not (Test-Path (Join-Path $probeDir 'ffprobe.exe'))) { throw 'Build ffprobe with build_ffprobe_windows.sh in the matching MSYS2 shell first.' }
function Assert-NativeSuccess([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE" }
}
Push-Location $root
try {
    rustup target add $rustTarget
    Assert-NativeSuccess 'Install Rust target'
    cargo test -p fillr-core
    Assert-NativeSuccess 'Rust tests'
    cargo build --release -p fillr-core --target $rustTarget
    Assert-NativeSuccess 'Rust release build'
    $publish = Join-Path $root "dist/windows-$Architecture"
    if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
    dotnet publish native/windows/FILLR.csproj -c Release -r $rid --self-contained true -o $publish
    Assert-NativeSuccess 'Windows publish'
    if (-not (Test-Path (Join-Path $publish 'Assets/FILLR.ico'))) { throw 'Published Windows app is missing the FILLR icon.' }
    Copy-Item (Join-Path $root "target/$rustTarget/release/fillr_core.dll") $publish
    Copy-Item (Join-Path $probeDir '*') $publish
    & (Join-Path $publish 'ffprobe.exe') -v error -version | Out-Null
    Assert-NativeSuccess 'Bundled ffprobe smoke test'
    $zip = Join-Path $root "dist/FILLR-$rid-unsigned.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
    Write-Output "Built $zip"
} finally { Pop-Location }
