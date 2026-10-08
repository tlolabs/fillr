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
$previousRustFlags = $env:RUSTFLAGS
$env:RUSTFLAGS = (($previousRustFlags + ' -C target-feature=+crt-static').Trim())
Push-Location $root
try {
    rustup target add $rustTarget
    Assert-NativeSuccess 'Install Rust target'
    cargo test -p fillr-core --target $rustTarget
    Assert-NativeSuccess 'Rust tests'
    cargo build --release -p fillr-core -p fillr-update --target $rustTarget
    Assert-NativeSuccess 'Rust release build'
    $publish = Join-Path $root "dist/windows-$Architecture"
    if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
    New-Item $publish -ItemType Directory -Force | Out-Null
    $importLib = Join-Path $root "target/$rustTarget/release/fillr_core.dll.lib"
    if (-not (Test-Path $importLib)) { throw 'Rust import library is missing.' }
    $qtBuild = Join-Path $root "target/qt-windows-$Architecture"
    cmake -S (Join-Path $root 'native/qt') -B $qtBuild -A $(if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }) -DFILLR_CORE_LIBRARY=$importLib
    Assert-NativeSuccess 'Qt configure'
    cmake --build $qtBuild --config Release --parallel
    Assert-NativeSuccess 'Qt release build'
    Copy-Item (Join-Path $qtBuild 'Release/fillr_qt.exe') (Join-Path $publish 'FILLR.exe')
    windeployqt --release --no-translations (Join-Path $publish 'FILLR.exe')
    Assert-NativeSuccess 'Qt deployment'
    New-Item (Join-Path $publish 'Assets') -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $root 'assets/icons/FILLR.ico') (Join-Path $publish 'Assets/FILLR.ico')
    Copy-Item (Join-Path $root "target/$rustTarget/release/fillr_core.dll") $publish
    Copy-Item (Join-Path $root "target/$rustTarget/release/fillr-update.exe") $publish
    Copy-Item (Join-Path $probeDir '*') $publish
    python (Join-Path $root 'script/package_rust_licenses.py') --manifest (Join-Path $root 'Cargo.toml') --target $rustTarget --output (Join-Path $publish 'Rust-LICENSES.txt')
    Assert-NativeSuccess 'Rust dependency license notices'
    $qtLicenses = Join-Path $env:QT_ROOT_DIR 'LICENSES'
    if (Test-Path $qtLicenses) { Copy-Item $qtLicenses (Join-Path $publish 'Qt-LICENSES') -Recurse }
    $qtSbom = Join-Path $env:QT_ROOT_DIR 'sbom.spdx.json'
    if (Test-Path $qtSbom) { Copy-Item $qtSbom (Join-Path $publish 'Qt-SBOM.spdx.json') }
    Copy-Item (Join-Path $root 'LICENSE') $publish
    Copy-Item (Join-Path $root 'licenses/FFmpeg-NOTICE.txt') $publish
    Copy-Item (Join-Path $root 'licenses/Qt-NOTICE.txt') $publish
    Copy-Item (Join-Path $root 'licenses/Windows-SDK-LICENSE.txt') $publish
    $probeVersionOutput = & (Join-Path $publish 'ffprobe.exe') -version
    Assert-NativeSuccess 'Bundled ffprobe smoke test'
    if (-not $probeVersionOutput[0].StartsWith('ffprobe version 9.0.2 ')) { throw 'Bundled FFprobe version does not match the pinned source.' }
    if ((Get-FileHash (Join-Path $publish 'ffprobe.exe') -Algorithm SHA256).Hash -ne (Get-FileHash (Join-Path $probeDir 'ffprobe.exe') -Algorithm SHA256).Hash) {
        throw 'Packaged FFprobe differs from the FILLR build artifact.'
    }
    python (Join-Path $root 'script/verify_windows_runtime.py') $publish
    Assert-NativeSuccess 'Self-contained compiler runtime verification'
    if ($Production) {
        & (Join-Path $PSScriptRoot 'package_windows_update.ps1') -Directory $publish -Architecture $Architecture -Version $version
        return
    }
    $zip = Join-Path $root "dist/FILLR-$rid-unsigned.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
    Write-Output "Built $zip"
} finally { $env:RUSTFLAGS = $previousRustFlags; Pop-Location }
