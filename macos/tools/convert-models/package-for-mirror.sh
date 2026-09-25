#!/bin/bash
# Packs the converted Core ML models for the download mirror:
#   <out>/coreml/<kind>/<version>/model.mlpackage.zip + LICENSE.html
# and writes <out>/manifest.json with the entries (path, size, sha256) – merge them into the mirror's
# manifest.json. The folder also works as a local mirror: CLEARSTAR_MIRROR=file://<out>/
#   package-for-mirror.sh <converted models dir> <out>
set -euo pipefail
src=${1:?converted models dir}; out=${2:?output dir}
mkdir -p "$out"
entries=()
for pkg in "$src"/*/*/model.mlpackage; do
  kind=$(basename "$(dirname "$(dirname "$pkg")")"); version=$(basename "$(dirname "$pkg")")
  dest="$out/coreml/$kind/$version"; mkdir -p "$dest"
  rm -f "$dest/model.mlpackage.zip"
  ditto -c -k --keepParent "$pkg" "$dest/model.mlpackage.zip"
  [ -f "$(dirname "$pkg")/LICENSE.html" ] && cp "$(dirname "$pkg")/LICENSE.html" "$dest/"
  for f in "$dest/model.mlpackage.zip" "$dest/LICENSE.html"; do
    [ -f "$f" ] || continue
    rel=${f#"$out/"}
    entries+=("{\"path\":\"$rel\",\"size\":$(stat -f %z "$f"),\"sha256\":\"$(shasum -a 256 "$f" | cut -d' ' -f1)\",\"kind\":\"$kind\",\"version\":\"$version\",\"license\":\"CC BY-NC-SA 4.0\",\"source\":\"GraXpert Development Team (https://graxpert.com), converted to Core ML by ClearStar\"}")
  done
done
(IFS=,; echo "{\"generated\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"files\":[${entries[*]}]}") > "$out/manifest.json"
echo "wrote $out/manifest.json (${#entries[@]} files)"
