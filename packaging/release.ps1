<#
.SYNOPSIS
  Prepares a ClearStar release for the Microsoft Store: version, tests, commit, MSIX, publish folder.

.DESCRIPTION
  1. checks that the working tree is clean and on main
  2. sets <Version> in Directory.Build.props (a.b.c; the package version becomes a.b.c.0)
  3. runs the tests - a failing test stops the release
  4. commits "Version a.b.c"
  5. builds the Store MSIX (make-msix.ps1) and refreshes the repository's publish\ folder
  6. writes packaging\out\release-<version>.txt with the "What's new" texts to paste
  7. with -Push, pushes main to GitHub (the Store listing links PRIVACY.md there)

  The upload itself stays manual: the Store submission API needs a Microsoft Entra tenant, which
  a personal Microsoft account cannot create without a billing account. The script ends with the
  Partner Center steps.

.EXAMPLE
  .\release.ps1 -Version 0.1.2 -NotesHu "Gyorsabb zajcsokkentes." -NotesEn "Faster denoising." -Push
#>
param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$NotesHu,
    [Parameter(Mandatory)] [string]$NotesEn,
    [switch]$Push
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$storeId = "9N193WDH7KF"

function Invoke-Git { & git -C $root @args; if ($LASTEXITCODE -ne 0) { throw "git $args failed" } }

# --- 1. preconditions ---
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must have three parts (a.b.c): $Version" }
if ((Invoke-Git rev-parse --abbrev-ref HEAD) -ne "main") { throw "Not on main." }
if (Invoke-Git status --porcelain) { throw "The working tree has uncommitted changes; commit or stash them first." }

# --- 2. version ---
$propsPath = Join-Path $root "Directory.Build.props"
$props = [IO.File]::ReadAllText($propsPath)
$current = [regex]::Match($props, '<Version>([^<]+)</Version>').Groups[1].Value
if ([version]$Version -lt [version]$current) { throw "Version $Version is lower than the current $current." }
if ($Version -ne $current) {
    [IO.File]::WriteAllText($propsPath, $props.Replace("<Version>$current</Version>", "<Version>$Version</Version>"), (New-Object Text.UTF8Encoding $false))
    Write-Host "Version: $current -> $Version"
}

# --- 3. tests ---
Write-Host "Running tests..."
& dotnet test (Join-Path $root "tests\ClearStar.Core.Tests") -nologo -v q
if ($LASTEXITCODE -ne 0) {
    Invoke-Git checkout -- Directory.Build.props
    throw "Tests failed; the version change was reverted."
}

# --- 4. commit ---
if ($Version -ne $current) {
    Invoke-Git commit -q -m "Version $Version" -- Directory.Build.props
    Write-Host "Committed: Version $Version"
}

# --- 5. package + publish folder ---
& (Join-Path $PSScriptRoot "make-msix.ps1")
$msix = Join-Path $PSScriptRoot "out\ClearStar_$Version.0_x64.msix"
if (-not (Test-Path $msix)) { throw "Package not found: $msix" }
$publish = Join-Path $root "publish"
New-Item -ItemType Directory -Force $publish | Out-Null
Copy-Item (Join-Path $PSScriptRoot "out\publish\*") $publish -Recurse -Force

# --- 6. release notes ---
$notesPath = Join-Path $PSScriptRoot "out\release-$Version.txt"
$notes = @"
ClearStar $Version - Partner Center, What's new in this version

[hu]
$NotesHu

[en]
$NotesEn
"@
[IO.File]::WriteAllText($notesPath, $notes, (New-Object Text.UTF8Encoding $true))

# --- 7. push ---
if ($Push) {
    Invoke-Git push origin main
    Write-Host "Pushed main to GitHub."
}

Write-Host ""
Write-Host "Ready: $msix"
Write-Host "Notes: $notesPath"
Write-Host ""
Write-Host "Partner Center (https://partner.microsoft.com/dashboard/products/$storeId/overview):"
Write-Host "  1. Update  (starts a new submission)"
Write-Host "  2. Packages: upload the .msix above, remove the previous package"
Write-Host "  3. Store listings (hu, en): paste the 'What's new' text from the notes file;"
Write-Host "     if packaging\store-listing.md changed since the last release, update the description too"
Write-Host "  4. Submit to the Store"
if (-not $Push) { Write-Host "  (Push to GitHub first if PRIVACY.md changed - the listing links it there: .\release.ps1 ... -Push)" }
