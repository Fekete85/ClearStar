# macOS-port – checklist

A haladás egyetlen forrása. Ág: `macos-port`. Minden sor mérhető; kipipálni csak ellenőrzés (teszt, build, parancs)
után szabad. Kontextustömörítés után innen kell folytatni. Döntések: `PORT-DECISIONS.md`, csak a szerző által
megoldható tételek: `PORT-BLOCKERS.md`.

**Paritás** = a Swift-kód kimenete a Windows-változat (C#) ugyanarra a bemenetre adott kimenetével egyezik. A
referenciákat a `windows/tools/ClearStar.Cli` `reference` parancsa állítja elő (`macos/tools/make-references.sh`):
`testdata/reference/synthetic/` (generált bemenetek) és `testdata/reference/m31/` (a valódi M31-képekből); mindkettő
gitignore-olt (D4). A modelleket és az offline katalógust a `macos/tools/download-testdata.sh` tölti le.

## F0 – Előkészítés
- [x] `docs/PORT-CHECKLIST.md`, `PORT-DECISIONS.md`, `PORT-BLOCKERS.md` létrehozva
- [x] C# referencia-generátor: `clearstar-cli reference <kimenet>` szintetikus + valódi (M31) referenciákkal
- [x] A C#-mag Macen ONNX Runtime CPU-val fut (az AI-referenciákhoz), a Windows-build változatlan
- [x] A Swift-csomag optimalizálva fordul a tesztekhez is (a paritástesztek percek alatt lefutnak)

## F1 – Alapok: kép, IO, statisztika, nyújtás, munkafolyamat
- [x] `AstroImage` (planar Float, kisbetű-érzéketlen fejléc, Clone, Clamp01, Luminance, Downsample, DownsampleFactor)
- [x] `ImageStats` (Compute ritkított mintavétellel, ComputeAll, Median) – paritás
- [x] `DisplayStretch` (Mtf, Params.Apply/Invert, Compute, ComputeAll presetekkel és linked módban) – paritás
- [x] `Resample` (Resize kicsinyítés + nagyítás, GaussianBlur) – paritás
- [x] `FitsReader` (BITPIX 8/16/32/−32/−64, BZERO/BSCALE, normálás, fejléc) és `FitsWriter` – a C# által írt FITS bitre azonosan olvasva, oda-vissza teszt
- [x] `ImageFiles` (TIFF/PNG/JPEG 16 bites olvasás; JPEG/TIFF16/PNG16/FITS írás; EffectiveBayerPattern) – ImageIO-val
- [x] `Debayer` (bilineáris, 4 minta, FlipRows) – paritás
- [x] `FrameSet` (Scan, Inspect, típus fejlécből/névből, almappák) és `ObjectNameGuess` – paritás a `testdata/M31`-en
- [x] `GhsParams` + `GhsTransform` (GHS, invGHS, asinh, invasinh, linear, MTF, Simple; 3 színmodell; JSON-lista) – paritás görbéken és képen
- [x] `Histogram`
- [x] `StepParameters`, `ParameterDefinition`, `StepDefinition`, `StepBase`-gyárak (feliratok a nyelvi fájlból)
- [x] `SnapshotStore` (memória-LRU + lemezre írás) és `Workflow` (Run, Skip, Reopen, Reset, Stale, ImageBefore/After) – a C#-tesztek Swift-megfelelői
- [x] `UserSettings` (settings.json az Application Supportban)
- [x] Lépések: LoadFrames, Crop (Orient, OrientRightAngle, OrientedSize, Crop), `Coverage` – paritás
- [x] Lépések: StarlessStretch (Commit, Undo, CommitAuto, RegionMedian, CurrentAll), StarStretch (AddStars, FullStrengthStars) – paritás
- [x] Lépések: GreenRemoval, Fringe, Contrast, Saturation (Preview + Run), Save (3 formátum) – paritás
- [x] F1 commit

## F2 – Stackelés és igazítás
- [x] `StarDetector` – paritás (szintetikus és valódi képen)
- [x] `StarMatcher` (VoteTranslation, Refine, TriangleMatch, Pair, Fit) és `SimilarityTransform` – paritás
- [x] `ImageWarp` – paritás
- [x] `BackgroundExtractionStep.Flatten` (polinom, visszautasítás) – paritás
- [x] `StackStep` (kalibrálás, gradiens, igazítás, framing=max, szigma-vágás, minőségjegyek, FrameNote-ok) – paritás a teljes M31-stacken (63 kép)
- [x] M31-stack optimalizált buildben ≤ 60 s (mérve: 50 s; C# Release: 52 s)
- [x] F2 commit

## F3 – AI (Core ML) és StarNet2
- [x] `macos/tools/convert-models/` (requirements, convert.py): mind a 4 GraXpert-modell `.mlpackage`-dzsé alakítva
- [x] Konverzió numerikus ellenőrzése ONNX Runtime-mal (mind a 4 modell a tűréshatáron belül)
- [x] `Tiling` (PadIndex, Pad, Unpad, geometria) – paritás
- [x] `BackgroundModel`, `DenoiseModel`, `DeconvolutionModel` Core ML-lel – paritás a C# ONNX-kimenetével valódi képrészleten
- [x] `PsfMeasure` – paritás
- [x] `AiModelStore` (lista, választás, import `.mlpackage`/zip, tükör-manifest `coreml/…`, letöltés SHA-256-tal, fordítás) – helyi tükör-fixtúrával tesztelve
- [x] Neural Engine/GPU kapcsoló (`ai.gpu` beállítás → computeUnits)
- [x] Lépések: BackgroundExtraction (AI + polinom), Deconvolution, Denoise
- [x] `StarNet` (keresés: beállítás, Siril-config macOS-en, /Applications, ~/Applications, PATH; futtatás `--machine-progress`-szel; BGR-csere; lineáris oda-vissza) – stub-programmal tesztelve
- [x] `StarLayerStore`, StarRemoval lépés
- [x] F3 commit

## F4 – Asztrometria és színkalibráció
- [x] `Wcs` (Project, Deproject, SkyToPixel, PixelToSky, FITS-írás/-olvasás, formázás) – paritás
- [x] `Healpix` (NESTED pixelközéppontok, QueryDiscInclusive) – paritás
- [x] `LocalGaiaCatalog` (fejléc-ellenőrzés, index, Cone, BpRpFromTeff, jelöltek: beállítás, Siril macOS-config, Siril-mappa, ClearStar-mappa) – szintetikus katalógusfájllal, paritás
- [x] Online katalógusok (VizieR TSV, Gaia TAP CSV, Sesame) – elemzők paritása, lemezes gyorsítótár
- [x] `CatalogDownloader` (bzip2 kicsomagolás libbz2-vel, SHA-256, tükörsorrend) – helyi fixtúrával
- [x] `PlateSolver` – paritás szintetikus mezőn és a valódi M31-en (a C# által mentett katalógusrészlettel)
- [x] `ColorCalibration` (Measure, Fit, Apply) – paritás
- [x] Lépések: PlateSolve, ColorCalibration
- [x] Teljes 16 lépéses lánc Swiftben a `testdata/M31`-en (AI-val, StarNet-stubbal) hibátlanul lefut (4,5 perc; élesítés 94 s, zaj 112 s 7,4 MP-en, GPU FP32)
- [x] F4 commit

## F5 – Mac-natív felület
- [ ] Ablak: `NavigationSplitView` – oldalsáv (csoportok, lépésállapotok, haladásjelző), középen a kép, jobbra inspector
- [ ] Inspector: paraméter-UI a definíciókból (csúszka tick-feliratokkal / értékformátummal, kapcsoló, választó, mappa/fájl, szöveg, modellválasztó), haladó beállítások, Alkalmaz / Kihagy / Alaphelyzet, megjegyzés + művelet, másodlagos művelet
- [ ] Képnéző: nagyítás/mozgatás, illesztés, előtte–utána osztott nézet, „eredeti” nyomva tartva, kijelölés fogantyúkkal (vágás), pipetta (GHS), méretcímke
- [ ] Élő előnézet: GHS (+ hisztogram-panel), csillagok visszahelyezése, zöld/szegély/kontraszt/telítettség, vágás-orientáció
- [ ] Képlista-nézet: betöltött képek kártyái, minőségi grafikonok (4 mérőszám), stack-bélyegkép, egyedi kép előnézete lapozással
- [ ] Eszköztár (osztott nézet, előnézet-erősítés + preset-menü, névjegy), állapotsor (üzenet, haladás, megszakítás, képinfó)
- [ ] Üdvözlő lap, fogd és vidd (mappa / fájl), Megnyitás… menü
- [ ] Menüsor és billentyűparancsok (Megnyitás ⌘O, Alkalmaz ⌘↩, Kihagyás, előző/következő lépés, nagyítás ⌘+ ⌘− ⌘0, osztott nézet, erősítés)
- [ ] Beállítások ablak (nyelv, Neural Engine/GPU), Névjegy (verzió, licenc, felhasznált munkák, modell-licencek, támogatás)
- [ ] StarNet-beállító és katalógus-beállító lap (letöltés folyamatjelzővel, megszakítással)
- [ ] Liquid Glass (eszköztár, lebegő vezérlők), világos és sötét mód
- [ ] Nézetmodell-tesztek (lépésválasztás, alkalmazás, kihagyás, elavulás, élő előnézet) az Xcode tesztcélban
- [ ] Az app elindul, a teljes lánc a felületen végigkattintható (képernyőképpel ellenőrizve)
- [ ] F5 commit

## F6 – Csomagolás és terjesztés
- [ ] Release konfiguráció: hardened runtime, arm64, macOS 26, verzió a közös forrásból
- [ ] `macos/packaging/make-dmg.sh`: archív → aláírás (Developer ID, ha van; különben ad-hoc) → ellenőrzés → DMG → notarizálás, ha van hozzá profil
- [ ] Hardened runtime-os, ad-hoc aláírt Release build lefordul, `codesign` szerint `runtime` jelzővel
- [ ] A DMG-szkript hiba nélkül lefut, a DMG csatolható, benne az app és az Applications-hivatkozás
- [ ] Dokumentáció: `macos/README.md`, `PRIVACY.md` (macOS-helyek), `THIRD-PARTY-NOTICES.md` (Core ML-modellek, macOS)
- [ ] `xcodebuild test` 0 hibával (egység-, paritás- és nézetmodell-tesztek)
- [ ] F6 commit
