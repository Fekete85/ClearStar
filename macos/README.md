# ClearStar – macOS (Apple Silicon)

Native SwiftUI app for Apple Silicon (macOS 26+), with the same 16-step guided workflow as the
Windows version. The AI steps run on Core ML; StarNet2 and Siril's offline catalogue are handled the same
way as in the Windows version. Distribution: a signed, notarized DMG from the project site (like Siril). Plans and
decisions: [`../docs/macos-port-analysis.md`](../docs/macos-port-analysis.md),
[`../docs/PORT-DECISIONS.md`](../docs/PORT-DECISIONS.md), status: [`../docs/PORT-CHECKLIST.md`](../docs/PORT-CHECKLIST.md).

## Build, run, test

Requires: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); for the
parity references, the .NET 10 SDK.

```
cd macos
xcodegen generate                                   # project.yml → ClearStar.xcodeproj (not version-controlled)
open ClearStar.xcodeproj                            # or:
xcodebuild -scheme ClearStar -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/ClearStarDD build
xcodebuild -scheme ClearStar -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/ClearStarDD test
```

On a network/synced (GDrive) volume the build folders fail with a "File exists" error when the index
is renamed, so they are placed on a local disk (`-derivedDataPath`, `swift test --scratch-path`).

When launched from the command line, a folder or image argument is loaded and stacked right away (as on Windows):
`open ClearStar.app --args ~/Astro/M31`.

### Test data and parity

The tests measure the Swift code against the Windows (C#) outputs (`testdata/reference/`, gitignored):

```
macos/tools/download-testdata.sh        # GraXpert ONNX models + Siril offline catalogue from the mirror (~2.8 GB)
macos/tools/make-references.sh          # C# references: synthetic + the existing real data sets (M31, M99, NGC6992_sub)
```

The real AI tests need the Core ML models in `testdata/coreml/` (`tools/convert-models/`, see
there). Tests that need real data run on every data set whose images and references are present
(`TestEnv.dataSets`); missing ones are skipped. Test against the live mirror:
`CLEARSTAR_LIVE_MIRROR=1 swift test --filter liveMirror`.

## Structure

```
project.yml                     XcodeGen: arm64, macOS 26+, hardened runtime, no sandbox; scheme with the package tests
ClearStar/                      SwiftUI app
  ClearStarApp.swift            windows (main, About, Settings), menus and keyboard shortcuts
  Views/                        MainView (sidebar, toolbar, status bar), InspectorView (step card, parameters,
                                model picker), ImageViewer (AppKit: zoom, pan, split view, selection),
                                FramesView (frame list, quality charts, histogram), Sheets, AboutAndSettings
Packages/ClearStarCore/         Swift package
  Sources/ClearStarCore/        port of windows/src/ClearStar.Core: Imaging, IO, Pipeline, Registration, Steps,
                                AI (Core ML, model store, StarNet2), Astrometry (WCS, HEALPix, catalogues, plate solve)
  Sources/ClearStarAppModel/    view models of the UI (port of the WPF MainViewModel), testable without UI
  Sources/CBZip2/               the system libbz2 (catalogue decompression)
  Tests/                        parity, unit and view-model tests
tools/                          download-testdata.sh, make-references.sh, convert-models/ (ONNX → Core ML)
packaging/make-dmg.sh           Release archive → signing → DMG → notarization
../shared/Languages/            hu.json, en.json – shared with the Windows version (Mac-specific strings: mac.*)
```

## Data locations

`~/Library/Application Support/ClearStar/`: `settings.json` (same keys as on Windows),
`ai-models/<kind>/<version>/model.mlpackage`, `catalogs/`, `Languages/`; the catalogue query
cache: `~/Library/Caches/ClearStar/`. The app reads Siril's settings (`~/Library/Application Support/org.siril.Siril`)
to discover StarNet2 and the offline catalogue.

## Release (DMG)

```
macos/packaging/make-dmg.sh             # → macos/packaging/out/ClearStar-<version>-arm64.dmg
```

The version comes from `windows/Directory.Build.props` (set by the Windows release script), the build number is
the commit count. Without a signing identity an ad-hoc signed DMG is built (runs only on this machine); for a release:

```
export CODESIGN_IDENTITY="Developer ID Application: <name> (<TEAM>)" DEVELOPMENT_TEAM=<TEAM>
xcrun notarytool store-credentials clearstar-notary --apple-id <apple id> --team-id <TEAM>   # once
NOTARY_PROFILE=clearstar-notary macos/packaging/make-dmg.sh
```

The script checks the hardened runtime, arm64 and the version, mounts and verifies the DMG, then
notarizes and staples it.
