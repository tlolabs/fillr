param([Parameter(Mandatory)][string]$Directory,
      [ValidateSet('x64','arm64')][string]$Architecture,
      [Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$trust = Get-Content (Join-Path $root 'updates/trust.json') -Raw | ConvertFrom-Json
$publisher = $trust.identities.windows
if ($publisher -eq 'UNCONFIGURED' -or -not $trust.keys.PSObject.Properties.Count) { throw 'Configure production publisher and update public key first.' }
if (-not $env:WINDOWS_SIGNING_THUMBPRINT) { throw 'Set WINDOWS_SIGNING_THUMBPRINT to the existing trusted Authenticode identity.' }
$certificate = Get-Item "Cert:\CurrentUser\My\$env:WINDOWS_SIGNING_THUMBPRINT"
if ($certificate.Subject -ne $publisher) { throw 'Signing certificate does not match pinned publisher.' }
$kit = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory | Sort-Object Name -Descending | Where-Object { Test-Path (Join-Path $_.FullName 'x64/makeappx.exe') } | Select-Object -First 1
if (-not $kit) { throw 'Windows SDK packaging tools are missing.' }
$makeappx = Join-Path $kit.FullName 'x64/makeappx.exe'
$signtool = Join-Path $kit.FullName 'x64/signtool.exe'
function Checked([string]$Step) { if ($LASTEXITCODE -ne 0) { throw "$Step failed: $LASTEXITCODE" } }
# Sign every shipped PE that is not already validly publisher-signed (including the updater).
Get-ChildItem $Directory -Recurse -File | Where-Object { $_.Extension -in @('.exe','.dll') } | ForEach-Object {
    $signature = Get-AuthenticodeSignature $_.FullName
    if ($signature.Status -ne 'Valid') {
        & $signtool sign /sha1 $env:WINDOWS_SIGNING_THUMBPRINT /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 $_.FullName
        Checked 'Authenticode signing'
    }
    & $signtool verify /pa /all $_.FullName
    Checked 'Authenticode verification'
}
$assetDir = Join-Path $Directory 'Assets'
New-Item $assetDir -ItemType Directory -Force | Out-Null
Add-Type -AssemblyName System.Drawing
$sourceIcon = [Drawing.Image]::FromFile((Join-Path $root 'assets/icons/linux/hicolor/256x256/apps/edu.chabot.news.backgrounder.png'))
try {
    foreach ($spec in @(@('StoreLogo', 50), @('Square150', 150), @('Square44', 44))) {
        $bitmap = [Drawing.Bitmap]::new([int]$spec[1], [int]$spec[1])
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($sourceIcon, 0, 0, [int]$spec[1], [int]$spec[1])
            $bitmap.Save((Join-Path $assetDir ($spec[0]+'.png')), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $sourceIcon.Dispose() }
# Full-trust self-contained WinUI app; Windows owns side-by-side deployment and recovery.
$escapedPublisher = [Security.SecurityElement]::Escape($publisher)
@"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap rescap">
 <Identity Name="TLOLabs.FILLR" Publisher="$escapedPublisher" Version="$Version.0" ProcessorArchitecture="$Architecture" />
 <Properties><DisplayName>FILLR</DisplayName><PublisherDisplayName>TLO Labs</PublisherDisplayName><Logo>Assets\StoreLogo.png</Logo></Properties>
 <Resources><Resource Language="en-us" /></Resources>
 <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" /></Dependencies>
 <Applications><Application Id="FILLR" Executable="FILLR.exe" EntryPoint="Windows.FullTrustApplication"><uap:VisualElements DisplayName="FILLR" Description="FILLR" BackgroundColor="transparent" Square150x150Logo="Assets\Square150.png" Square44x44Logo="Assets\Square44.png" /></Application></Applications>
 <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"@ | Set-Content (Join-Path $Directory 'AppxManifest.xml') -Encoding utf8
$output = Join-Path $root "dist/FILLR-$Version-windows-$Architecture.msix"
& $makeappx pack /d $Directory /p $output /o
Checked 'MSIX packaging'
& $signtool sign /sha1 $env:WINDOWS_SIGNING_THUMBPRINT /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 $output
Checked 'MSIX signing'
& $signtool verify /pa /all $output
Checked 'MSIX signature verification'
$actualVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Directory 'FILLR.exe')).ProductVersion.Split('+')[0]
if ($actualVersion -ne $Version) { throw 'Packaged executable version mismatch.' }
$helperVersion = (& (Join-Path $Directory 'fillr-update.exe') --version).Trim()
if ($helperVersion -ne $Version) { throw 'Packaged updater version mismatch.' }
@{ schema=1; platform='windows'; architecture=$Architecture; version=$Version; filename=(Split-Path $output -Leaf); sha256=(Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant(); identity=$publisher; signature_verified=$true; installed_upgrade_verified=$false } | ConvertTo-Json | Set-Content "$output.verified.json"
Write-Output "Verified signed package: $output; installed upgrade qualification remains separate."
