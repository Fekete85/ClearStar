# ClearStar – Adatvédelmi tájékoztató / Privacy policy

*Utolsó frissítés / last updated: 2026-09-18*

## Magyar

A ClearStar egy asztrofotó-feldolgozó asztali program Windowsra. **Nem gyűjt, nem tárol és nem küld el
semmilyen személyes adatot.** Nincs benne felhasználói fiók, telemetria, hirdetés vagy elemzés.

A program a következő esetekben használ hálózatot, mindig csak akkor, amikor te indítod el az adott lépést:

* **Égbolt azonosítása és színkalibrálás:** a képed közepéhez tartozó égi koordináták (jobbra emelkedés,
  deklináció) és a látómező mérete alapján csillagadatokat kér le az ESA Gaia-archívumból vagy a CDS
  (Strasbourg) VizieR/Sesame szolgáltatásától. Csak ezek a koordináták, illetve a beírt objektumnév
  utazik a szerverhez – a képed nem.
* **Offline csillagkatalógus letöltése:** a Siril Astrometry Catalogue fájlját tölti le a Zenodo
  szerveréről, ha te ezt kéred a beállítóablakban.
* **AI-modell letöltése:** ha megadsz egy URL-t, arról tölti le a modellfájlt.

A képeid és minden beállítás kizárólag a saját gépeden marad (`%LOCALAPPDATA%\ClearStar`). A program nem
nyit meg más fájlt, mint amit te kiválasztasz, és az általad választott mappába ment.

A csillagleválasztáshoz a program a **te** géped StarNet2 példányát indítja el; ez a program nem a ClearStar
része, saját feltételei vannak.

Kérdés esetén: a projekt GitHub-oldalán nyithatsz hibajegyet.

## English

ClearStar is a desktop astrophotography processing application for Windows. **It does not collect,
store or transmit any personal data.** There are no user accounts, no telemetry, no advertising and
no analytics.

The application uses the network only in the following cases, and only when you start that step:

* **Sky identification and colour calibration:** based on the sky coordinates of the centre of your
  image (right ascension, declination) and the size of the field of view it queries star data from the
  ESA Gaia archive or the CDS (Strasbourg) VizieR/Sesame services. Only those coordinates or the object
  name you typed are sent – never your image.
* **Offline star catalogue download:** downloads the Siril Astrometry Catalogue file from Zenodo when
  you request it in the setup dialog.
* **AI model download:** if you enter a URL, the model file is downloaded from it.

Your images and all settings stay on your own computer (`%LOCALAPPDATA%\ClearStar`). The application
opens no files other than the ones you pick, and saves to the folder you choose.

For star removal the application launches **your own** copy of StarNet2; that program is not part of
ClearStar and has its own terms.

Questions: open an issue on the project's GitHub page.
