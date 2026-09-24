# ClearStar

Vezetett asztrofotó-feldolgozó Windows-alkalmazás kezdőknek: a nyers képektől a kész képig 16 lépésben,
minden lépésnél közérthető magyarázattal és 2–4 egyszerű beállítással.

## Futtatás

```
dotnet build
dotnet run --project src/ClearStar.App              # üres indulás
dotnet run --project src/ClearStar.App -- <mappa>   # azonnal betölt és összeilleszt
dotnet test                                          # Core tesztek
dotnet publish src/ClearStar.App -c Release -o publish   # egyetlen önálló ClearStar.exe (x64, .NET beépítve)
```

A publish egyetlen fájl: a .NET és a program a `ClearStar.exe`-ben van, a natív könyvtárak (WPF, ONNX Runtime,
DirectML) az első indításkor a `%TEMP%\.net\ClearStar\` gyorsítótárba csomagolódnak ki. Az exe mellé csak egy
opcionális `Languages` mappa kerülhet.

Támogatott bemenet: FITS (8/16/32 bit egész, 32/64 bit lebegő; mono, RGB és Bayer-mintás OSC nyers – `BAYERPAT` alapján debayerezve), TIFF, PNG, JPEG.
Valódi tesztadat: Seestar S50 Pro, 63×30 s M31 (`testdata/M31`, gitignore-olva) – a teljes lánc ~30 s alatt fut le rajta.
A mappában a `IMAGETYP` fejléc vagy a fájlnév/almappa (`light`, `dark`, `flat`, `bias`) alapján válogatjuk szét a képeket.

## Felépítés

```
src/ClearStar.Core      – UI-független feldolgozó mag
  Imaging/    AstroImage (planar float32), ImageStats (medián/MAD), DisplayStretch (autostretch MTF)
  IO/         FitsReader/FitsWriter, ImageFiles (TIFF/PNG/JPEG), FrameSet (mappa szétválogatása)
  Pipeline/   StepDefinition (16 lépés + paraméterleírások), Workflow (lépések futtatása,
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
| 3 | Vágás | kijelölés fogantyúkkal, szélcsúszka, negyedfordulatok + finom szög (−45…+45°, bilineáris), tükrözés – mind élő előnézettel (WPF TransformedBitmap), a lefedett téglalap az elforgatott képen újraszámolva |
| 4 | Háttér kiegyenlítése | GraXpert AI-modell (ONNX Runtime, DirectML GPU / CPU) vagy polinom-modell; modellválasztó, letöltés a tükörről, tallózás, URL |
| 5 | Élesítés | GraXpert deconvolution-modellek: előbb csillagok, aztán objektum (512-es csempék, log-normálás, FWHM automatikus mérése); DirectML-lel a videokártyán (~11 s a két menet 9 MP-en), CPU-tartalékkal (~140 s) |
| 6 | Zajcsökkentés | GraXpert denoise-modell (256-os csempék, 128-as lépés, medián/MAD-normálás, fényes pixelek megtartása, erősség szerinti keverés); GPU-n ~20 s 9 MP-en |
| 7 | Égbolt azonosítása | „közeli” plate solving: a fejléc RA/DEC (vagy objektumnév → CDS Sesame) körül Gaia DR3 csillagok – **offline** a Siril HEALPix-katalógusból (`siril_cat_healpix8_astro.dat`, saját olvasó, ~0,5 s), különben ESA archívum TAP, tartalék VizieR, lemezes gyorsítótár, háromszög-illesztés tükrözéssel is, TAN WCS legkisebb négyzetes illesztéssel; az eredmény a FITS-fejlécbe kerül (~2 s) |
| 8 | Színek kalibrálása | fotometriai (SPCC-jellegű): a WCS alapján a Gaia-csillagok apertúra-fotometriája R/G/B-ben, robusztus egyenes-illesztés a BP−RP színindexre, a napszerű (vagy Vega-) fehér referenciánál a vörös/kék szorzó; háttér semlegesítése (~1 s) |
| 9 | Csillagok leválasztása | a felhasználó saját StarNet2 CLI-jét hívja (Siril-beállításból, telepítési helyről vagy tallózva; beállító ablak letöltési útmutatóval); lineáris képen automatikus MTF-előnyújtás → StarNet2 → pontos visszanyújtás; a csillagréteg (eredeti − csillagtalan) a StarLayerStore-ban |
| 10 | Ködök kiemelése (GHS) | kezdőknek három csúszka: objektum fényessége (MTF a háttér fölötti tartományon), háttér szintje (feketepont-eltolás), kontraszt a kettő között (GHS a háttérre centrálva, a háttér helyben marad); haladó beállítás alatt a Siril GHS-dialógus vezérlői (ln(D+1), b, SP, LP, HP, típus, BP, színmodell – a ght.c portja), élő előnézet + hisztogram jelölőkkel, „Alkalmaz” = rögzítés a nyújtás-történetbe és tiszta lap (több lépcsős nyújtás), visszavonás; varázspálca = az „Előnézet felerősítése” aktuális beállítása rögzítve (csatornánkénti, kapcsolatlan MTF, árnyék = medián − k·MAD – ugyanaz, mint a GraXpert autostretch-e; az előnézettel azonos, lekicsinyített képen mérve); pipetta az SP-hez |
| 11 | Csillagok visszahelyezése | a 10. lépés a csillagréteget „teljes erővel” is elkészíti (az eredeti kép ugyanazzal a nyújtás-történettel nyújtva, mínusz a csillagtalan); a csúszka ezt a réteget adja hozzá additívan, a maximumon minden csillag pontosan úgy tér vissza, mintha nem lett volna leválasztás, lejjebb a réteg 1/érték hatványra emelve (előbb a halvány csillagok és az udvarok tűnnek el); élő előnézet; leválasztás nélkül a teljes kép enyhe MTF-nyújtása |
| 12 | Zöld eltávolítása (SCNR) | kész, élő előnézet |
| 13 | Színes szegélyek | lila/ibolya szegélyek semlegesítése a fényes csillagok körül (színezet-ablak ibolya–magenta, telítettség- és fényességküszöb, a fényesség megtartásával – a Siril unpurple ötlete alapján); haladó: küszöb, színtartomány szélessége; élő előnézet |
| 14–15 | Kontraszt, telítettség | kész, élő előnézet |
| 16 | Mentés | JPEG / TIFF 16 bit / FITS |

## Licenc és jogi tudnivalók

A ClearStar **GPL-3.0-or-later** licencű (`LICENSE`). Saját implementáció, de a Siril és a GraXpert
(mindkettő GPL-3.0) forráskódjából tanultunk, ezért a projekt is GPL. A felhasznált munkák, a GraXpert
AI-modellek **CC BY-NC-SA 4.0** (csak nem kereskedelmi) licence és a közreműködők névsora a
`THIRD-PARTY-NOTICES.md`-ben van, és a programban a Névjegy ablak (a jobb felső „?” gomb) is megmutatja.
A szerző nevét a `Directory.Build.props` `Authors`/`Copyright` mezőiben kell megadni – onnan kerül a Névjegybe.

## Nyelvek

Minden felirat a nyelvi adatbázisból jön: `src/ClearStar.Core/Languages/hu.json` és `en.json` (beépítve).
Új nyelv: másold le az `en.json`-t `xx.json` néven (a `_meta.name` a nyelv neve), fordítsd le, és tedd a
program melletti `Languages` mappába vagy ide: `%LOCALAPPDATA%\ClearStar\Languages`. Az azonos kódú fájl
felülírja a beépítettet; a hiányzó kulcsok angolul jelennek meg. A nyelv a Névjegy ablakban választható
(`settings.json` → `language`), alapból a Windows nyelve, ha van hozzá fájl, különben magyar.
A csúszkafeliratok tömbök, a `{0}` helyőrzők .NET formátumúak (`{1:0.0}`).

## Parancssori futtató

`tools/ClearStar.Cli`: a teljes láncot UI nélkül futtatja (`clearstar-cli <mappa> <kimeneti mappa>`), és
`clearstar-cli bench <kép>` méri az egyes műveletek idejét egy képen.

## Smart App Control

Ha az exe vagy a tesztek `FileLoadException (0x800711C7)`-tel állnak le, a Windows Smart App Control
blokkolja az aláíratlan, frissen fordított DLL-eket. Fejlesztéshez ki kell kapcsolni:
Beállítások → Windows-biztonság → Alkalmazás- és böngészővezérlés → Smart App Control → Ki.

## AI-modellek

A 4. lépés (és később a zajcsökkentés, élesítés) a GraXpert nyílt ONNX-modelljeit használja. A GraXpert
privát tárolóból tölti őket, ezért a ClearStar a saját letöltési tükréről
(`https://csillag.blackit.hu/clearstar/`, `AppLinks.Mirror`) szedi le a legfrissebbet: a tükör
`manifest.json`-ja adja a verziót, a méretet és az SHA-256-ot, amit a letöltés után ellenőrzünk. A tükör
az offline csillagkatalógust is kiszolgálja (a Zenodo csak tartalék). A GraXpert által már letöltött
modelleket automatikusan megtalálja (`%LOCALAPPDATA%\GraXpert\GraXpert\…`), ezen kívül `model.onnx`/zip
betallózható vagy URL-ről letölthető (`%LOCALAPPDATA%\ClearStar\ai-models`). A választás a
`%LOCALAPPDATA%\ClearStar\settings.json`-ban marad meg. A workflow az „AbdurAstro Method for Processing in
Siril 1.4” leírást követi.

## Microsoft Store csomag (MSIX)

`packaging/make-msix.ps1` egyfájlos publish-ből MSIX-et készít (Windows SDK `makeappx` kell hozzá – a
„Windows SDK Signing Tools for Desktop Apps” komponens). Az ikonokat a `clearstar_icon.png`-ből generálja,
a manifest (`packaging/AppxManifest.xml`) helyőrzőit a Partner Center *Product identity* értékeivel tölti ki:

```
.\packaging\make-msix.ps1 -IdentityName "<Package/Identity/Name>" -Publisher "<CN=…>" -PublisherDisplayName "<név>"
```

A kész `packaging/out/ClearStar_<verzió>_x64.msix` aláíratlanul megy a Store-ba (a Store írja alá).
Helyi próbához `-Sign` önaláírt tanúsítványt készít; a kiírt `Import-Certificate` parancs után a
csomag dupla kattintással telepíthető. `PRIVACY.md` a Store által kért adatvédelmi tájékoztató.
