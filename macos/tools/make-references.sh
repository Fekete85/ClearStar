#!/bin/bash
# Writes the Windows (C#) reference outputs the Swift parity tests compare with:
#   testdata/reference/synthetic  – small generated inputs, every unit-level result (always)
#   testdata/reference/<set>      – the steps on the real test images (M31, M99, NGC6992_sub – when present)
# The real run also needs the GraXpert ONNX models in testdata/models/<kind>/<version>/model.onnx and the
# Siril offline catalogue in testdata/catalog/ (download-testdata.sh fetches both from the mirror).
set -euo pipefail
cd "$(dirname "$0")/../.."
# Built into a local temporary folder: on a synced drive (Google Drive) the output DLLs can vanish mid-run.
OUT="${TMPDIR:-/tmp}/clearstar-cli"
dotnet build windows/tools/ClearStar.Cli -c Release -p:PlatformTarget=AnyCPU -m:1 -nologo -v q -o "$OUT"
CLI="$OUT/clearstar-cli.dll"
dotnet "$CLI" reference synthetic testdata/reference/synthetic
# Real data sets: folder, reference folder, object name for the plate solve ("" = from the header).
for set in "M31|m31|M 31" "M99|m99|" "NGC6992_sub|ngc6992|"; do
  IFS='|' read -r folder name object <<< "$set"
  [ -d "testdata/$folder" ] || continue
  args=(reference real "testdata/reference/$name" --frames "testdata/$folder" --models testdata/models
        --catalog testdata/catalog/siril_cat_healpix8_astro.dat)
  [ -n "$object" ] && args+=(--object "$object")
  dotnet "$CLI" "${args[@]}" "$@"
done
