#!/bin/bash
# Writes the Windows (C#) reference outputs the Swift parity tests compare with:
#   testdata/reference/synthetic  – small generated inputs, every unit-level result (always)
#   testdata/reference/m31        – the steps on the real test images (when testdata/M31 exists)
# The real run also needs the GraXpert ONNX models in testdata/models/<kind>/<version>/model.onnx and the
# Siril offline catalogue in testdata/catalog/ (download-testdata.sh fetches both from the mirror).
set -euo pipefail
cd "$(dirname "$0")/../.."
dotnet build windows/tools/ClearStar.Cli -c Release -p:PlatformTarget=AnyCPU -m:1 -nologo -v q
CLI=windows/tools/ClearStar.Cli/bin/Release/net10.0/clearstar-cli.dll
dotnet "$CLI" reference synthetic testdata/reference/synthetic
if [ -d testdata/M31 ]; then
  dotnet "$CLI" reference real testdata/reference/m31 --m31 testdata/M31 --models testdata/models \
    --catalog testdata/catalog/siril_cat_healpix8_astro.dat "$@"
fi
