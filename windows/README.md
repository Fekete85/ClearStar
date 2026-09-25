# ClearStar

A guided astrophotography processing Windows application for beginners: from raw frames to the finished image in 16 steps,
with a plain-language explanation and 2–4 simple settings at every step.

## Running

```
dotnet build
dotnet run --project src/ClearStar.App              # empty start
dotnet run --project src/ClearStar.App -- <folder>   # loads and stacks immediately
dotnet test                                          # Core tests
dotnet publish src/ClearStar.App -c Release -o publish   # a single self-contained ClearStar.exe (x64, .NET built in)
```

The publish output is a single file: .NET and the program are inside `ClearStar.exe`; the native libraries (WPF, ONNX Runtime,
DirectML) are extracted to the `%TEMP%\.net\ClearStar\` cache on first launch. Only an
optional `Languages` folder may go next to the exe.

Supported input: FITS (8/16/32-bit integer, 32/64-bit float; mono, RGB and Bayer-pattern OSC raw – debayered based on `BAYERPAT`), TIFF, PNG, JPEG.
Real test data: Seestar S50 Pro, 63×30 s M31 (`../testdata/M31`, gitignored) – the full pipeline runs on it in ~30 s.
Frames in the folder are sorted by the `IMAGETYP` header or by the file name/subfolder (`light`, `dark`, `flat`, `bias`).

## Structure

```
src/ClearStar.Core      – UI-independent processing core
  Imaging/    AstroImage (planar float32), ImageStats (median/MAD), DisplayStretch (autostretch MTF)
  IO/         FitsReader/FitsWriter, ImageFiles (TIFF/PNG/JPEG), FrameSet (sorting the folder)
  Pipeline/   StepDefinition (16 steps + parameter descriptions), Workflow (running steps,
              per-step snapshots, "Frissítés szükséges" (Update required) flag), SnapshotStore (memory+disk)
  Registration/ StarDetector (threshold + components + weighted centroid), StarMatcher (offset voting,
              iterative nearest neighbor, closed-form similarity fit), ImageWarp (bilinear)
  Steps/      one class per step; StepCatalog provides the order
src/ClearStar.App       – WPF UI (MVVM, CommunityToolkit.Mvvm)
  Themes/     dark Fluent-style theme, icons, templates for the step card and the setting types
  ViewModels/ MainViewModel (workflow + preview), StepViewModel, Parameter*ViewModel
  Controls/   ImageViewer (zoom/pan, before/after split view)
