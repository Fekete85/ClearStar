<#
.SYNOPSIS
  Builds the ClearStar MSIX package for the Microsoft Store (or a self-signed one for local testing).

.DESCRIPTION
  1. dotnet publish (single-file, self-contained x64) into packaging\out\publish
  2. staging folder: ClearStar.exe + Store icons (generated from the app icon) + AppxManifest.xml
  3. makeappx pack  → packaging\out\ClearStar_<version>_x64.msix
  4. optionally (-Sign) a self-signed certificate so the package can be installed locally for a test.

  For the Store submission run it without parameters (the Store identity is the default) and upload the
  .msix under Packages; the Store signs it itself (do NOT sign a Store upload):
    .\make-msix.ps1

  For a local test build:
    .\make-msix.ps1 -Sign
  then trust the certificate once (admin PowerShell, printed at the end) and double-click the .msix.

.PARAMETER Version
  Four-part package version; default: <Version> from Directory.Build.props + ".0".
#>
# Store identity of ClearStar (Partner Center → Product identity, Store ID 9N193WDH7KF). A -Sign (local test)
# build uses a separate dev identity so it never collides with the Store-installed app.
param(
    [string]$IdentityName = "LaszloFekete.ClearStar",
    [string]$Publisher = "CN=EA8412CF-9BD5-4574-9413-B9FC60B2BABF",
    [string]$PublisherDisplayName = "Laszlo Fekete",
    [string]$Version = "",
    [switch]$Sign,
    [switch]$SkipPublish
)
$ErrorActionPreference = "Stop"
if ($Sign -and -not $PSBoundParameters.ContainsKey("IdentityName")) { $IdentityName = "ClearStar.Dev"; $Publisher = "CN=ClearStar Dev"; $PublisherDisplayName = "ClearStar" }
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot "out"
$publishDir = Join-Path $out "publish"
$staging = Join-Path $out "staging"

# --- tools (Windows SDK) ---
$kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
$sdkVer = Get-ChildItem $kits -Directory | Where-Object { Test-Path (Join-Path $_.FullName "x64\makeappx.exe") } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVer) { throw "Windows SDK signing tools not found under $kits (install the 'Windows SDK Signing Tools for Desktop Apps' feature)." }
$makeappx = Join-Path $sdkVer.FullName "x64\makeappx.exe"
$signtool = Join-Path $sdkVer.FullName "x64\signtool.exe"
Write-Host "Windows SDK: $($sdkVer.Name)"

# --- version ---
if (-not $Version) {
    $props = [xml](Get-Content (Join-Path $root "Directory.Build.props"))
    $v = $props.Project.PropertyGroup.Version
    if (-not $v) { $v = "0.1.0" }
    $Version = "$v.0"
}
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Version must have four parts (a.b.c.d): $Version" }

# --- 1. publish ---
if (-not $SkipPublish) {
    Write-Host "Publishing…"
    & dotnet publish (Join-Path $root "src\ClearStar.App") -c Release -o $publishDir -nologo -v q
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
}
if (-not (Test-Path (Join-Path $publishDir "ClearStar.exe"))) { throw "ClearStar.exe not found in $publishDir" }

# --- 2. staging ---
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $staging "Assets") | Out-Null
Copy-Item (Join-Path $publishDir "ClearStar.exe") $staging
if (Test-Path (Join-Path $publishDir "Languages")) { Copy-Item (Join-Path $publishDir "Languages") $staging -Recurse }

# Store icons from the app icon (square, transparent background, centred with a small margin).
Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Image]::FromFile((Join-Path $root "src\ClearStar.App\Assets\clearstar_icon.png"))
function Save-Logo([string]$name, [int]$w, [int]$h, [double]$fill = 1.0) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $side = [int]([Math]::Min($w, $h) * $fill)
    $g.DrawImage($icon, [int](($w - $side) / 2), [int](($h - $side) / 2), $side, $side)
    $g.Dispose()
    $bmp.Save((Join-Path $staging "Assets\$name"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
Save-Logo "Square44x44Logo.png" 44 44
Save-Logo "Square44x44Logo.targetsize-44_altform-unplated.png" 44 44
Save-Logo "Square44x44Logo.scale-200.png" 88 88
Save-Logo "Square150x150Logo.png" 150 150 0.8
Save-Logo "Square150x150Logo.scale-200.png" 300 300 0.8
Save-Logo "Wide310x150Logo.png" 310 150 0.8
Save-Logo "Wide310x150Logo.scale-200.png" 620 300 0.8
Save-Logo "LargeTile.png" 310 310 0.8
Save-Logo "SmallTile.png" 71 71 0.8
Save-Logo "StoreLogo.png" 50 50
Save-Logo "StoreLogo.scale-200.png" 100 100
$icon.Dispose()

# Manifest with the identity filled in.
$manifest = Get-Content (Join-Path $PSScriptRoot "AppxManifest.xml") -Raw -Encoding UTF8
$manifest = $manifest.Replace("__IDENTITY_NAME__", $IdentityName).Replace("__PUBLISHER__", $Publisher).Replace("__PUBLISHER_DISPLAY__", $PublisherDisplayName).Replace("__VERSION__", $Version)
[IO.File]::WriteAllText((Join-Path $staging "AppxManifest.xml"), $manifest, (New-Object Text.UTF8Encoding $false))

# --- 3. pack ---
$msix = Join-Path $out "ClearStar_${Version}_x64.msix"
if (Test-Path $msix) { Remove-Item $msix -Force }
& $makeappx pack /d $staging /p $msix /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed" }
Write-Host "Package: $msix ($([Math]::Round((Get-Item $msix).Length / 1MB)) MB)"

# --- 4. optional self-signing for a local install ---
if ($Sign) {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Publisher -and $_.FriendlyName -eq "ClearStar dev signing" } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "Creating a self-signed certificate for $Publisher…"
        $cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature -FriendlyName "ClearStar dev signing" `
            -CertStoreLocation Cert:\CurrentUser\My -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") -NotAfter (Get-Date).AddYears(3)
    }
    $cerPath = Join-Path $out "ClearStar-dev.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $msix
    if ($LASTEXITCODE -ne 0) { throw "signtool failed" }
    Write-Host ""
    Write-Host "Signed with a self-signed certificate. To install the package on this PC, trust the certificate once (admin PowerShell):"
    Write-Host "  Import-Certificate -FilePath `"$cerPath`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    Write-Host "then double-click the .msix. Never upload a self-signed package to the Store – build it without -Sign for that."
}
