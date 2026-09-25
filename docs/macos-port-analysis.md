# ClearStar macOS-port – elemzés és döntések

*Állapot: 2026-09-25. Cél: natív Apple Silicon alkalmazás Core ML-es AI-val, ingyenesen.*

## 1. Döntések (2026-09-25)

| # | Kérdés | Döntés |
|---|---|---|
| 0 | Port módja | teljes Swift-újraírás (mag + felület), a Windows-változat mellett párhuzamosan |
| 1 | Terjesztés | **csak aláírt, notarizált DMG a saját oldalról** (Developer ID), App Store nélkül – mint a Siril |
| 2 | StarNet2 | **mint Windowson**: a felhasználó saját StarNet2 CLI-je, automatikus felismeréssel, tallózással, beállító ablakkal |
| 3 | AI-modellek | **natív Core ML**: egyszeri ONNX → Core ML konverzió nálunk, a `.mlpackage` a saját tükörről; ORT csak végső tartalék arra a modellre, amelyik nem konvertálható |
| 4 | Minimális macOS | **macOS 26 Tahoe** (arm64) |
| 5 | Felület | **Mac-natív**: oldalsáv a lépésekkel, középen a kép, jobb oldali inspector a beállításokkal, eszköztár, menüsor és billentyűparancsok, rendszer világos/sötét mód, Liquid Glass |
| 6 | Gaia-katalógus | **mint Windowson**: a Siril már letöltött katalógusa, különben letöltés a tükörről a felhasználó döntésére, egyébként online lekérdezés |

Az ingyenesség és a DMG-terjesztés miatt a korábbi két akadály (App Store-os homokozó, GPL-3.0 és az App Store
feltételeinek ütközése) megszűnt.

## 2. Hogyan csinálja a Siril (a döntés alapja)