tests/ClearStar.Core.Tests
../design/              – Claude Design canvas sources (build.js generates the artboards)
../reference/           – Siril and GraXpert source (GPL-3.0, for study only; gitignored)
```

A new step = one `StepBase` subclass: `Definition` provides the name, explanation and
parameters (from these the UI builds a slider/toggle/selector on its own), `RunAsync` produces the image.
The UI does not need to be modified for it.

## Step status

| # | Step | Status |
|---|---|---|
| 1 | Load images | done |
| 2 | Stacking | calibration, Bayer debayering, per-frame gradient subtraction (like Siril `seqsubsky 1`), star-based alignment, background normalization (`norm=add`), full field of view (`framing=max`), sigma-clipped mean |
| 3 | Crop | selection with handles, edge slider, quarter turns + fine angle (−45…+45°, bilinear), mirroring – all with live preview (WPF TransformedBitmap), the covered rectangle recalculated on the rotated image |
| 4 | Background equalization | GraXpert AI model (ONNX Runtime, DirectML GPU / CPU) or polynomial model; model picker, download from the mirror, browse, URL |
| 5 | Sharpening | GraXpert deconvolution models: stars first, then the object (512 tiles, log normalization, automatic FWHM measurement); with DirectML on the graphics card (~11 s for the two passes at 9 MP), with CPU fallback (~140 s) |
| 6 | Noise reduction | GraXpert denoise model (256 tiles, 128 stride, median/MAD normalization, preservation of bright pixels, blending by strength); ~20 s on GPU at 9 MP |
| 7 | Sky identification | „near” plate solving: Gaia DR3 stars around the header RA/DEC (or object name → CDS Sesame) – **offline** from the Siril HEALPix catalog (`siril_cat_healpix8_astro.dat`, own reader, ~0.5 s), otherwise ESA archive TAP, VizieR fallback, disk cache, triangle matching including mirrored images, TAN WCS with least-squares fit; the result is written to the FITS header (~2 s) |
| 8 | Color calibration | photometric (SPCC-like): based on the WCS, aperture photometry of the Gaia stars in R/G/B, robust line fit against the BP−RP color index, red/blue multiplier at the solar-type (or Vega) white reference; background neutralization (~1 s) |
| 9 | Star separation | calls the user's own StarNet2 CLI (from the Siril settings, the install location or browsed; setup dialog with download instructions); on a linear image automatic MTF pre-stretch → StarNet2 → exact inverse stretch; the star layer (original − starless) is kept in StarLayerStore |
| 10 | Nebula enhancement (GHS) | three sliders for beginners: object brightness (MTF over the range above the background), background level (black point shift), contrast between the two (GHS centered on the background, the background stays in place); under advanced settings the controls of the Siril GHS dialog (ln(D+1), b, SP, LP, HP, type, BP, color model – a port of ght.c), live preview + histogram with markers, „Alkalmaz” (Apply) = commit to the stretch history and a clean slate (multi-stage stretching), undo; magic wand = the current setting of „Előnézet felerősítése” (Boost preview) committed (per-channel, unlinked MTF, shadow = median − k·MAD – the same as GraXpert's autostretch; measured on the same downscaled image as the preview); eyedropper for SP |
| 11 | Star recombination | step 10 also produces the star layer „at full strength” (the original image stretched with the same stretch history, minus the starless one); the slider adds this layer additively, at the maximum every star returns exactly as if there had been no separation, below that the layer is raised to the power of 1/value (faint stars and halos disappear first); live preview; without separation, a mild MTF stretch of the whole image |
| 12 | Green removal (SCNR) | done, live preview |
| 13 | Color fringes | neutralization of purple/violet fringes around bright stars (hue window violet–magenta, saturation and brightness threshold, preserving brightness – based on Siril's unpurple idea); advanced: threshold, width of the color range; live preview |
| 14–15 | Contrast, saturation | done, live preview |
| 16 | Save | JPEG / TIFF 16-bit / FITS |

## License and legal notices

ClearStar is licensed under **GPL-3.0-or-later** (`LICENSE`). It is our own implementation, but we learned from the source code
of Siril and GraXpert (both GPL-3.0), so the project is GPL as well. The works used, the **CC BY-NC-SA 4.0** (non-commercial only)
license of the GraXpert AI models, and the list of contributors are in
`THIRD-PARTY-NOTICES.md`, and the program also shows them in the Névjegy (About) window (the „?” button at the top right).
The author's name must be set in the `Authors`/`Copyright` fields of `Directory.Build.props` – from there it goes into the About window.

## Languages

Every label comes from the language database: `../shared/Languages/hu.json` and `en.json` (built into Core; the macOS app uses them too).
New language: copy `en.json` as `xx.json` (`_meta.name` is the name of the language), translate it, and put it in the
`Languages` folder next to the program or here: `%LOCALAPPDATA%\ClearStar\Languages`. A file with the same code
overrides the built-in one; missing keys are shown in English. The language can be selected in the About window
(`settings.json` → `language`); by default it is the Windows language if there is a file for it, otherwise Hungarian.
Slider labels are arrays; the `{0}` placeholders use .NET format (`{1:0.0}`).

## Command-line runner

`tools/ClearStar.Cli`: runs the full pipeline without UI (`clearstar-cli <folder> <output folder>`), and
`clearstar-cli bench <image>` measures the time of each operation on one image.

## Smart App Control

If the exe or the tests stop with `FileLoadException (0x800711C7)`, Windows Smart App Control
is blocking the unsigned, freshly built DLLs. For development it must be turned off:
Settings → Windows Security → App & browser control → Smart App Control → Off.

## AI models

Step 4 (and later noise reduction and sharpening) uses GraXpert's open ONNX models. GraXpert
downloads them from a private repository, so ClearStar fetches the latest one from its own download mirror
(`https://csillag.blackit.hu/clearstar/`, `AppLinks.Mirror`): the mirror's
`manifest.json` provides the version, the size and the SHA-256, which we verify after download. The mirror
also serves the offline star catalog (Zenodo is only a fallback). It automatically finds models already downloaded by
GraXpert (`%LOCALAPPDATA%\GraXpert\GraXpert\…`); in addition, a `model.onnx`/zip
can be browsed for or downloaded from a URL (`%LOCALAPPDATA%\ClearStar\ai-models`). The choice is persisted in
`%LOCALAPPDATA%\ClearStar\settings.json`. The workflow follows the „AbdurAstro Method for Processing in
Siril 1.4” guide.

## Microsoft Store package (MSIX)

`packaging/make-msix.ps1` builds an MSIX from the single-file publish (it requires the Windows SDK `makeappx` – the
„Windows SDK Signing Tools for Desktop Apps” component). It generates the icons from `clearstar_icon.png`,
and fills the placeholders of the manifest (`packaging/AppxManifest.xml`) with the Partner Center *Product identity* values:

```
.\packaging\make-msix.ps1 -IdentityName "<Package/Identity/Name>" -Publisher "<CN=…>" -PublisherDisplayName "<name>"
```

The finished `packaging/out/ClearStar_<version>_x64.msix` goes to the Store unsigned (the Store signs it).
For a local trial, `-Sign` creates a self-signed certificate; after running the printed `Import-Certificate` command the
package can be installed by double-clicking. `PRIVACY.md` is the privacy policy requested by the Store.
