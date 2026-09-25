# macOS-port – döntések

A rögzített alapdöntéseket (`macos-port-analysis.md`, 1. fejezet) nem ismétli. Itt a port közben hozott, nem
egyértelmű kérdések vannak; az irányelv: ami kétséges, az a Windows-változattal egyezzen.

| # | Kérdés | Döntés | Indok |
|---|---|---|---|
| D1 | Beállítások tárolása | `settings.json` (lapos kulcs–érték) az `~/Library/Application Support/ClearStar/` mappában, ugyanazokkal a kulcsokkal, mint Windowson | Windows-egyező; a UserDefaults helyett, amit az elemzés javasolt |
| D2 | GHS és a GraXpert-feldolgozás portolása | 1:1 port a C#-ból | A DMG-terjesztés miatt a GPL-kérdés megszűnt, a paritás így ellenőrizhető |
| D3 | AI-referenciák Macen | A C#-mag nem Windows alatt a CPU-s `Microsoft.ML.OnnxRuntime` csomagot használja (feltételes csomaghivatkozás) | A DirectML-csomagban nincs macOS-es natív könyvtár; a Windows-build nem változik |
| D4 | Referenciák helye | Mind a `testdata/reference/` alá (gitignore): `synthetic/` és `m31/`; a `macos/tools/make-references.sh` állítja elő, a modelleket és a katalógust a `download-testdata.sh` tölti le | A szintetikus referencia ~64 MB, túl nagy a repóba; a C#-eszközzel bármikor újragenerálható |
| D5 | „Nyomtatáshoz” TIFF | Valódi 16 bites TIFF (LZW) | A Windows-változat ImageSharp-kódolója a `Bit48` beállítás ellenére 8 bites TIFF-et ír (sips: bitsPerSample 8) – ez Windows-oldali hiba, a Mac a szándékolt 16 bitet írja; a paritásteszt 8 bites pontossággal vet össze |
