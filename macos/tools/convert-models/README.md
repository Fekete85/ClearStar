# GraXpert ONNX → Core ML

```
python3.12 -m venv venv && venv/bin/pip install -r requirements.txt
macos/tools/download-testdata.sh                       # testdata/models/<kind>/<version>/model.onnx
venv/bin/python convert.py ../../../testdata/models ../../../testdata/coreml      # FP32, batch 1
./package-for-mirror.sh ../../../testdata/coreml ../../../testdata/mirror         # zip + manifest.json
```

- Út: ONNX → PyTorch (onnx2torch) → TorchScript → coremltools ML program, **FP32**, rögzített 1-es batch
  (a nyomkövetés a batch-méretet a reshape-ekbe égeti; a csempék és az élesítésnél a csatornák függetlenek).
- Ellenőrzés: minden modell kimenete ONNX Runtime-mal összevetve (külön folyamatban – egy folyamatban a
  coremltools-szal összeomlik), `validation.json`. Mért eltérés (max, normált tér): háttér 8·10⁻⁷, élesítés
  ≤ 1,2·10⁻⁶, zaj 1,8·10⁻² (GPU; a csempeszéleken, amelyek úgyis levágódnak). Képszinten a C#-kimenethez
  képest: élesítés 146 dB, zaj 111 dB PSNR.
- FP16 nem használható: az élesítő modell max. eltérése 0,23.
- A modellek licence CC BY-NC-SA 4.0 (GraXpert Development Team); a `LICENSE.html` a csomag mellé kerül.
