# ClearStar macOS-port – elemzés

*Állapot: 2026-09-25. Cél: natív Apple Silicon alkalmazás a Mac App Store-ba, Core ML-es AI-val, ingyenesen.*

## 1. Összefoglaló

- **Ajánlás: teljes Swift-újraírás** (mag + felület). A Windows-változat magja (`windows/src/ClearStar.Core`,
  ~6000 sor) szinte teljesen saját, platformfüggetlen algoritmus (FITS, stackelés, igazítás, GHS, plate solving,
  színkalibráció), ezért jól portolható. A felület (~3000 sor WPF) úgyis újraírandó.
- **B-terv** (csak ha a Swift-port elakad): a .NET Core megtartása `osx-arm64`-re, ONNX Runtime + CoreML
  execution providerrel, Swift/SwiftUI felülettel. Ez nem natív Core ML, a .NET runtime beágyazása, a sandbox és
  az aláírás pedig macOS-en nehézkes. Nem javasolt.
- **Két valódi akadály** van: (1) a StarNet2 külső program nem futtatható App Store-os sandboxban, (2) a GPL-3.0
  és az App Store feltételei ütköznek. Mindkettőre van megoldás (6. és 7. fejezet).
- A repó már ketté van választva: `windows/` (változatlanul működik), `macos/` (lefordítható, sandboxolt váz),
  `shared/Languages` (közös nyelvi fájlok).

## 2. A jelenlegi architektúra

| Réteg | Windows | Platformfüggés |
|---|---|---|
| Munkafolyamat | `Pipeline/Workflow`, `StepDefinition`, `StepParameters`, `SnapshotStore` | nincs |
| Képfeldolgozás | `Imaging/*` (AstroImage planar float32, statisztika, MTF, GHS, PSF, átméretezés) | nincs |
| Beolvasás/írás | `IO/FitsReader/Writer` (saját), `ImageFiles` (ImageSharp: TIFF/PNG/JPEG) | ImageSharp |
| Igazítás | `Registration/*` (csillagdetektor, háromszög-/szavazásos illesztés, bilineáris warp) | nincs |
| Asztrometria | `Astrometry/*` (TAN WCS, HEALPix, offline Siril-katalógus, Gaia TAP/VizieR, Sesame) | SharpZipLib (bzip2) |
| AI | `AI/*` (GraXpert ONNX-modellek, csempézés, StarNet2 CLI) | **DirectML**, **külső exe** |
| Beállítások | `UserSettings` (settings.json), `%LOCALAPPDATA%\ClearStar\…` | **Windows-utak** |
| Felület | WPF + CommunityToolkit.Mvvm; ImageViewer, HistogramView, QualityChart, beállító ablakok | **WPF** |

A felület a `StepDefinition` paraméterleírásaiból (`Slider`, `Toggle`, `Choice`, `Folder`, `Text`, `Hidden`,
`Model`) magától épít vezérlőket – ezt a mintát a SwiftUI-változat is átveszi.

## 3. Modulonkénti leképezés (C# → Swift)

