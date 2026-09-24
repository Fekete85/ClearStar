# Microsoft Store listing texts

Copy-paste material for Partner Center → Store listings (one section per language).
Screenshots: `packaging/out/store/*.png` (2400×1308, taken from the app).

---

## Hungarian (Hungary)

**Product name:** ClearStar

**Short description (max 100 chars):**
Kezdőbarát asztrofotó-feldolgozás: nyers képektől a kész fotóig 16 vezetett lépésben.

**Description:**

A ClearStar a Seestar és más okostávcsövek, valamint fényképezőgépes asztrofotósok számára készült: a nyers felvételekből egy vezetett, 16 lépéses folyamatban lesz kész kép – minden lépésnél közérthető magyarázattal, jó alapbeállításokkal és élő előnézettel. Nem kell hozzá előképzettség: ha csak végigkattintod, akkor is szép eredményt kapsz; ha akarsz, minden lépésbe belenyúlhatsz.

Mit tud?
• Képek összeillesztése (stackelés): sötét- és flat-képek, Bayer-debayer, csillagok szerinti igazítás, gyenge képek automatikus kihagyása
• Vágás, forgatás élő előnézettel
• Háttér kiegyenlítése, élesítés és zajcsökkentés a GraXpert nyílt AI-modelljeivel – a videokártyán (DirectML) vagy processzoron
• Égbolt azonosítása (plate solving) és fotometriai színkalibrálás a Gaia-katalógus alapján – online vagy offline katalógussal
• Csillagok leválasztása a saját StarNet2 programoddal, a ködök és a csillagok külön kezelése
• Ködök, galaxisok kiemelése: automatikus nyújtás egy gombbal, utána három egyszerű csúszka (objektum fényessége, háttér, kontraszt); haladóknak a Siril GHS-vezérlői
• Zöld árnyalat és lila csillagszegélyek eltávolítása, kontraszt, színtelítettség – mind élőben
• Mentés JPEG, 16 bites TIFF vagy FITS formátumban

Bemenet: FITS, TIFF, PNG, JPEG – mono, RGB és nyers Bayer-mintás képek.

A ClearStar ingyenes és nyílt forráskódú (GPL-3.0). Nem gyűjt adatot; a hálózatot csak a csillagkatalógus-lekéréshez és az általad kért letöltésekhez használja. Az AI-lépésekhez szükséges GraXpert-modelleket egy gombnyomással letölti (ha a GraXpert telepítve van, az ő modelljeit is megtalálja); a csillagleválasztáshoz a StarNet2 kell, a program útmutatója szerint szerezhető be.

**What's new in this version:**
Első nyilvános béta.

**Product features (max 20, egy-egy sor):**
Vezetett 16 lépéses feldolgozás magyarázatokkal
Stackelés kalibrálással és csillag szerinti igazítással
AI háttérkivonás, élesítés, zajcsökkentés (GraXpert-modellek, GPU)
Plate solving és fotometriai színkalibrálás (Gaia)
Csillagok leválasztása StarNet2-vel
Egy gombos automatikus nyújtás + egyszerű csúszkák
Élő előnézet és hisztogram
Magyar és angol felület

**Search terms:** asztrofotó, astrophotography, Seestar, stacking, plate solving, GraXpert, StarNet, csillagászat

**Copyright and trademark info:** © 2026 Laszlo Fekete. GPL-3.0-or-later.

**Additional license terms:** GNU General Public License v3.0 or later – https://github.com/Fekete85/ClearStar/blob/main/LICENSE

**Developed by:** Laszlo Fekete

**Website / Support contact:** https://github.com/Fekete85/ClearStar
**Privacy policy:** https://github.com/Fekete85/ClearStar/blob/main/PRIVACY.md

---

## English (United States)

**Product name:** ClearStar

**Short description (max 100 chars):**
Beginner-friendly astrophotography processing: raw frames to a finished photo in 16 guided steps.

**Description:**

ClearStar is made for owners of Seestar and other smart telescopes and for camera astrophotographers: your raw frames become a finished image through a guided 16-step workflow – every step with a plain-language explanation, good defaults and a live preview. No prior experience needed: click through and you get a pleasing result; dig into any step if you want to.

What it does
• Stacking: dark and flat frames, Bayer demosaicing, star-based alignment, automatic rejection of poor frames
• Crop and rotate with a live preview
• Background flattening, sharpening and noise reduction with GraXpert's open AI models – on your GPU (DirectML) or CPU
• Plate solving and photometric colour calibration against the Gaia catalogue – online or with an offline catalogue
• Star removal with your own StarNet2, then nebulae and stars handled separately
• Bringing out nebulae and galaxies: one-click auto stretch, then three simple sliders (object brightness, background, contrast); Siril's GHS controls for advanced users
• Green cast and purple star fringe removal, contrast, saturation – all live
• Save as JPEG, 16-bit TIFF or FITS

Input: FITS, TIFF, PNG, JPEG – mono, RGB and raw Bayer-pattern images.

ClearStar is free and open source (GPL-3.0). It collects no data; the network is used only for star catalogue queries and downloads you ask for. The GraXpert models the AI steps need are downloaded with one click (models of an installed GraXpert are found too); star removal needs StarNet2 – the app guides you to it.

**What's new in this version:**
First public beta.

**Product features:**
Guided 16-step workflow with explanations
Stacking with calibration and star alignment
AI background extraction, sharpening, denoising (GraXpert models, GPU)
Plate solving and photometric colour calibration (Gaia)
Star removal with StarNet2
One-click auto stretch + simple sliders
Live preview and histogram
Hungarian and English UI

**Search terms:** astrophotography, Seestar, stacking, plate solving, GraXpert, StarNet, astronomy, deep sky

**Copyright and trademark info:** © 2026 Laszlo Fekete. GPL-3.0-or-later.

**Additional license terms:** GNU General Public License v3.0 or later – https://github.com/Fekete85/ClearStar/blob/main/LICENSE

**Developed by:** Laszlo Fekete

**Website / Support contact:** https://github.com/Fekete85/ClearStar
**Privacy policy:** https://github.com/Fekete85/ClearStar/blob/main/PRIVACY.md
