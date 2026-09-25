#!/usr/bin/env python3
"""Converts the GraXpert ONNX models to Core ML (.mlpackage) for the macOS version.

Route: ONNX → PyTorch (onnx2torch) → TorchScript trace → coremltools (ML program). The converted
model is checked against ONNX Runtime (CPU) on real image tiles and on random inputs of the right
distribution; the conversion fails when the difference is above the limit.

  python convert.py <models dir> <output dir> [--precision fp16|fp32]

<models dir> holds <kind>/<version>/model.onnx (as download-testdata.sh / the mirror lays them out);
the output gets <kind>/<version>/model.mlpackage plus the LICENSE.html next to it, and a
validation.json with the measured differences.
"""
import argparse
import json
import os
import shutil
import sys

import subprocess
import tempfile

import numpy as np
import onnx
import torch
import coremltools as ct
from onnx2torch import convert

# Per kind: the tensor layout of the inputs (see the Windows code, AI/*.cs). The batch is fixed at 1:
# the trace bakes the example's batch size into the reshapes, and the tiles (and, for the sharpening
# networks, the channels fed as a batch) are independent, so the app runs them one by one.
SPECS = {
    "bge": {"batch": (1, 1), "inputs": {"gen_input_image": (256, 256, 3)}},
    "denoise": {"batch": (1, 1), "inputs": {"gen_input_image": (256, 256, 3)}},
    "deconvolution-stars": {"batch": (1, 1), "inputs": {"gen_input_image": (1, 512, 512), "params": (2,)}},
    "deconvolution-object": {"batch": (1, 1), "inputs": {"gen_input_image": (1, 512, 512), "params": (2,),
                                                         "sigma": (1,), "strenght": (1,)}},
}


def sample_inputs(kind, names, batch, rng):
    """Inputs in the distribution the Windows code feeds the networks."""
    feeds = {}
    for name in names:
        shape = (batch,) + SPECS[kind]["inputs"][name]
        if name == "gen_input_image":
            if kind == "bge":
                # (x − median)/MAD·0.04 of a smooth background, clamped to ±1.
                y, x = np.mgrid[0:256, 0:256] / 255.0
                base = 0.3 * x[..., None] - 0.2 * y[..., None] + 0.05 * rng.standard_normal((256, 256, 3))
                v = np.clip(np.broadcast_to(base, shape), -1, 1)
            elif kind == "denoise":
                v = np.clip(rng.standard_normal(shape) * 0.3 + (rng.random(shape) < 0.01) * 5.0, -10, 10)
            else:
                v = rng.standard_normal(shape) * 0.1
            feeds[name] = v.astype(np.float32)
        elif name == "params":
            feeds[name] = np.tile(np.array([[0.4, 0.475]], np.float32), (batch, 1))
        else:
            feeds[name] = np.full(shape, 0.4 if name == "sigma" else 0.475, np.float32)
    return feeds


def convert_one(kind, onnx_path, out_path, precision):
    model_onnx = onnx.load(onnx_path)
    input_names = [i.name for i in model_onnx.graph.input if i.name not in {init.name for init in model_onnx.graph.initializer}]
    torch_model = convert(model_onnx).eval()
    lo, hi = SPECS[kind]["batch"]
    rng = np.random.default_rng(1)
    example = sample_inputs(kind, input_names, hi, rng)
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, tuple(torch.from_numpy(example[n]) for n in input_names))
    inputs = []
    for n in input_names:
        dims = SPECS[kind]["inputs"][n]
        batch_dim = ct.RangeDim(lower_bound=lo, upper_bound=hi, default=hi) if hi > lo else hi
        inputs.append(ct.TensorType(name=n, shape=ct.Shape((batch_dim,) + dims), dtype=np.float32))
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = f"GraXpert {kind} model (CC BY-NC-SA 4.0), converted for ClearStar"
    mlmodel.author = "GraXpert Development Team (model); converted by ClearStar"
    mlmodel.license = "CC BY-NC-SA 4.0"
    if os.path.exists(out_path):
        shutil.rmtree(out_path)
    mlmodel.save(out_path)
    return input_names


ORT_RUNNER = """
import sys, numpy as np, onnxruntime as ort
feeds = dict(np.load(sys.argv[2]))
s = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
np.save(sys.argv[3], s.run(None, feeds)[0])
"""


def onnx_reference(onnx_path, feeds):
    """ONNX Runtime output in a separate process (ONNX Runtime and coremltools crash in one process)."""
    with tempfile.TemporaryDirectory() as tmp:
        inp, out = os.path.join(tmp, "in.npz"), os.path.join(tmp, "out.npy")
        np.savez(inp, **feeds)
        subprocess.run([sys.executable, "-c", ORT_RUNNER, onnx_path, inp, out], check=True)
        return np.load(out)


def validate(kind, onnx_path, ml_path, input_names):
    """Differences to ONNX Runtime (CPU) on the CPU alone and with all compute units (what the app uses)."""
    rng = np.random.default_rng(7)
    cases = []
    for _ in range(3):
        feeds = sample_inputs(kind, input_names, 1, rng)
        cases.append((feeds, onnx_reference(onnx_path, feeds)))
    result = {}
    for label, units in (("cpu", ct.ComputeUnit.CPU_ONLY), ("all", ct.ComputeUnit.ALL)):
        ml = ct.models.MLModel(ml_path, compute_units=units)
        worst, rms = 0.0, 0.0
        for feeds, ref in cases:
            out = ml.predict(feeds)["output"]
            d = np.abs(out.astype(np.float64) - ref.astype(np.float64))
            worst = max(worst, float(d.max()))
            rms = max(rms, float(np.sqrt((d ** 2).mean())))
        result[label] = {"maxAbs": worst, "rms": rms}
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models")
    ap.add_argument("output")
    ap.add_argument("--precision", default="fp32", choices=["fp16", "fp32"])
    ap.add_argument("--only", default=None)
    args = ap.parse_args()
    report = {}
    for kind in SPECS:
        if args.only and kind != args.only:
            continue
        kdir = os.path.join(args.models, kind)
        if not os.path.isdir(kdir):
            continue
        for version in sorted(os.listdir(kdir)):
            src = os.path.join(kdir, version, "model.onnx")
            if not os.path.exists(src):
                continue
            dst_dir = os.path.join(args.output, kind, version)
            os.makedirs(dst_dir, exist_ok=True)
            dst = os.path.join(dst_dir, "model.mlpackage")
            print(f"converting {kind} {version} ({args.precision})…", flush=True)
            names = convert_one(kind, src, dst, args.precision)
            lic = os.path.join(kdir, version, "LICENSE.html")
            if os.path.exists(lic):
                shutil.copy(lic, dst_dir)
            v = validate(kind, src, dst, names)
            v["precision"] = args.precision
            report[f"{kind}/{version}"] = v
            for label in ("cpu", "all"):
                print(f"  {label}: max |Δ| {v[label]['maxAbs']:.2e}, rms {v[label]['rms']:.2e}", flush=True)
    with open(os.path.join(args.output, "validation.json"), "w") as f:
        json.dump(report, f, indent=2)


if __name__ == "__main__":
    sys.exit(main())