| C# | Swift / Apple-keretrendszer | Megjegyzés |
|---|---|---|
| AstroImage, ImageStats, DisplayStretch, Ghs, PsfMeasure, Resample | tiszta Swift + **Accelerate** (vDSP, vImage) | a medián/MAD, konvolúció, átméretezés vDSP/vImage-dzsel gyors |
| FitsReader/Writer, Debayer, FrameSet | tiszta Swift (`Data`, big-endian olvasás) | 1:1 port |
| ImageFiles (ImageSharp) | **ImageIO** (`CGImageSource`/`CGImageDestination`) | 16 bites TIFF/PNG, JPEG – rendszerszinten |
| Registration/*, Astrometry (WCS, HEALPix, PlateSolver, ColorCalibration) | tiszta Swift (+ `simd`) | 1:1 port |
| HttpClient (TAP, VizieR, Sesame, tükör) | **URLSession** (async) | letöltés folytatással, SHA-256: **CryptoKit** |
| SharpZipLib bzip2 | a rendszer **libbz2** (`-lbz2`, a macOS SDK része) | az Apple Compression keretrendszere nem ismeri a bzip2-t |
| `System.IO.Compression` (modell-zip importálás) | minimális saját zip-olvasó, vagy csak kész `.mlpackage` importja | sandboxban nincs `unzip` |
| ONNX Runtime + DirectML | **Core ML** (`MLModel`, `MLMultiArray`, batch-predikció) | lásd 4. fejezet |
| UserSettings (settings.json) | `UserDefaults` | + security-scoped bookmarkok a fájlutakhoz |
| `%LOCALAPPDATA%\ClearStar\{ai-models,catalogs,catalog-cache}` | `Application Support/ClearStar/…` és `Caches/ClearStar/…` (a sandbox-konténerben) | |
| Temp (`SnapshotStore`, StarNet) | `FileManager.temporaryDirectory` | sandboxban is működik |
| L (nyelvek) | `Strings` + `DotNetFormat` (**kész**, tesztelve) | ugyanazok a JSON-ok, .NET-helyőrzőkkel |
| WPF + MVVM | **SwiftUI** + Observation (`@Observable`) | macOS 14+ |
| ImageViewer (zoom/pan, előtte-utána, kijelölés) | SwiftUI + `NSView`/`CALayer`, később Metal | 9 MP-es előnézet CGImage-dzsel is elég gyors |
| HistogramView, QualityChart | SwiftUI `Canvas` vagy **Swift Charts** | |
| PreviewRenderer (lekicsinyítés, autostretch, BGRA8) | vImage + `CGImage` | |
| Megnyitás/mentés párbeszéd, fogd és vidd | `NSOpenPanel`/`NSSavePanel`, SwiftUI `.dropDestination` | a sandbox csak így ad fájlhozzáférést |
| AboutWindow, beállító ablakok | SwiftUI `Settings`/`Window` jelenet | |

## 4. AI: ONNX → Core ML

### Modellek és tenzorformák (a Windows-kódból kiolvasva)

| Modell | Bemenet | Kimenet | Csempézés, normálás |
|---|---|---|---|
| Háttér (BGE) | NHWC `1×256×256×3` | ugyanaz | nincs csempézés; 240²-re kicsinyítés + 8 px szél; `(x−medián)/MAD·0,04`, ±1 |
| Zajcsökkentés | NHWC `n×256×256×3` (batch 8) `gen_input_image` | ugyanaz | 256-os ablak, 128-as lépés; globális medián/MAD; küszöb ±1 (v1.0/1.1) vagy ±10 |
| Élesítés (csillag + objektum) | `ch×1×512×512` `gen_input_image` + `params` `[ch,2]` **vagy** `sigma` `[ch,1]` + `strenght` `[ch,1]` (v1.0.0) | maradék, `ch×1×512×512` | 512-es ablak, 448-as lépés; csempénként log-normálás |

### Konverziós út

A coremltools a 6-os verzió óta nem konvertál közvetlenül ONNX-ből, ezért:

1. **ONNX → PyTorch**: `onnx2torch`.
2. **PyTorch → Core ML**: `torch.jit.trace` → `coremltools.convert(..., convert_to="mlprogram",
   compute_precision=FP16, minimum_deployment_target=macOS14)`. Rögzített formák; a zajmodellnél a batch 1…8,
   az élesítésnél 1…3 `EnumeratedShapes`-szel.
3. **Numerikus ellenőrzés**: ugyanazokon a csempéken ONNX Runtime (CPU) és Core ML kimenete; elfogadás pl.
   max. abszolút eltérés < 1e-2 a normált térben, és a teljes kép PSNR-je > 45 dB. Ha az FP16 nem elég pontos
   (a log-normálás miatt az élesítésnél lehet gond), FP32 GPU-n.
4. Egy Python-szkript (`macos/tools/convert-models/`, python 3.12 venv) készíti el mind a négy modellt;
   a kész `.mlpackage` fájlok nincsenek verziókezelve.

**Futtatás:** `MLModelConfiguration.computeUnits = .all` (Neural Engine + GPU + CPU). A Windows „GPU / CPU”
kapcsolója itt „Gyorsítás / csak CPU” lesz. A csempézés, normálás és visszaállítás (`AI/Tiling.cs`,
`DenoiseModel.cs`, `DeconvolutionModel.cs`, `BackgroundModel.cs`) 1:1 portolandó; a meglévő C#-tesztek
(`TilingGeometryMatchesGraXpert`, `PadIndexRepeatsEdgesLikeGraXpert`, `NormalizedPsfFollowsModelVersion`)
Swift-megfelelője rögzíti a geometriát.

**Terjesztés:** a meglévő tükör (`https://csillag.blackit.hu/clearstar/manifest.json`, `path`/`size`/`sha256`)
új bejegyzéseket kap: `coreml/<bge|denoise|deconvolution-object|deconvolution-stars>/<verzió>/model.mlpackage.zip`
+ `LICENSE.html`. Az app letölti, SHA-256-tal ellenőrzi, kicsomagolja, és `MLModel.compileModel(at:)`-tel
lefordítja az Application Supportba. A modell adat, nem futtatható kód, így az App Store szabályaival összefér.

**Tartalék:** ha egy művelet nem konvertálható, az adott modell ONNX Runtime + CoreML EP-vel fut (az ORT Swift
csomagja App Store-kompatibilis).

**Licenc:** a konvertált modell a GraXpert-modell átdolgozása → továbbra is **CC BY-NC-SA 4.0**,
forrásmegjelöléssel és a `LICENSE.html`-lel együtt terjesztendő. Ingyenes, reklámmentes appban az NC-feltétel
teljesül; a legtisztább, ha a GraXpert-csapattól írásos jóváhagyást kérünk a Core ML-változat terjesztésére.

## 5. Hálózat és adatok

- Végpontok: CDS Sesame, VizieR (I/355), ESA Gaia TAP, saját tükör, Zenodo (katalógus-tartalék) – a
  `com.apple.security.network.client` jogosultság elég; mind HTTPS, ATS-kivétel nem kell.
- Offline Gaia-katalógus: 1,14 GB tömörítve / 1,52 GB kibontva, az Application Supportba letöltve,
  SHA-256-tal ellenőrizve. A letöltés közben mutatott méret és a lemezhely-ellenőrzés fontos (App Review
  szereti, ha a nagy letöltés a felhasználó döntése – ez most is így van).
- Az App Store adatvédelmi címkéje: „Nem gyűjt adatot” (a `PRIVACY.md` szerint semmi nem megy a
  szerzőhöz); a `PrivacyInfo.xcprivacy` már a vázban van.

## 6. Sandbox és App Store – mit kell átgondolni

| Windows-viselkedés | Probléma macOS App Store-ban | Megoldás |
|---|---|---|
| **StarNet2 CLI** meghívása (`AI/StarNet.cs`) | sandboxolt app nem indíthat a felhasználó által választott külső programot; a StarNet licence tiltja a beépítést | **v1: a 9. lépés macOS-en „nem elérhető”** (átugorható, a 10–11. lépés leválasztás nélkül is működik). Később: engedély kérése a StarNet szerzőjétől egy Core ML-változatra, vagy nyílt csillageltávolító modell. Opcionálisan egy App Store-on kívüli (Developer ID-val aláírt, notarizált) kiadás megtarthatja a külső StarNet-et. |
| GraXpert modellmappájának automatikus felderítése | más app mappája a sandboxból nem olvasható | a tükörről letöltött Core ML-modellek; kézi import `NSOpenPanel`-lel |
| Siril `config.ini` olvasása (StarNet-út, katalógus-út) | ugyanaz | a felhasználó választja ki a katalógusfájlt; security-scoped bookmark |
| Fájlutak a `settings.json`-ban | sandboxban újraindítás után nem nyithatók meg | security-scoped bookmarkok |
| Mentés a Képek mappába alapból | nincs rá jogosultság | `NSSavePanel` |
| `Process.Start(url)`, `explorer.exe` | – | `NSWorkspace.shared.open`, `activateFileViewerSelecting` |

Egyéb követelmények: arm64-only build (engedélyezett), macOS 14+, hardened runtime, App Store Connect-fiók
és csapatazonosító, képernyőképek, adatvédelmi URL (a gyökérbeli `PRIVACY.md` a GitHubon már elérhető, de
a macOS-es tárolási helyekkel ki kell egészíteni).

## 7. Jogi kérdések

1. **GPL-3.0 és App Store.** Az FSF szerint az App Store felhasználási feltételei a GPL-lel összeférhetetlen
   további korlátozások (2011-ben emiatt került le a VLC). **Megoldás:** a ClearStar-kód szerzői joga a szerzőé,
   ezért a `LICENSE` kiegészíthető egy GPLv3 7. § szerinti **kiegészítő engedéllyel**, ami megengedi az App
   Store-on keresztüli terjesztést. Ez a saját kódra működik; külső közreműködők kódjára csak az ő
   hozzájárulásukkal.
2. **Siril és GraXpert eredetű részek.** A `THIRD-PARTY-NOTICES.md` szerint nincs bemásolt kód, de a Windows
   README a GHS-t „a ght.c portjaként” írja le, és a GraXpert-modellek elő-/utófeldolgozása „szorosan követi az
   eredetit”. Ha ezek valójában fordítások, akkor a Siril/GraXpert szerzőinek GPL-je rájuk is vonatkozik, és a
   kiegészítő engedélyt a mi nevünkben nem adhatjuk meg rájuk. **Ajánlás:** a Swift-változatban ezeket a
   részeket a publikált leírásokból (GHS: Cranfield–Payne, ghsastro.co.uk; a modellek tenzor-specifikációja: ez a
   dokumentum, 4. fejezet) írjuk meg, nem a C#-kód soronkénti fordításával – vagy kérjünk engedélyt a két
   csapattól. A README szóhasználatát érdemes pontosítani.
3. **GraXpert-modellek (CC BY-NC-SA 4.0):** ingyenes app → rendben; a modelleket nem építjük be, a tükörről
   töltődnek le; a konvertált változat is CC BY-NC-SA (lásd 4. fejezet).
4. **StarNet2:** nem építhető be, nem terjeszthető → 6. fejezet.

## 8. Paritás és tesztelés

- A 60 C#-teszt (`windows/tests/ClearStar.Core.Tests`) modulonként kap Swift-megfelelőt (Swift Testing).
  Az első kettő (nyelvi kulcsok egyezése, helyőrzők) már kész.
- **„Arany” kimenetek:** a `windows/tools/ClearStar.Cli` `net10.0`-s, Macen is fut. A `testdata/` (M31, M99,
  NGC6992) mintáin lépésenként FITS-kimenetet készít; a Swift-mag ugyanezekkel a beállításokkal tűréshatáron
  belül ugyanazt kell adja. Az AI-lépésekhez a CLI-nek Macen a CPU-s `Microsoft.ML.OnnxRuntime` csomag kell
  (a DirectML-csomagban nincs macOS-es natív könyvtár).
- Megjegyzés: a `Directory.Build.props` `PlatformTarget=x64` beállítása miatt Macen a teszteket
  `-p:PlatformTarget=AnyCPU`-val kell futtatni (x64-es .NET nincs telepítve):
  `dotnet build windows/tests/ClearStar.Core.Tests -p:PlatformTarget=AnyCPU --no-incremental` után
  `dotnet test … --no-build`.

## 9. Ütemterv

A becslések egy fejlesztőre, AI-támogatással, nagyságrendi pontossággal értendők.

| Fázis | Tartalom | Becslés | Kész, ha |
|---|---|---|---|
| F0 | repó szétválasztása, macOS-váz, nyelvi réteg | **kész** | build + 5 Swift-teszt zöld |
| F1 | AstroImage, FITS, ImageIO, statisztika, MTF, GHS, Workflow + SnapshotStore | 1–2 hét | az 1., 10., 12–16. lépés parancssorból az arany kimenetekkel egyezik |
| F2 | debayer, kalibrálás, csillagdetektor, illesztés, warp, stackelés, vágás | 2 hét | M31: a stack a C#-éval tűrésen belül egyezik |
| F3 | Core ML-konverzió + ellenőrzés, csempézés, 4–6. lépés, tükör-bejegyzések | 2 hét | PSNR-küszöb teljesül; 9 MP-en mért idők |
| F4 | plate solving (online + offline katalógus), színkalibráció | 1–2 hét | az asztrometriai tesztek Swift-megfelelője zöld |
| F5 | SwiftUI-felület: lépéskártyák, paraméter-UI, képnéző, hisztogram, minőségi grafikon, élő előnézet, beállítás-ablakok | 3–4 hét | a teljes lánc végigkattintható |
| F6 | App Store: aláírás, képernyőképek, adatvédelmi címke, TestFlight, beküldés | 1 hét | jóváhagyott build |

## 10. Kockázatok

| Kockázat | Hatás | Kezelés |
|---|---|---|
| Egy GraXpert-modell művelete nem konvertálható Core ML-re | közepes | ORT + CoreML EP tartalék az adott modellre |
| FP16 pontatlanság (élesítés log-normálás) | közepes | FP32 GPU-n; numerikus teszt dönti el |
| Nincs csillagleválasztás Macen | közepes (felhasználói élmény) | v1-ben átugorható lépés; később saját vagy engedélyezett modell |
| GPL/App Store vita, Siril/GraXpert-eredetű részek | magas, ha bekövetkezik | kiegészítő engedély + tiszta újraírás specifikációból, engedélykérés |
| App Review: nagy letöltések, „nem működik első indításra” | alacsony–közepes | a modell- és katalógusletöltés egyértelmű felhasználói döntés; AI nélkül is végigmegy a lánc |
| Két kódbázis párhuzamos karbantartása | folyamatos | közös nyelvi fájlok, arany kimenetek, közös tenzor-specifikáció |
