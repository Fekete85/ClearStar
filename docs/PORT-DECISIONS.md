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
| D6 | Core ML-modellek pontossága és batch-mérete | FP32 ML program, rögzített 1-es batch, `computeUnits = .all` (a Neural Engine csak FP16-ot futtat, így gyakorlatilag GPU) | FP16-ban az élesítő modell max. eltérése 0,23 a normált térben; FP32-ben a háttér- és élesítő modellek ≤ 3·10⁻⁶-ra egyeznek az ONNX Runtime-mal. A nyomkövetés a batch-méretet a reshape-ekbe égeti, ezért batch 1, csempénként / csatornánként futtatva (a C# is függetlenül kezeli őket) |
| D7 | ONNX-referencia a konverzióban | Az ONNX Runtime külön Python-folyamatban fut | Egy folyamatban a coremltools-szal szegmentálási hibát okoz |
| D8 | AI-sebesség | FP32 marad a zajmodellnél is | GPU-korlátos (0,115 s / 256²-es csempe, kötegelve és párhuzamosan is); FP16-ban a Neural Engine-en csak ~20%-kal gyorsabb. 7,4 MP-en élesítés ~94 s, zaj ~112 s (a Windows DirectML-es dedikált GPU-n gyorsabb) |
| D9 | Siril offline katalógus felderítése | Beállítás → Siril `config*.ini` `catalogue_gaia_astro=` → `~/Library/Application Support/org.siril.Siril[/siril]`, `~/.local/share/siril` → ClearStar-mappa; a gyorsítótárazott katalógus érvénytelenül, ha a jelöltlista első létező eleme megváltozott | Windows-egyező sorrend; a Windows-változat újraindításig a régit tartja – itt a beállítás-változás azonnal érvényes |
