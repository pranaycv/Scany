#!/usr/bin/env python3
"""Rewrite BiFPN einsums and export DocAligner FastViT-T8 to Core ML."""

from __future__ import annotations

import shutil
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, numpy_helper

ROOT = Path(__file__).resolve().parent
ONNX_SRC = ROOT / "models" / "fastvit_t8_h_e_bifpn_256_fp32.onnx"
ONNX_REWRITTEN = ROOT / "models" / "fastvit_t8_rewritten.onnx"
TRACED = ROOT / "models" / "fastvit_t8_traced.pt"
APP_MODEL = ROOT.parent / "Scany" / "Detection" / "ScanyModel.mlpackage"
DRIVE_ID = "1W88oOkHjMza6xXbDxrG8k_C-Tf2aYKJ4"


def ensure_onnx() -> None:
    if ONNX_SRC.exists() and ONNX_SRC.stat().st_size > 1_000_000:
        return
    ONNX_SRC.parent.mkdir(parents=True, exist_ok=True)
    import gdown

    print("downloading FastViT-T8 ONNX...", flush=True)
    gdown.download(f"https://drive.google.com/uc?id={DRIVE_ID}", str(ONNX_SRC), quiet=False)


def rewrite_bifpn_einsums(model: onnx.ModelProto) -> onnx.ModelProto:
    """Replace `i,i...->...` with Unsqueeze + Mul + ReduceSum (Core ML friendly)."""
    graph = model.graph
    new_nodes: list[onnx.NodeProto] = []
    extra_inits: list[onnx.TensorProto] = []

    for node in graph.node:
        if node.op_type != "Einsum":
            new_nodes.append(node)
            continue
        equation = next(a.s.decode() for a in node.attribute if a.name == "equation")
        if equation != "i,i...->...":
            raise ValueError(f"Unexpected einsum {node.name}: {equation}")
        weights, features = node.input
        out = node.output[0]
        stem = node.name.replace("/", "_").replace(".", "_")
        axes5 = f"{stem}_unsqueeze_axes"
        extra_inits.append(numpy_helper.from_array(np.array([1, 2, 3, 4], dtype=np.int64), axes5))
        w5 = f"{stem}_w5"
        new_nodes.append(helper.make_node("Unsqueeze", [weights, axes5], [w5], name=f"{stem}_unsqueeze"))
        mul = f"{stem}_mul"
        new_nodes.append(helper.make_node("Mul", [features, w5], [mul], name=f"{stem}_mul"))
        sum_axes = f"{stem}_sum_axes"
        extra_inits.append(numpy_helper.from_array(np.array([0], dtype=np.int64), sum_axes))
        new_nodes.append(
            helper.make_node("ReduceSum", [mul, sum_axes], [out], name=f"{stem}_sum", keepdims=0)
        )

    del graph.node[:]
    graph.node.extend(new_nodes)
    graph.initializer.extend(extra_inits)
    onnx.checker.check_model(model)
    return model


def main() -> int:
    ensure_onnx()
    print("rewrite einsums...", flush=True)
    model = rewrite_bifpn_einsums(onnx.load(str(ONNX_SRC)))
    onnx.save(model, str(ONNX_REWRITTEN))

    import onnxruntime as ort
    import torch
    from onnx2torch import convert as onnx_to_torch

    rng = np.random.default_rng(0)
    dummy = rng.random((1, 3, 256, 256), dtype=np.float32)
    orig = ort.InferenceSession(str(ONNX_SRC), providers=["CPUExecutionProvider"])
    rew = ort.InferenceSession(str(ONNX_REWRITTEN), providers=["CPUExecutionProvider"])
    a = orig.run(None, {"img": dummy})[0]
    b = rew.run(None, {"img": dummy})[0]
    max_diff = float(np.max(np.abs(a - b)))
    print(f"onnx rewrite max|diff|={max_diff:.6g} shape={a.shape}", flush=True)
    if max_diff > 1e-5:
        raise SystemExit(f"rewrite mismatch {max_diff}")

    print("onnx2torch + trace...", flush=True)
    net = onnx_to_torch(str(ONNX_REWRITTEN))
    net.eval()
    x = torch.from_numpy(dummy)
    with torch.no_grad():
        y = net(x)
    print("torch out", tuple(y.shape), flush=True)
    traced = torch.jit.trace(net, x, strict=False)
    traced.eval()
    TRACED.parent.mkdir(parents=True, exist_ok=True)
    traced.save(str(TRACED))

    import coremltools as ct

    print("coremltools convert...", flush=True)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS15,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="img",
                shape=(1, 3, 256, 256),
                scale=1 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.BGR,
            )
        ],
        outputs=[ct.TensorType(name="heatmap")],
    )
    mlmodel.short_description = "Scany page detector (DocAligner FastViT-T8 heatmap)"
    mlmodel.author = "DocsaidLab / Scany"
    mlmodel.license = "Apache-2.0"
    mlmodel.version = "fastvit_t8_h_e_bifpn_256"
    if APP_MODEL.exists():
        shutil.rmtree(APP_MODEL)
    APP_MODEL.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(APP_MODEL))
    print("wrote", APP_MODEL, flush=True)

    spec = mlmodel.get_spec()
    print("inputs", [i.name for i in spec.description.input])
    print("outputs", [o.name for o in spec.description.output])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
