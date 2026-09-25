# ClearStar

Guided astrophotography processing app for beginners: from raw frames to a finished image in 16 steps,
with a plain-language explanation and 2–4 simple settings at every step.

| Folder | Contents |
|---|---|
| [`windows/`](windows/README.md) | Windows app (.NET 10, WPF, ONNX Runtime + DirectML) – on the Microsoft Store |
| [`macos/`](macos/README.md) | macOS app (Swift, SwiftUI, Core ML, Apple Silicon, macOS 26+) – as a signed DMG from the project site |
| `shared/Languages/` | shared language files (`hu.json`, `en.json`) – used by both apps |
| [`docs/`](docs/macos-port-analysis.md) | analysis of the macOS port, its decisions (`PORT-DECISIONS.md`), status (`PORT-CHECKLIST.md`) and the to-dos waiting on the author (`PORT-BLOCKERS.md`) |
| `site/` | the clearstar.blackit.hu landing page (Hugo) |
| `design/` | Claude Design canvas sources |
| `testdata/`, `reference/` | test images and Siril/GraXpert source for study (gitignored) |

Licence: **GPL-3.0-or-later** (`LICENSE`); licences of the third-party works and the GraXpert AI models:
`THIRD-PARTY-NOTICES.md`; privacy: `PRIVACY.md`.
