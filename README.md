# ClearStar

Vezetett asztrofotó-feldolgozó alkalmazás kezdőknek: a nyers képektől a kész képig 16 lépésben,
minden lépésnél közérthető magyarázattal és 2–4 egyszerű beállítással.

| Mappa | Tartalom |
|---|---|
| [`windows/`](windows/README.md) | Windows-alkalmazás (.NET 10, WPF, ONNX Runtime + DirectML) – a Microsoft Store-ban |
| [`macos/`](macos/README.md) | macOS-alkalmazás (Swift, SwiftUI, Core ML, Apple Silicon) – készül, aláírt DMG-ként a saját oldalról |
| `shared/Languages/` | közös nyelvi fájlok (`hu.json`, `en.json`) – mindkét alkalmazás ezeket használja |
| [`docs/`](docs/macos-port-analysis.md) | a macOS-port elemzése, döntései és ütemterve |
| `site/` | a clearstar.blackit.hu nyitóoldal (Hugo) |
| `design/` | a Claude Design canvas forrásai |
| `testdata/`, `reference/` | tesztképek, illetve Siril/GraXpert forrás tanulmányozásra (gitignore-olva) |

Licenc: **GPL-3.0-or-later** (`LICENSE`); a felhasznált munkák és a GraXpert AI-modellek licence:
`THIRD-PARTY-NOTICES.md`; adatvédelem: `PRIVACY.md`.
