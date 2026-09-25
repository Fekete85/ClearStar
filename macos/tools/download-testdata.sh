#!/bin/bash
# Fetches the GraXpert ONNX models and the Siril offline catalogue from the author's mirror into
# testdata/ (checked against the manifest's SHA-256). ~2.8 GB.
set -euo pipefail
cd "$(dirname "$0")/../../testdata" 2>/dev/null || { mkdir -p "$(dirname "$0")/../../testdata"; cd "$(dirname "$0")/../../testdata"; }
M=${CLEARSTAR_MIRROR:-https://csillag.blackit.hu/clearstar/}
curl -fsS "$M/manifest.json" -o manifest.json
python3 - "$M" <<'PY'
import hashlib, json, os, sys, urllib.request
base = sys.argv[1]
m = json.load(open('manifest.json'))
for f in m['files']:
    p = f['path']
    if p.endswith('model.onnx') or p.endswith('LICENSE.html'):
        parts = p.split('/'); dest = f"models/{parts[1].replace('-ai-models','')}/{parts[2]}/{parts[3]}"
    elif p.endswith('healpix8_astro.dat'):
        dest = 'catalog/siril_cat_healpix8_astro.dat'
    else:
        continue
    def sha(path):
        h = hashlib.sha256()
        with open(path, 'rb') as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b''): h.update(chunk)
        return h.hexdigest()
    if os.path.exists(dest) and sha(dest) == f['sha256']:
        print('ok', dest); continue
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    urllib.request.urlretrieve(base + p, dest + '.part')
    os.replace(dest + '.part', dest)
    assert sha(dest) == f['sha256'], dest
    print('downloaded', dest)
PY
