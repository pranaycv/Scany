#!/usr/bin/env python3
"""Write overlay previews for a trained tiny document checkpoint."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw

from doc_dataset import DocCornerTorch
from quad_geometry import mask_to_convex_quad
from tiny_model import arch_from_checkpoint, build_model

ROOT = Path(__file__).resolve().parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--arch", default=None)
    parser.add_argument("--out", type=Path, default=ROOT / "runs" / "eval_overlays")
    parser.add_argument("--limit", type=int, default=24)
    parser.add_argument("--split", default="validation")
    return parser.parse_args()


def stroke(draw: ImageDraw.ImageDraw, quad: np.ndarray, color: tuple[int, int, int], width: int) -> None:
    pts = [(float(x), float(y)) for x, y in quad]
    for i in range(4):
        draw.line([pts[i], pts[(i + 1) % 4]], fill=color, width=width)


def main() -> int:
    args = parse_args()
    ckpt = torch.load(args.checkpoint, map_location="cpu")
    state = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
    arch = args.arch or arch_from_checkpoint(ckpt if isinstance(ckpt, dict) else None)
    model = build_model(arch)
    model.load_state_dict(state)
    model.eval()
    ds = DocCornerTorch(args.split, augment=False, limit=args.limit)
    args.out.mkdir(parents=True, exist_ok=True)
    with torch.no_grad():
        for i in range(min(args.limit, len(ds))):
            item = ds[i]
            image = item["image"].unsqueeze(0)
            mask_logits, presence_logits, _ = model(image)
            pred = (torch.sigmoid(mask_logits)[0, 0] > 0.5).numpy().astype(np.uint8)
            rgb = (item["image"].numpy().transpose(1, 2, 0) * 255).clip(0, 255).astype(np.uint8)
            overlay = Image.fromarray(rgb)
            wash = Image.new("RGB", overlay.size, (180, 40, 160))
            mask_img = Image.fromarray((pred * 160).astype(np.uint8), mode="L")
            overlay = Image.blend(overlay, Image.composite(wash, overlay, mask_img), 0.35)
            draw = ImageDraw.Draw(overlay)
            gt_q = mask_to_convex_quad((item["mask"][0].numpy() > 0.5).astype(np.uint8))
            pred_q = mask_to_convex_quad(pred)
            if gt_q is not None:
                stroke(draw, gt_q, (124, 255, 142), 3)
            if pred_q is not None:
                stroke(draw, pred_q, (92, 200, 255), 2)
            score = float(torch.sigmoid(presence_logits).item())
            overlay.save(args.out / f"{i:04d}_p{score:.2f}.jpg", quality=88)
    print(f"Wrote {args.out} arch={arch}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
