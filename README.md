# ClearStar

Vezetett asztrofotó-feldolgozó Windows-alkalmazás kezdőknek: a nyers képektől a kész képig 17 lépésben,
minden lépésnél közérthető magyarázattal és 2–4 egyszerű beállítással.

## Futtatás

```
dotnet build
dotnet run --project src/ClearStar.App              # üres indulás
dotnet run --project src/ClearStar.App -- <mappa>   # azonnal betölt és összeilleszt
dotnet test                                          # Core tesztek
```

Támogatott bemenet: FITS (8/16/32 bit egész, 32/64 bit lebegő; mono, RGB és Bayer-mintás OSC nyers – `BAYERPAT` alapján debayerezve), TIFF, PNG, JPEG.
Valódi tesztadat: Seestar S50 Pro, 63×30 s M31 (`testdata/M31`, gitignore-olva) – a teljes lánc ~30 s alatt fut le rajta.
A mappában a `IMAGETYP` fejléc vagy a fájlnév/almappa (`light`, `dark`, `flat`, `bias`) alapján válogatjuk szét a képeket.

## Felépítés

```
src/ClearStar.Core      – UI-független feldolgozó mag
  Imaging/    AstroImage (planar float32), ImageStats (medián/MAD), DisplayStretch (autostretch MTF)
  IO/         FitsReader/FitsWriter, ImageFiles (TIFF/PNG/JPEG), FrameSet (mappa szétválogatása)
  Pipeline/   StepDefinition (17 lépés + paraméterleírások), Workflow (lépések futtatása,
              lépésenkénti pillanatképek, "Frissítés szükséges" jelölés), SnapshotStore (memória+lemez)
  Registration/ StarDetector (küszöb + komponensek + súlyozott középpont), StarMatcher (eltolás-szavazás,
              iteratív legközelebbi szomszéd, zárt alakú hasonlósági illesztés), ImageWarp (bilineáris)
  Steps/      egy osztály lépésenként; a StepCatalog adja a sorrendet
src/ClearStar.App       – WPF felület (MVVM, CommunityToolkit.Mvvm)
  Themes/     sötét Fluent-jellegű téma, ikonok, a lépéskártya és a beállítás-típusok sablonjai
  ViewModels/ MainViewModel (workflow + előnézet), StepViewModel, Parameter*ViewModel
  Controls/   ImageViewer (zoom/pan, előtte-utána osztott nézet)
tests/ClearStar.Core.Tests
design/                 – a Claude Design canvas forrásai (build.js generálja az artboardokat)
reference/              – Siril és GraXpert forrás (GPL-3.0, csak tanulmányozásra; gitignore-olva)
```

Egy új lépés = egy `StepBase` leszármazott: a `Definition` adja a nevet, magyarázatot és a
paramétereket (ezekből a felület magától épít csúszkát/kapcsolót/választót), a `RunAsync` a képet.
A felületet nem kell hozzá módosítani.

## Lépések állapota

| # | Lépés | Állapot |
|---|---|---|
| 1 | Képek betöltése | kész |
| 2 | Összeillesztés | kalibrálás, Bayer-debayer, képenkénti gradiens-kivonás (mint Siril `seqsubsky 1`), csillag szerinti igazítás, háttér-normálás (`norm=add`), teljes látómező (`framing=max`), szigma-vágott átlag |
| 3 | Vágás | kész (arányos szélvágás) |
| 4 | Háttér kiegyenlítése | GraXpert AI-modell (ONNX Runtime, DirectML GPU / CPU) vagy polinom-modell; modellválasztó tallózással/URL-letöltéssel |
| 5 | Élesítés | GraXpert deconvolution-modellek: előbb csillagok, aztán objektum (512-es csempék, log-normálás, FWHM automatikus mérése); DirectML-lel a videokártyán (~11 s a két menet 9 MP-en), CPU-tartalékkal (~140 s) |
| 6 | Zajcsökkentés | GraXpert denoise-modell (256-os csempék, 128-as lépés, medián/MAD-normálás, fényes pixelek megtartása, erősség szerinti keverés); GPU-n ~20 s 9 MP-en |
| 7–9 | Plate solving, színkalibrálás, csillagleválasztás | helyőrző (a képet változatlanul adja tovább) |
| 10 | Ködök kiemelése (GHS) | kész – a D-t a háttér célfényességéhez keresi meg |
| 11 | Csillagok nyújtása | MTF; csillagleválasztás nélkül a teljes képre (nyújtott képet nem nyújt újra) |
| 12 | Csillagok visszahelyezése | helyőrző |
| 13 | Zöld eltávolítása (SCNR) | kész |
| 14 | Színes szegélyek | helyőrző |
| 15–16 | Kontraszt, telítettség | kész |
| 17 | Mentés | JPEG / TIFF 16 bit / FITS |

## Licenc és jogi tudnivalók

A ClearStar **GPL-3.0-or-later** licencű (`LICENSE`). Saját implementáció, de a Siril és a GraXpert
(mindkettő GPL-3.0) forráskódjából tanultunk, ezért a projekt is GPL. A felhasznált munkák, a GraXpert
AI-modellek **CC BY-NC-SA 4.0** (csak nem kereskedelmi) licence és a közreműködők névsora a
`THIRD-PARTY-NOTICES.md`-ben van, és a programban a Névjegy ablak (a jobb felső „?” gomb) is megmutatja.
A szerző nevét a `Directory.Build.props` `Authors`/`Copyright` mezőiben kell megadni – onnan kerül a Névjegybe.

## Nyelvek

Minden felirat a nyelvi adatbázisból jön: `src/ClearStar.Core/Languages/hu.json` és `en.json` (beépítve).
Új nyelv: másold le az `en.json`-t `xx.json` néven (a `_meta.name` a nyelv neve), fordítsd le, és tedd a
program melletti `Languages` mappába vagy ide: `%LOCALAPPDATA%ClearStaranguages`. az azonos kódú fájl
felülírja a beépítettet; a hiányzó kulcsok angolul jelennek meg. a nyelv a névjegy ablakban választható
(`settings.json` → `language`), alapból a windows nyelve, ha van hozzá fájl, különben magyar.
a csúszkafeliratok tömbök, a `{0}` helyőrzők .net formátumúak (`{1:0.0}`).

## Parancssori futtató

`tools/ClearStar.Cli`: a teljes láncot UI nélkül futtatja (`clearstar-cli <mappa> <kimeneti mappa>`), és
`clearstar-cli bench <kép>` méri az egyes műveletek idejét egy képen.

## Smart App Control

Ha az exe vagy a tesztek `FileLoadException (0x800711C7)`-tel állnak le, a Windows Smart App Control
blokkolja az aláíratlan, frissen fordított DLL-eket. Fejlesztéshez ki kell kapcsolni:
Beállítások → Windows-biztonság → Alkalmazás- és böngészővezérlés → Smart App Control → Ki.

## AI-modellek

A 4. lépés (és később a zajcsökkentés, élesítés) a GraXpert nyílt ONNX-modelljeit használja. A GraXpert
privát tárolóból tölti őket, ezért a ClearStar közvetlenül nem tud letölteni; a GraXpert által már letöltött
modelleket automatikusan megtalálja (`%LOCALAPPDATA%\GraXpert\GraXpert\…`), ezen kívül `model.onnx`/zip
betallózható vagy URL-ről letölthető (`%LOCALAPPDATA%\ClearStar\ai-models`). A választás a
`%LOCALAPPDATA%\ClearStar\settings.json`-ban marad meg. A workflow az „AbdurAstro Method for Processing in
Siril 1.4” leírást követi.