- A Siril Macen **aláírt és notarizált DMG**-ként érkezik a siril.org-ról, nem az App Store-ból, homokozó nélkül
  ([siril-macos-build](https://github.com/lock042/siril-macos-build), [letöltés](https://siril.org/download/)).
  A legújabb fejlesztői változat már csak Apple Siliconra készül (ChangeLog: *Drop support for Intel architecture on
  macOS*).
- A StarNet2-t a felhasználó telepíti; a Siril csak meghívja a CLI-t (a beállításokban megadott úton). A Siril 1.5-ben a
  régi C-interfészt egy Python-szkript váltotta, de a hívott program ugyanaz.
- A **StarNet2 2.6.2** (2026-09-19) macOS ARM64-es CLI-je **maga is Core ML-en fut**, önálló csomag, nem kell hozzá
  Python/Torch/ONNX ([StarNet CLI](https://starnetastro.com/cli-tools/)). A gépi olvasásra szánt folyamatjelzést
  (`--machine-progress`) is adja, amit a Windows-kód használ.
- A Siril beállításai macOS-en: `~/Library/Application Support/org.siril.Siril/` (a forrás `main.c`-je szerint);
  innen olvasható a StarNet útja (`starnet_exe=`) és az offline katalógus helye (`catalogue_gaia_astro=`).

## 3. A jelenlegi architektúra

| Réteg | Windows | Platformfüggés |
|---|---|---|
| Munkafolyamat | `Pipeline/Workflow`, `StepDefinition`, `StepParameters`, `SnapshotStore` | nincs |
| Képfeldolgozás | `Imaging/*` (AstroImage planar float32, statisztika, MTF, GHS, PSF, átméretezés) | nincs |
| Beolvasás/írás | `IO/FitsReader/Writer` (saját), `ImageFiles` (ImageSharp: TIFF/PNG/JPEG) | ImageSharp |
| Igazítás | `Registration/*` (csillagdetektor, háromszög-/szavazásos illesztés, bilineáris warp) | nincs |
| Asztrometria | `Astrometry/*` (TAN WCS, HEALPix, offline Siril-katalógus, Gaia TAP/VizieR, Sesame) | SharpZipLib (bzip2) |
| AI | `AI/*` (GraXpert ONNX-modellek, csempézés, StarNet2 CLI) | **DirectML**, `.exe`, `;`-es PATH |
| Beállítások | `UserSettings` (settings.json), `%LOCALAPPDATA%\ClearStar\…` | **Windows-utak** |
| Felület | WPF + CommunityToolkit.Mvvm; ImageViewer, HistogramView, QualityChart, beállító ablakok | **WPF** |

A felület a `StepDefinition` paraméterleírásaiból (`Slider`, `Toggle`, `Choice`, `Folder`, `Text`, `Hidden`,
`Model`) magától épít vezérlőket – a SwiftUI-inspector ugyanezt a mintát követi.

## 4. Modulonkénti leképezés (C# → Swift)

| C# | Swift / Apple-keretrendszer | Megjegyzés |
|---|---|---|
| AstroImage, ImageStats, DisplayStretch, Ghs, PsfMeasure, Resample | tiszta Swift + **Accelerate** (vDSP, vImage) | medián/MAD, konvolúció, átméretezés |
| FitsReader/Writer, Debayer, FrameSet | tiszta Swift (`Data`, big-endian olvasás) | 1:1 port |
| ImageFiles (ImageSharp) | **ImageIO** (`CGImageSource`/`CGImageDestination`) | 16 bites TIFF/PNG, JPEG |
| Registration/*, Astrometry (WCS, HEALPix, PlateSolver, ColorCalibration) | tiszta Swift (+ `simd`) | 1:1 port |
| HttpClient (TAP, VizieR, Sesame, tükör) | **URLSession** (async); SHA-256: **CryptoKit** | |
| SharpZipLib bzip2 | a rendszer **libbz2** (`-lbz2`) | az Apple Compression nem ismeri a bzip2-t |
| `System.IO.Compression` (modell-zip) | `/usr/bin/ditto -x -k` vagy saját zip-olvasó | homokozó nélkül a `ditto` hívható |
| ONNX Runtime + DirectML | **Core ML** (`MLModel`, `MLTensor`, batch-predikció) | 5. fejezet |
| StarNet (`Process`, `starnet2.exe`) | `Foundation.Process`, `starnet2` | PATH `:`-tal bontva; keresés: beállítás → Siril config → `/Applications`, `~/Applications` → PATH |
| UserSettings (settings.json) | `UserDefaults` | |
| `%LOCALAPPDATA%\ClearStar\{ai-models,catalogs,catalog-cache}` | `~/Library/Application Support/ClearStar/…`, `~/Library/Caches/ClearStar/…` | |
| Siril config (`%LOCALAPPDATA%\siril\config*.ini`) | `~/Library/Application Support/org.siril.Siril/config*.ini` | az utak már POSIX-alakúak, a `\\` visszafejtés nem kell |
| Temp (`SnapshotStore`, StarNet) | `FileManager.temporaryDirectory` | |
| L (nyelvek) | `Strings` + `DotNetFormat` (**kész**, tesztelve) | ugyanazok a JSON-ok |
| WPF + MVVM | **SwiftUI** + Observation (`@Observable`) | |
| ImageViewer (zoom/pan, előtte-utána, kijelölés) | SwiftUI + `NSView`/`CALayer`, később Metal | |
| HistogramView, QualityChart | SwiftUI `Canvas` vagy **Swift Charts** | |
| PreviewRenderer | vImage + `CGImage` | |
| Megnyitás/mentés, fogd és vidd | `NSOpenPanel`/`NSSavePanel`, `.dropDestination` | |
| AboutWindow, beállító ablakok | SwiftUI `Settings`/`Window` jelenet, `NSWorkspace` a linkekhez | |

## 5. AI: ONNX → Core ML

### Modellek és tenzorformák (a Windows-kódból kiolvasva)

| Modell | Bemenet | Kimenet | Csempézés, normálás |
|---|---|---|---|
| Háttér (BGE) | NHWC `1×256×256×3` | ugyanaz | nincs csempézés; 240²-re kicsinyítés + 8 px szél; `(x−medián)/MAD·0,04`, ±1 |
| Zajcsökkentés | NHWC `n×256×256×3` (batch 8) `gen_input_image` | ugyanaz | 256-os ablak, 128-as lépés; globális medián/MAD; küszöb ±1 (v1.0/1.1) vagy ±10 |
| Élesítés (csillag + objektum) | `ch×1×512×512` `gen_input_image` + `params` `[ch,2]` **vagy** `sigma` `[ch,1]` + `strenght` `[ch,1]` (v1.0.0) | maradék, `ch×1×512×512` | 512-es ablak, 448-as lépés; csempénként log-normálás |

### Konverzió

A coremltools a 6-os verzió óta nem konvertál közvetlenül ONNX-ből:

1. **ONNX → PyTorch**: `onnx2torch`.
2. **PyTorch → Core ML**: `torch.jit.trace` → `coremltools.convert(..., convert_to="mlprogram",
   compute_precision=FP16, minimum_deployment_target=macOS26)`; a batch a zajmodellnél 1…8, az élesítésnél 1…3
   (`EnumeratedShapes`).
3. **Numerikus ellenőrzés** ugyanazokon a csempéken ONNX Runtime (CPU) és Core ML között: max. abszolút eltérés
   < 1e-2 a normált térben, teljes képen PSNR > 45 dB. Ha az FP16 kevés (élesítés, log-normálás), FP32 GPU-n.
4. Szkript: `macos/tools/convert-models/` (python 3.12 venv); a `.mlpackage` nincs verziókezelve.

**Futtatás:** `computeUnits = .all` (Neural Engine + GPU + CPU); a Windows „GPU / CPU” kapcsolója itt
„Gyorsítás / csak CPU”. A csempézés és normálás (`AI/Tiling.cs`, `DenoiseModel.cs`, `DeconvolutionModel.cs`,
`BackgroundModel.cs`) 1:1 port; a `TilingGeometryMatchesGraXpert`, `PadIndexRepeatsEdgesLikeGraXpert`,
`NormalizedPsfFollowsModelVersion` tesztek Swift-megfelelője rögzíti a geometriát.

**Terjesztés:** a tükör `manifest.json`-ja új bejegyzéseket kap:
`coreml/<bge|denoise|deconvolution-object|deconvolution-stars>/<verzió>/model.mlpackage.zip` + `LICENSE.html`,
SHA-256-tal. Az app letölti, ellenőrzi, kibontja, `MLModel.compileModel(at:)`-tel lefordítja az Application
Supportba. A GraXpert által letöltött `.onnx` modellek Macen nem használhatók közvetlenül (ezért a GraXpert-mappa
felderítése kimarad).

**Licenc:** a konvertált modell a GraXpert-modell átdolgozása → **CC BY-NC-SA 4.0**, forrásmegjelöléssel és a
`LICENSE.html`-lel terjesztve; ingyenes appban az NC-feltétel teljesül. Udvariassági lépésként érdemes a
GraXpert-csapatnak jelezni a Core ML-változat közzétételét.

## 6. Terjesztés: aláírt, notarizált DMG

- **Apple Developer Program** tagság (99 USD/év) → *Developer ID Application* tanúsítvány.
- Release build: hardened runtime, **homokozó nélkül** (a StarNet2 indításához és a Siril beállításainak
  olvasásához); külön jogosultság (entitlement) várhatóan nem kell.
- `xcodebuild archive` → `-exportArchive` (Developer ID) → `notarytool submit --wait` → `stapler staple` →
  DMG (`create-dmg` vagy `hdiutil`), a DMG-t is aláírva és notarizálva. Egy `macos/packaging/make-dmg.sh` végzi,
  a Windows `packaging/release.ps1` mintájára (verzió a közös forrásból).
- Letöltés a clearstar.blackit.hu-ról (a site kap egy Mac-letöltés gombot). Frissítésjelzés később:
  a tükör `manifest.json`-jában verziószám, vagy Sparkle.
- **Jogi:** a GPL-3.0-s program saját oldalról terjesztve ugyanaz a helyzet, mint a Windows-kiadásoknál; a
  `THIRD-PARTY-NOTICES.md` kiegészül a macOS-es részekkel (Core ML-modellek, StarNet macOS-en).
  A Windows README „a ght.c portja” megfogalmazását érdemes a `THIRD-PARTY-NOTICES.md`-vel összhangba hozni.
- A `PRIVACY.md` kiegészül a macOS-es tárolási helyekkel.

## 7. Paritás és tesztelés

- A 60 C#-teszt (`windows/tests/ClearStar.Core.Tests`) modulonként kap Swift-megfelelőt (Swift Testing);
  a nyelvi fájlok kulcs- és helyőrző-egyezése már kész.
- **„Arany” kimenetek:** a `windows/tools/ClearStar.Cli` (`net10.0`) Macen is fut; a `testdata/` (M31, M99,
  NGC6992) mintáin lépésenként FITS-kimenetet ad, a Swift-magnak ezt tűréshatáron belül hoznia kell. Az AI-lépésekhez
  a CLI-nek Macen a CPU-s `Microsoft.ML.OnnxRuntime` kell (a DirectML-csomagban nincs macOS-es natív könyvtár).
- A StarNet-lépés Macen valódi StarNet2 2.6.x CLI-vel tesztelhető (mint a `StarNetRemovesSyntheticStarsIfInstalled`).
- Megjegyzés: a `Directory.Build.props` `PlatformTarget=x64` beállítása miatt Macen a .NET-teszteket
  `-p:PlatformTarget=AnyCPU`-val kell futtatni: `dotnet build windows/tests/ClearStar.Core.Tests
  -p:PlatformTarget=AnyCPU --no-incremental`, majd `dotnet test … --no-build`.

## 8. Ütemterv

Egy fejlesztőre, AI-támogatással, nagyságrendi becslés.

| Fázis | Tartalom | Becslés | Kész, ha |
|---|---|---|---|
| F0 | repó szétválasztása, macOS-váz, nyelvi réteg | **kész** | build + 5 Swift-teszt zöld |
| F1 | AstroImage, FITS, ImageIO, statisztika, MTF, GHS, Workflow + SnapshotStore | 1–2 hét | az 1., 10., 12–16. lépés az arany kimenetekkel egyezik |
| F2 | debayer, kalibrálás, csillagdetektor, illesztés, warp, stackelés, vágás | 2 hét | M31: a stack a C#-éval tűrésen belül egyezik |
| F3 | Core ML-konverzió + ellenőrzés, csempézés, 4–6. lépés, tükör-bejegyzések; StarNet (9. lépés) | 2 hét | PSNR-küszöb teljesül; StarNet-teszt zöld |
| F4 | plate solving (online + offline katalógus, Siril-katalógus felismerése), színkalibráció | 1–2 hét | az asztrometriai tesztek Swift-megfelelője zöld |
| F5 | Mac-natív felület: oldalsáv, képnéző, inspector, hisztogram, minőségi grafikon, élő előnézet, beállító ablakok, menük | 3–4 hét | a teljes lánc végigkattintható |
| F6 | Developer ID aláírás, notarizálás, DMG, site-letöltés, dokumentáció | 3–5 nap | notarizált DMG egy tiszta gépen elindul |

## 9. Kockázatok

| Kockázat | Hatás | Kezelés |
|---|---|---|
| Egy GraXpert-modell művelete nem konvertálható | közepes | ORT + CoreML EP tartalék arra a modellre |
| FP16 pontatlanság (élesítés) | közepes | FP32 GPU-n; a numerikus teszt dönt |
| StarNet2 CLI-felülete változik (2.6.x) | alacsony | a `--machine-progress` kimenet tesztje valódi CLI-vel; a hibaüzenet eljut a felhasználóhoz |
| Gatekeeper-figyelmeztetés, ha a notarizálás elmarad | közepes | a kiadási szkript nem enged notarizálatlan DMG-t |
| Két kódbázis párhuzamos karbantartása | folyamatos | közös nyelvi fájlok, arany kimenetek, közös tenzor-specifikáció |
