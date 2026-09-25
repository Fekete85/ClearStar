# ClearStar – macOS (Apple Silicon)

Natív SwiftUI-alkalmazás Apple Siliconra (macOS 26+), ugyanazzal a 16 lépéses vezetett folyamattal, mint a
Windows-változat. Az AI-lépések Core ML-en futnak, a StarNet2-t és a Siril offline katalógusát a Windows-
változathoz hasonlóan kezeli. Terjesztés: aláírt, notarizált DMG a saját oldalról (mint a Siril). Tervek és
döntések: [`../docs/macos-port-analysis.md`](../docs/macos-port-analysis.md),
[`../docs/PORT-DECISIONS.md`](../docs/PORT-DECISIONS.md), állapot: [`../docs/PORT-CHECKLIST.md`](../docs/PORT-CHECKLIST.md).

## Fordítás, futtatás, tesztek

Kell hozzá: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); a
paritás-referenciákhoz .NET 10 SDK.

```
cd macos
xcodegen generate                                   # project.yml → ClearStar.xcodeproj (nincs verziókezelve)
open ClearStar.xcodeproj                            # vagy:
xcodebuild -scheme ClearStar -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/ClearStarDD build
xcodebuild -scheme ClearStar -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/ClearStarDD test
```

A build-mappák a hálózati/szinkronizált (GDrive) köteten „File exists” hibával elszállnak az index
átnevezésekor, ezért kerülnek helyi lemezre (`-derivedDataPath`, `swift test --scratch-path`).

Parancssori indításnál egy mappa vagy kép argumentum azonnal betölt és összeilleszt (mint Windowson):
`open ClearStar.app --args ~/Astro/M31`.

### Tesztadatok és paritás

A tesztek a Windows (C#) kimenetekhez mérik a Swift-kódot (`testdata/reference/`, gitignore-olt):

```
macos/tools/download-testdata.sh        # GraXpert ONNX-modellek + Siril offline katalógus a tükörről (~2,8 GB)
macos/tools/make-references.sh          # C# referenciák: szintetikus + a meglévő valódi készletek (M31, M99, NGC6992_sub)
```

A Core ML-modellek a `testdata/coreml/`-ban kellenek a valódi AI-tesztekhez (`tools/convert-models/`, lásd
ott). A valódi adatokat igénylő tesztek minden olyan készletre lefutnak, amelynek képei és referenciái megvannak
(`TestEnv.dataSets`); a hiányzók kimaradnak. Az éles tükör tesztje:
`CLEARSTAR_LIVE_MIRROR=1 swift test --filter liveMirror`.

## Felépítés

```
project.yml                     XcodeGen: arm64, macOS 26+, hardened runtime, homokozó nélkül; séma a csomag tesztjeivel
ClearStar/                      SwiftUI app
  ClearStarApp.swift            ablakok (fő, Névjegy, Beállítások), menük és billentyűparancsok
  Views/                        MainView (oldalsáv, eszköztár, állapotsor), InspectorView (lépéskártya, paraméterek,
                                modellválasztó), ImageViewer (AppKit: nagyítás, mozgatás, osztott nézet, kijelölés),
                                FramesView (képlista, minőségi grafikonok, hisztogram), Sheets, AboutAndSettings
Packages/ClearStarCore/         Swift csomag
  Sources/ClearStarCore/        a windows/src/ClearStar.Core portja: Imaging, IO, Pipeline, Registration, Steps,
                                AI (Core ML, modelltár, StarNet2), Astrometry (WCS, HEALPix, katalógusok, plate solve)
  Sources/ClearStarAppModel/    a felület nézetmodelljei (a WPF MainViewModel portja), UI nélkül tesztelhető
  Sources/CBZip2/               a rendszer libbz2-je (katalógus-kicsomagolás)
  Tests/                        paritás-, egység- és nézetmodell-tesztek
tools/                          download-testdata.sh, make-references.sh, convert-models/ (ONNX → Core ML)
packaging/make-dmg.sh           Release archív → aláírás → DMG → notarizálás
../shared/Languages/            hu.json, en.json – közös a Windows-változattal (Mac-specifikus szövegek: mac.*)
```

## Adatok helye

`~/Library/Application Support/ClearStar/`: `settings.json` (ugyanazok a kulcsok, mint Windowson),
`ai-models/<fajta>/<verzió>/model.mlpackage`, `catalogs/`, `Languages/`; a katalógus-lekérdezések
gyorsítótára: `~/Library/Caches/ClearStar/`. A Siril beállításait (`~/Library/Application Support/org.siril.Siril`)
a StarNet2 és az offline katalógus felderítéséhez olvassa.

## Kiadás (DMG)

```
macos/packaging/make-dmg.sh             # → macos/packaging/out/ClearStar-<verzió>-arm64.dmg
```

A verzió a `windows/Directory.Build.props`-ból jön (a Windows-kiadószkript állítja), a build-szám a
commitok száma. Aláírás nélkül ad-hoc aláírt (csak ezen a gépen futtatható) DMG készül; kiadáshoz:

```
export CODESIGN_IDENTITY="Developer ID Application: <név> (<TEAM>)" DEVELOPMENT_TEAM=<TEAM>
xcrun notarytool store-credentials clearstar-notary --apple-id <apple id> --team-id <TEAM>   # egyszer
NOTARY_PROFILE=clearstar-notary macos/packaging/make-dmg.sh
```

A szkript ellenőrzi a hardened runtime-ot, az arm64-et, a verziót, a DMG-t felcsatolja és ellenőrzi, majd
notarizál és „staple”-öl.
