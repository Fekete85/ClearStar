# ClearStar – jogi tudnivalók és felhasznált munkák / Legal notices and third-party works

*(Magyar összefoglaló, utána a formális angol nyelvű közlemények. / Hungarian summary first, formal English notices below.)*

## Magyar összefoglaló

### Mi a ClearStar, és ki készítette?

A ClearStar egy kezdőknek szánt, Windowsra készült asztrofotó-feldolgozó program
(.NET / WPF, C#). A program forráskódja – a képfeldolgozó algoritmusok saját
megvalósítása, a lépésalapú munkafolyamat, a felület, a stackelő/igazító motor,
a FITS-olvasó, a nyelvi rendszer – **a ClearStar szerzőjének saját munkája**, a
szerzői jog a szerzőé (lásd a `LICENSE` fájl fejlécét és a program Névjegy
ablakát). A kód **GNU General Public License v3.0 vagy későbbi (GPL-3.0-or-later)**
licenc alatt érhető el: bárki szabadon használhatja, tanulmányozhatja,
módosíthatja és továbbadhatja, feltéve, hogy a módosított változatot is ugyanezen
licenc alatt, forráskóddal együtt adja tovább.

### Miből tanultunk, mit vettünk át?

A ClearStar **nem tartalmaz bemásolt kódot** a Sirilből vagy a GraXpertből, de
mindkét program forráskódját tanulmányoztuk, és több algoritmus logikáját,
paraméterezését azok mintájára írtuk meg C#-ban. Mivel mindkettő GPL-3.0
licencű, és egyes részek (különösen a GraXpert AI-modelljeinek elő- és
utófeldolgozása) szorosan követik az eredeti megoldást, a ClearStar egészét
szintén GPL-3.0 alá helyeztük – ez a jogilag tiszta és a szerzőkkel szemben
tisztességes megoldás.

| Mit használtunk | Kitől | Licenc | Hogyan |
|---|---|---|---|
| **Siril** – stackelés logikája (kalibrálás, képenkénti háttér-gradiens kivonás, csillagok szerinti igazítás, normálás, framing=max, szigma-vágott átlag), GHS-nyújtás képlete, SCNR, autostretch (MTF) | team free-astro, Francois Meyer és közreműködők | GPL-3.0-or-later | tanulmányozott forrás, saját újraírás |
| **GraXpert** – AI háttérkivonás előfeldolgozása (256×256, normálás MAD-dal, padding, simítás), polinomos háttérillesztés ötlete, a tervezett zajcsökkentés/élesítés modellkezelése | GraXpert Development Team | GPL-3.0 | tanulmányozott forrás, saját újraírás |
| **GraXpert AI-modellek** (háttérkivonás, zajcsökkentés, élesítés – `model.onnx` fájlok) | GraXpert Development Team és a tanítóképeket beküldő közösség (névsor lent) | **CC BY-NC-SA 4.0** | a ClearStar **nem tartalmazza** őket; a GraXpert által letöltött vagy a felhasználó által beszerzett fájlokat használja |
| **StarNet2** (csillagleválasztás) | Nikita Misiura / starnetastro.com | saját licenc: ingyenes asztrofotó-feldolgozásra, kereskedelmi szoftverbe nem építhető, nem terjeszthető | a felhasználó saját példányát hívja meg külső programként; a ClearStar nem tartalmazza |
| **AbdurAstro – „Processing in Siril 1.4”** leírás | AbdurAstro | a szerzőé | a 17 lépés sorrendjének mintája; szöveget nem vettünk át |
| **Gaia DR3 katalógus** (ESA Gaia-archívum, VizieR) és a **CDS Sesame** névfeloldó – online lekérdezés a plate solvinghoz | ESA/Gaia/DPAC, CDS Strasbourg | Gaia-adatok: CC BY-SA 3.0 IGO; a CDS-szolgáltatások szabadon használhatók, forrásmegjelöléssel | csak lekérdezés, a program nem tartalmaz katalógusadatot |
| SixLabors.ImageSharp (TIFF/PNG/JPEG írás-olvasás) | Six Labors | Six Labors Split License → nyílt forrású projektben Apache-2.0 | NuGet-csomag |
| Microsoft.ML.OnnxRuntime.DirectML (AI-modellek futtatása) | Microsoft | MIT | NuGet-csomag |
| Microsoft.AI.DirectML – `DirectML.dll` (GPU-gyorsítás DirectX 12-n) | Microsoft | Microsoft Software License Terms (a DLL alkalmazással együtt terjeszthető; a fejlécek MIT) | NuGet-csomag, a program mellé kerül |
| **Siril Astrometry Catalogue** (Gaia DR3-kivonat, `siril_cat_healpix8_astro.dat`) | Siril-csapat (team free-astro) | CC BY 4.0 (Zenodo 14692304; a Gaia-adatok CC BY-SA 3.0 IGO) | az app kérésre letölti a felhasználó gépére; a program nem tartalmazza |
| SharpZipLib (bzip2-kicsomagolás a katalógus letöltéséhez) | ICSharpCode / SharpZipLib közreműködők | MIT | NuGet-csomag |
| CommunityToolkit.Mvvm | .NET Foundation | MIT | NuGet-csomag |
| .NET 10 runtime, WPF | Microsoft | MIT | keretrendszer |
| Segoe UI betűtípus | Microsoft | Windows része | csak a rendszerből |

### A GraXpert AI-modellek – fontos korlátozás

A modellek **Creative Commons BY-NC-SA 4.0** licencűek. Ez azt jelenti:

* **BY** – meg kell nevezni a szerzőt (GraXpert Development Team) és a licencet;
* **NC** – **kereskedelmi célra nem használhatók**: a ClearStar AI-lépései ezért
  csak nem kereskedelmi (hobbi, oktatási, kutatási) használatra valók, még akkor
  is, ha maga a ClearStar-kód (GPL) ezt nem tiltaná;
* **SA** – ha valaki módosított modellt ad tovább, azt ugyanezen licenc alatt teheti.

A ClearStar a modelleket nem terjeszti: a GraXpert telepítése után annak
mappájából (`%LOCALAPPDATA%\GraXpert\GraXpert\…`) olvassa be, vagy a felhasználó
tallózza be / tölti le. Ha a jövőben a ClearStar saját szerverről kínálná fel
őket, az a fenti három feltétel betartásával (forrás és licenc feltüntetése,
változatlan vagy azonos licencű továbbadás, nem kereskedelmi jelleg) tehető meg.

### Mit jelent ez a felhasználónak?

* A programot ingyen használhatod, továbbadhatod, módosíthatod (GPL-3.0).
* A képek, amiket vele készítesz, **a tieid** – a ClearStar semmilyen jogot nem
  formál a kimenetre.
* Az AI-lépések eredményét (a modellek NC feltétele miatt) ne használd
  kereskedelmi célra.
* A program semmilyen adatot nem küld el; az egyetlen hálózati művelet az általad
  megadott URL-ről történő modell-letöltés.

---

## Formal notices (English)

### ClearStar

Copyright (C) 2026 the ClearStar author(s). See the `LICENSE` file.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

ClearStar is an original implementation. It ships no code copied from other
projects, but its algorithms were designed after studying the source code of
the GPL-licensed projects listed below, and in places they follow those
implementations closely. For that reason ClearStar as a whole is licensed under
GPL-3.0-or-later, which is compatible with every work listed here.

### Siril

Siril – astronomical image processing tool. https://siril.org
Copyright (C) 2005-2011 Francois Meyer; Copyright (C) 2012-2026 team free-astro.
Licensed under the GNU General Public License v3.0 or later.
Used as a reference for: the OSC preprocessing/stacking pipeline (calibration,
per-frame background gradient subtraction, star-based registration, additive
normalisation, framing=max, sigma-clipped rejection), the generalised
hyperbolic stretch (GHS) formula, SCNR green removal and the MTF autostretch.
No Siril source code is included in ClearStar.

### GraXpert

GraXpert – background extraction and denoising for astrophotography.
https://graxpert.com – Copyright (C) GraXpert Development Team.
Licensed under the GNU General Public License v3.0.
Used as a reference for: the pre- and post-processing around the AI background
extraction model (256×256 tiling, MAD normalisation, padding, smoothing,
upscaling), the polynomial background fit, and the planned denoising and
deconvolution model handling. No GraXpert source code is included in ClearStar.

### GraXpert AI models (not distributed with ClearStar)

The GraXpert Background Extraction, Denoising and Deconvolution models
(`model.onnx`) are provided by the GraXpert Development Team under the
**Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
(CC BY-NC-SA 4.0)** license – https://creativecommons.org/licenses/by-nc-sa/4.0/
ClearStar does not include these files; it loads models that GraXpert has
already downloaded, or that the user imports or downloads themselves. Any use
of the models – including through ClearStar – is restricted to non-commercial
purposes. The GraXpert team thanks the following people who contributed
training images (verbatim from the model license files):

*Background extraction model:* Alistair M., Axel L., Bernd L., Christian B.,
Christian <chges100> G., Claus-Peter S., David S., Elias <TheAmazingLooser> S.,
Francis M., Frank <frasax> S., Georg I., Henry <Minusman> L., Holger R.,
Iris F., Jürgen <jt> T., Kurt K., Marc <PapaBear_Marc> B., Mark W.,
Moritz <MoMa> M., Niccolo C., Nicolas P., Norbert L., Olaf H., Rafael S.,
Reinhard G., Riccardo A., Roger B., Sherwin C., Steffen <_steffens_> S.,
Steffen <Steffen> H., Stephen R., Steven D., Thomas P., Thomas G.,
Ulrike <astronomy_ffm> K.

*Denoising model:* see `src/ClearStar.App/Legal/GraXpert-Denoise-Model-LICENSE.txt`.
*Deconvolution models:* see `src/ClearStar.App/Legal/GraXpert-Deconvolution-Model-LICENSE.txt`.

### Gaia DR3 and CDS services (online queries only)

Plate solving queries the ESA Gaia Archive (https://gea.esac.esa.int) and, as a
fallback, VizieR (https://vizier.cds.unistra.fr) for Gaia DR3 stars, and the CDS
Sesame service for object names. This work has made use of data from the European
Space Agency (ESA) mission Gaia (https://www.cosmos.esa.int/gaia), processed by the
Gaia Data Processing and Analysis Consortium (DPAC). Gaia data are licensed under
CC BY-SA 3.0 IGO. VizieR and Sesame are provided by the CDS, Strasbourg
Astronomical Data Center. No catalogue data is distributed with ClearStar; query
results are cached locally for the user's own reuse.

### StarNet2 (external program, not distributed)

The star-removal step runs the user's own copy of StarNet2 (https://www.starnetastro.com)
as an external process, the same way Siril does. StarNet2 is licensed by its author for
astrophotography image processing; it may not be used to build commercial software and is
not redistributed with ClearStar. The user installs it separately; ClearStar only locates
and launches it.

### AbdurAstro – "Processing in Siril 1.4"

The order of ClearStar's 17 processing steps follows the workflow described in
the AbdurAstro processing guide. No text or images from the guide are included.

### SixLabors.ImageSharp 3.1.12

Copyright (c) Six Labors. Licensed under the Six Labors Split License, Version
1.0 (June 2022). Because ClearStar is open-source software, ImageSharp is used
under the terms of the Apache License, Version 2.0 as granted by that license.
https://github.com/SixLabors/ImageSharp

### Microsoft.ML.OnnxRuntime.DirectML 1.24.4

Copyright (c) Microsoft Corporation. Licensed under the MIT License.
https://github.com/microsoft/onnxruntime – see the package's ThirdPartyNotices.txt
for the notices of its own dependencies.

### Microsoft.AI.DirectML 1.15.4 (DirectML.dll)

Copyright (c) Microsoft Corporation. The redistributable `DirectML.dll` is licensed
under the Microsoft Software License Terms for DirectX Machine Learning, which
permit distributing it with applications that run on Windows; the headers are MIT.
https://www.nuget.org/packages/Microsoft.AI.DirectML – it provides GPU
acceleration for the AI models on any DirectX 12 device (with CPU fallback).

### Siril Astrometry Catalogue (downloaded on request, not bundled)

The offline plate-solving catalogue is the "Siril Astrometry Catalogue extracted from
Gaia DR3" published by the Siril team on Zenodo (https://zenodo.org/records/14692304)
under CC BY 4.0, in the Siril HEALPix Catalog Format 1.0.0 (specification:
https://zenodo.org/records/14697486). ClearStar downloads it to the user's machine only
when the user asks for it and verifies the published SHA-256. Gaia data: ESA/Gaia/DPAC,
CC BY-SA 3.0 IGO.

### SharpZipLib 1.4.2

Copyright © 2000-2022 SharpZipLib Contributors. Licensed under the MIT License.
https://github.com/icsharpcode/SharpZipLib – used to unpack the bzip2 catalogue download.

### CommunityToolkit.Mvvm 8.4.0

Copyright © .NET Foundation and Contributors. Licensed under the MIT License.
https://github.com/CommunityToolkit/dotnet

### .NET runtime and Windows Presentation Foundation

Copyright (c) .NET Foundation and Contributors. Licensed under the MIT License.
https://github.com/dotnet/runtime · https://github.com/dotnet/wpf

### MIT License (text)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### Apache License 2.0

The full text is available at https://www.apache.org/licenses/LICENSE-2.0.
