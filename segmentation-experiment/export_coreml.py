#!/usr/bin/env python3
"""Export a tiny document segmenter to Core ML for the Scany iOS app."""

from __future__ import annotations

import argparse
from pathlib import Path

import torch

from tiny_model import (
    ARCH_TRANSFORMER,
    ExportNet,
    arch_from_checkpoint,
    build_model,
    count_params,
    normalize_arch,
)

ROOT = Path(__file__).resolve().parent
APP_MODELS = {
    "cnn": ROOT / "runs" / "TinyDocumentSegmenter.mlpackage",
    "transformer": ROOT / "runs" / "TinyDocumentTransformer.mlpackage",
}
APP_MODEL = APP_MODELS["cnn"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--arch", default=None, help="cnn or transformer; default: read from checkpoint")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--image-size", type=int, default=256)
    parser.add_argument("--format", choices=("neuralnetwork", "mlprogram"), default="mlprogram")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ckpt = torch.load(args.checkpoint, map_location="cpu")
    state = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
    arch = normalize_arch(args.arch) if args.arch else arch_from_checkpoint(ckpt if isinstance(ckpt, dict) else None)
    net = build_model(arch)
    net.load_state_dict(state)
    net.eval()
    export = ExportNet(net)
    export.eval()
    dummy = torch.rand(1, 3, args.image_size, args.image_size)
    with torch.no_grad():
        mask, presence = export(dummy)
    print(
        f"arch={arch} params={count_params(net):,} mask={tuple(mask.shape)} presence={tuple(presence.shape)}",
        flush=True,
    )

    traced = torch.jit.trace(export, dummy, strict=True)
    traced.eval()

    import coremltools as ct

    out = args.out or APP_MODELS[arch]
    mlmodel = ct.convert(
        traced,
        convert_to=args.format,
        minimum_deployment_target=ct.target.iOS15,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, args.image_size, args.image_size),
                scale=1 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[
            ct.TensorType(name="mask"),
            ct.TensorType(name="presence"),
        ],
    )
    kind = "transformer" if arch == ARCH_TRANSFORMER else "CNN"
    mlmodel.short_description = f"Tiny {kind} document page segmenter for Scany"
    mlmodel.author = "Scany"
    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))
    print(f"Wrote {out} ({out.stat().st_size} bytes)", flush=True)
    weights = args.checkpoint.parent / f"tiny_document_{arch}.pt"
    torch.save({"model": net.state_dict(), "image_size": args.image_size, "arch": arch}, weights)
    print(f"Wrote {weights}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
