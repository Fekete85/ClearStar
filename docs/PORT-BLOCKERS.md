# macOS-port – csak a szerző által megoldható tételek

Ezeket a port helyi stubbal vagy fixtúrával kerüli meg; a kiadás előtt a szerzőnek kell elvégeznie őket.

| # | Tétel | Mit kell tenni | Addig a port így halad |
|---|---|---|---|
| ~~B1~~ | ~~Core ML-modellek a tükrön~~ | **Megoldva 2026-09-25** (a szerző engedélyével): a 4 `coreml/<fajta>/<verzió>/model.mlpackage.zip` + `LICENSE.html` fent van a `https://csillag.blackit.hu/clearstar/` alatt, a `manifest.json` frissítve (a forrás: `12_Development/ClearStar-mirror`, `make-manifest.ps1` kiegészítve a `coreml` ággal), szerveren `sha256sum -c` rendben | Élő teszt: `CLEARSTAR_LIVE_MIRROR=1 … --filter liveMirror`; helyi stub továbbra is: `testdata/mirror/` |
