# macOS-port – csak a szerző által megoldható tételek

Ezeket a port helyi stubbal vagy fixtúrával kerüli meg; a kiadás előtt a szerzőnek kell elvégeznie őket.

| # | Tétel | Mit kell tenni | Addig a port így halad |
|---|---|---|---|
| ~~B1~~ | ~~Core ML-modellek a tükrön~~ | **Megoldva 2026-09-25** (a szerző engedélyével): a 4 `coreml/<fajta>/<verzió>/model.mlpackage.zip` + `LICENSE.html` fent van a `https://csillag.blackit.hu/clearstar/` alatt, a `manifest.json` frissítve (a forrás: `12_Development/ClearStar-mirror`, `make-manifest.ps1` kiegészítve a `coreml` ággal), szerveren `sha256sum -c` rendben | Élő teszt: `CLEARSTAR_LIVE_MIRROR=1 … --filter liveMirror`; helyi stub továbbra is: `testdata/mirror/` |
| B2 | Developer ID-aláírás és notarizálás | Apple Developer Program-tagság; *Developer ID Application* tanúsítvány a kulcskarikában; `xcrun notarytool store-credentials clearstar-notary …`; majd `CODESIGN_IDENTITY=… DEVELOPMENT_TEAM=… NOTARY_PROFILE=clearstar-notary macos/packaging/make-dmg.sh` | Ad-hoc aláírt, hardened runtime-os Release-build és DMG (`make-dmg.sh` változók nélkül); a notarizálás lépése kihagyva, üzenettel |
| B3 | Valódi StarNet2 kipróbálása Macen | A macOS arm64-es StarNet2 CLI letöltése (starnetastro.com), egyszeri indítás Finderből, majd a 9. lépés futtatása; ha a kimenet csatornasorrendje eltérne a stubétól (BGR), a `StarNet.removeStars` cseréje | Stub-program (`Tests/…/Fixtures/starnet2-stub.py`) ugyanazzal a parancssorral, `--machine-progress`-szel, BGR-kimenettel; a felderítés (beállítás, Siril-config, Alkalmazások, PATH) tesztelve |
| B4 | Letöltés a weboldalról | A notarizált DMG feltöltése (pl. a tükörre vagy GitHub Release-be), és egy Mac-letöltés gomb a `site/`-on (`hugo.toml` params + `layouts/home.html`) | A DMG helyben készül: `macos/packaging/out/` |

## Megjegyzés (nem blokkoló)

- **Windows-hiba:** a „Nyomtatáshoz” mentett „16 bites” TIFF valójában 8 bites (az ImageSharp `TiffEncoder`
  `Bit48` beállítás ellenére 8 bitet ír – lásd D5). A Mac-változat valódi 16 bitet ír; a Windows-kód javítása
  külön döntés.
- A felhős tükör `manifest.json`-ja és a `ClearStar-mirror/README.md`, `make-manifest.ps1` a `coreml/` ággal
  frissült; a blackit-dokumentáció (`MBP_D/Claude/blackit/03-szolgaltatasok.md`) módosítása nincs commitolva
  abban a repóban.
- **Közös (Windows + Mac) viselkedés:** az NGC6992_sub készleten a 7. lépés (égbolt azonosítása) a háttérkivonás
  után sikerül, de az élesítés és a zajszűrés után nem („Could not identify the sky”) – a C# lánc ugyanígy áll meg
  (CLI, 2026-09-25). A teszt ezt a viselkedést rögzíti (`chainSolves: false`); javítása külön döntés.
