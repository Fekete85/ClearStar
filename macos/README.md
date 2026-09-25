# ClearStar – macOS (Apple Silicon)

Natív SwiftUI-alkalmazás Apple Siliconra (macOS 26+); az AI-modellek Core ML-en futnak majd. Terjesztés: aláírt,
notarizált DMG a saját oldalról, mint a Siril. A port tervét és
állapotát a [`../docs/macos-port-analysis.md`](../docs/macos-port-analysis.md) írja le. Jelenleg **váz**:
a 16 lépés listája a közös nyelvi fájlokból, feldolgozás még nincs.

## Futtatás

Kell hozzá: Xcode 26+ és [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```
cd macos
xcodegen generate                        # project.yml → ClearStar.xcodeproj (nincs verziókezelve)
open ClearStar.xcodeproj                 # vagy parancssorból:
xcodebuild -scheme ClearStar -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/Library/Developer/ClearStarDD build
swift test --package-path Packages/ClearStarCore --scratch-path ~/Library/Developer/ClearStarCoreBuild
```

A build-mappák a hálózati/szinkronizált (GDrive) köteten „File exists” hibával elszállnak az index
átnevezésekor, ezért kerülnek helyi lemezre (`-derivedDataPath`, `--scratch-path`).

## Felépítés

```
project.yml                 XcodeGen-leírás: arm64, macOS 26+, hardened runtime, homokozó nélkül
ClearStar/                  SwiftUI app (ClearStarApp, ContentView), ikon
Packages/ClearStarCore/     UI-független mag, a windows/src/ClearStar.Core Swift megfelelője
  Localization/  Strings (a Windows L osztálya), DotNetFormat ({0}, {1:0.0}, {0:P1} … helyőrzők)
  Pipeline/      StepId, StepGroup
../shared/Languages/        hu.json, en.json – ugyanazok, mint a Windows-változatban; a bundle
                            Resources/Languages mappájába kerülnek
```

A Core további mappái (Imaging, IO, Registration, Astrometry, AI, Steps) a portolás ütemében jönnek létre,
a Windows-oldali szerkezetet követve.

## Aláírás és terjesztés

Helyben ad-hoc aláírással fordul (`CODE_SIGN_IDENTITY: "-"`). Kiadáshoz *Developer ID Application* tanúsítvány,
notarizálás és DMG kell – a lépéseket a [`../docs/macos-port-analysis.md`](../docs/macos-port-analysis.md) 6. fejezete
írja le. Homokozó nincs, hogy a felhasználó StarNet2 CLI-je és a Siril beállításai (offline katalógus) elérhetők
legyenek.
