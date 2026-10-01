param([ValidateSet('x64','arm64')][string]$Architecture = 'x64', [switch]$Production)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rid = "win-$Architecture"
$version = (& python (Join-Path $root "script/version.py")).Trim()
if ($LASTEXITCODE -ne 0) { throw "Invalid FILLR version" }
$rustTarget = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$probeDir = Join-Path $root 'dist/ffprobe-windows'
if (-not (Test-Path (Join-Path $probeDir 'ffprobe.exe'))) { throw 'Build ffprobe with build_ffprobe_windows.sh in the matching MSYS2 shell first.' }
$expectedProbeHash = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
$sourceArchive = Join-Path $probeDir 'ffmpeg-9.0.2-source.tar.xz'
if (-not (Test-Path $sourceArchive) -or (Get-FileHash $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedProbeHash) {
    throw 'The FFmpeg source archive is missing or has the wrong checksum.'
}
$probeBytes = [IO.File]::ReadAllBytes((Join-Path $probeDir 'ffprobe.exe'))
$peOffset = [BitConverter]::ToInt32($probeBytes, 0x3c)
$machine = [BitConverter]::ToUInt16($probeBytes, $peOffset + 4)
$expectedMachine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
if ($machine -ne $expectedMachine) { throw "FFprobe architecture does not match $Architecture." }
function Assert-NativeSuccess([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE" }
}
Push-Location $root
try {
    rustup target add $rustTarget
    Assert-NativeSuccess 'Install Rust target'
    cargo test -p fillr-core
    Assert-NativeSuccess 'Rust tests'
    cargo build --release -p fillr-core -p fillr-update --target $rustTarget
    Assert-NativeSuccess 'Rust release build'
    $publish = Join-Path $root "dist/windows-$Architecture"
    if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
    $packageType = if ($Production) { "MSIX" } else { "None" }
    dotnet publish native/windows/FILLR.csproj -c Release -r $rid --self-contained true -p:WindowsPackageType=$packageType -p:Version=$version -p:AssemblyVersion="$version.0" -o $publish
    Assert-NativeSuccess 'Windows publish'
    if (-not (Test-Path (Join-Path $publish 'Assets/FILLR.ico'))) { throw 'Published Windows app is missing the FILLR icon.' }
    Copy-Item (Join-Path $root "target/$rustTarget/release/fillr_core.dll") $publish
    Copy-Item (Join-Path $root "target/$rustTarget/release/fillr-update.exe") $publish
    Copy-Item (Join-Path $probeDir '*') $publish
    Copy-Item (Join-Path $root 'LICENSE') $publish
    Copy-Item (Join-Path $root 'licenses/FFmpeg-NOTICE.txt') $publish
    $probeVersionOutput = & (Join-Path $publish 'ffprobe.exe') -version
    Assert-NativeSuccess 'Bundled ffprobe smoke test'
    if (-not $probeVersionOutput[0].StartsWith('ffprobe version 9.0.2 ')) { throw 'Bundled FFprobe version does not match the pinned source.' }
    if ((Get-FileHash (Join-Path $publish 'ffprobe.exe') -Algorithm SHA256).Hash -ne (Get-FileHash (Join-Path $probeDir 'ffprobe.exe') -Algorithm SHA256).Hash) {
        throw 'Packaged FFprobe differs from the FILLR build artifact.'
    }
    if ($Production) {
        & (Join-Path $PSScriptRoot 'package_windows_update.ps1') -Directory $publish -Architecture $Architecture -Version $version
        return
    }
    $zip = Join-Path $root "dist/FILLR-$rid-unsigned.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
    Write-Output "Built $zip"
} finally { Pop-Location }
