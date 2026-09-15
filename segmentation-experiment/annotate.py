#!/usr/bin/env python3
"""Run a teacher segmenter on DocCorner images and save convex-quad review files.

Prefers local SAM 3 (`facebook/sam3`) with a text prompt. If that checkpoint is
gated or too large for this machine, falls back to SAM 2.1 tiny with a box prompt.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import platform
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from quad_geometry import (  # noqa: E402
    cheap_document_box,
    gt_corners_from_sample,
    mask_to_convex_quad,
    normalize_quad,
    quad_iou,
    quad_to_dict,
)
from review_html import write_review_index  # noqa: E402

DATA_CACHE = ROOT / "data" / "hf_cache"
LOCAL_DATASET = ROOT / "data" / "DocCornerDataset"
MODELS_DIR = ROOT / "models"
REVIEW_DIR = ROOT / "review"
DATASET_ID = "mapo80/DocCornerDataset"
SAM3_ID = "facebook/sam3"
SAM2_ID = "facebook/sam2.1-hiera-tiny"
TEXT_PROMPTS = ("paper", "document", "card", "page", "id card")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", default="train", choices=("train", "validation", "test"))
    parser.add_argument("--offset", type=int, default=100, help="Dataset index to start at (HF viewer page 2 is 100)")
    parser.add_argument("--limit", type=int, default=80, help="How many images to annotate in this run")
    parser.add_argument("--text", default="paper", help="SAM 3 text prompt")
    parser.add_argument("--review-dir", type=Path, default=REVIEW_DIR)
    parser.add_argument("--force-sam2", action="store_true")
    parser.add_argument(
        "--require-sam3",
        action="store_true",
        help="Do not fall back to SAM 2.1 if official SAM 3 fails to load",
    )
    parser.add_argument("--token", default=None)
    return parser.parse_args()


def patch_torch_for_intel() -> None:
    """SAM 3 assumes torch>=2.4 compiler APIs that Intel's last torch 2.2 lacks."""
    import torch

    if not hasattr(torch, "compiler"):
        class _Compiler:
            @staticmethod
            def is_compiling():
                return False

            @staticmethod
            def is_dynamo_compiling():
                return False

        torch.compiler = _Compiler()
        return
    if not hasattr(torch.compiler, "is_compiling"):
        torch.compiler.is_compiling = lambda: False
    if not hasattr(torch.compiler, "is_dynamo_compiling"):
        torch.compiler.is_dynamo_compiling = lambda: False


def pick_device():
    import torch

    patch_torch_for_intel()

    if torch.cuda.is_available():
        return torch.device("cuda")
    # Intel builds can report MPS even though it is not usable.
    if platform.machine() == "x86_64":
        return torch.device("cpu")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def to_pil(image) -> Image.Image:
    if isinstance(image, Image.Image):
        return image.convert("RGB")
    if isinstance(image, dict):
        raw = image.get("bytes")
        if raw:
            return Image.open(io.BytesIO(raw)).convert("RGB")
        path = image.get("path")
        if path:
            return Image.open(path).convert("RGB")
    raise TypeError(f"Unsupported image payload: {type(image)}")


class Sam3Teacher:
    """Official `sam3` package teacher (CPU-capable). Transformers Sam3Model needs torch>=2.5."""

    def __init__(self, path: str, device, token: str | None):
        del token
        import torch
        from sam3.model.sam3_image_processor import Sam3Processor
        from sam3.model_builder import build_sam3_image_model

        patch_torch_for_intel()

        ckpt = Path(path)
        if ckpt.is_dir():
            ckpt = ckpt / "sam3.pt"
        if not ckpt.exists():
            raise FileNotFoundError(
                f"Official SAM 3 checkpoint not found: {ckpt}. "
                "Re-run download_sam3.py so sam3.pt is present."
            )
        bpe = MODELS_DIR / "sam3_assets" / "bpe_simple_vocab_16e6.txt.gz"
        if not bpe.exists():
            raise FileNotFoundError(f"CLIP BPE vocab missing: {bpe}")

        print(f"Building official SAM 3 on {device} from {ckpt} …", flush=True)
        self.torch = torch
        self.device = device
        self.name = str(ckpt)
        self.model = build_sam3_image_model(
            bpe_path=str(bpe),
            device=str(device),
            eval_mode=True,
            checkpoint_path=str(ckpt),
            load_from_HF=False,
            enable_segmentation=True,
            enable_inst_interactivity=False,
            compile=False,
        )
        self.processor = Sam3Processor(
            self.model,
            device=str(device),
            confidence_threshold=0.2,
        )

    def _pick_mask(self, state: dict) -> tuple[np.ndarray | None, float]:
        masks = state.get("masks")
        scores = state.get("scores")
        if masks is None:
            return None, -1.0
        if hasattr(masks, "detach"):
            masks_np = masks.detach().cpu().numpy()
        else:
            masks_np = np.asarray(masks)
        if scores is None:
            scores_np = np.ones((len(masks_np),), dtype=np.float32)
        elif hasattr(scores, "detach"):
            scores_np = scores.detach().cpu().numpy().reshape(-1)
        else:
            scores_np = np.asarray(scores).reshape(-1)
        best_mask = None
        best_score = -1.0
        for i in range(len(masks_np)):
            arr = np.asarray(masks_np[i])
            while arr.ndim > 2:
                arr = arr[0]
            arr = (arr > 0.5).astype(np.uint8)
            area = float(arr.mean())
            if area < 0.02 or area > 0.98:
                continue
            score = float(scores_np[i]) if i < len(scores_np) else float(area)
            if score > best_score:
                best_score = score
                best_mask = arr
        return best_mask, best_score

    def _cxcywh_from_xyxy(self, box: list[float], width: int, height: int) -> list[float]:
        x1, y1, x2, y2 = box
        return [
            ((x1 + x2) / 2.0) / max(width, 1),
            ((y1 + y2) / 2.0) / max(height, 1),
            (x2 - x1) / max(width, 1),
            (y2 - y1) / max(height, 1),
        ]

    def segment(self, image: Image.Image, text: str, prompt_box=None) -> tuple[np.ndarray | None, float, str]:
        best_mask = None
        best_score = -1.0
        best_prompt = text
        state = self.processor.set_image(image)
        prompts = [text] + [p for p in TEXT_PROMPTS if p != text]
        for prompt in prompts:
            self.processor.reset_all_prompts(state)
            out = self.processor.set_text_prompt(prompt=prompt, state=state)
            mask, score = self._pick_mask(out)
            if mask is not None and score > best_score:
                best_mask = mask
                best_score = score
                best_prompt = prompt
            if best_score >= 0.45:
                break
        if best_score < 0.35:
            rgb = np.array(image.convert("RGB"))
            box = prompt_box or cheap_document_box(rgb)
            if box is not None:
                self.processor.reset_all_prompts(state)
                self.processor.set_text_prompt(prompt="paper", state=state)
                cxcywh = self._cxcywh_from_xyxy(box, image.width, image.height)
                out = self.processor.add_geometric_prompt(box=cxcywh, label=True, state=state)
                mask, score = self._pick_mask(out)
                if mask is not None and score > best_score:
                    best_mask = mask
                    best_score = score
                    best_prompt = "paper+box"
        return best_mask, best_score, best_prompt


class Sam2Teacher:
    def __init__(self, path: str, device, token: str | None):
        import torch
        from transformers import Sam2Model, Sam2Processor

        self.name = path
        self.device = device
        self.torch = torch
        kwargs = {"local_files_only": Path(path).exists()}
        if token:
            kwargs["token"] = token
        self.processor = Sam2Processor.from_pretrained(path, **kwargs)
        self.model = Sam2Model.from_pretrained(path, **kwargs).to(device)
        self.model.eval()

    def segment(self, image: Image.Image, text: str, prompt_box=None) -> tuple[np.ndarray | None, float, str]:
        del text
        rgb = np.array(image.convert("RGB"))
        box = prompt_box or cheap_document_box(rgb)
        if box is None:
            h, w = rgb.shape[:2]
            inset_x, inset_y = w * 0.12, h * 0.12
            box = [inset_x, inset_y, w - inset_x, h - inset_y]
        cx = (box[0] + box[2]) / 2.0
        cy = (box[1] + box[3]) / 2.0
        inputs = self.processor(
            images=image,
            input_boxes=[[box]],
            input_points=[[[[cx, cy]]]],
            input_labels=[[[1]]],
            return_tensors="pt",
        )
        allowed = {"pixel_values", "input_points", "input_labels", "input_boxes", "input_masks"}
        model_inputs = {}
        for key, value in inputs.items():
            if key not in allowed:
                continue
            model_inputs[key] = value.to(self.device) if hasattr(value, "to") else value
        with self.torch.no_grad():
            outputs = self.model(**model_inputs, multimask_output=False)
        masks = getattr(outputs, "pred_masks", None)
        scores = getattr(outputs, "iou_scores", None)
        if masks is None:
            return None, -1.0, "sam2-box"
        original_sizes = inputs.get("original_sizes")
        post = self.processor.post_process_masks(masks, original_sizes)
        arr = post[0]
        if hasattr(arr, "detach"):
            arr = arr.detach().cpu().numpy()
        arr = np.asarray(arr)
        while arr.ndim > 2:
            if arr.shape[0] > 1 and scores is not None:
                score_np = scores.detach().cpu().numpy().reshape(-1)
                arr = arr[int(np.argmax(score_np))]
            else:
                arr = arr[0]
        mask = (arr > 0.5).astype(np.uint8)
        score = -1.0
        if scores is not None:
            score_np = scores.detach().cpu().numpy().reshape(-1)
            score = float(np.max(score_np))
        area = float(mask.mean())
        if area < 0.02 or area > 0.98:
            return None, score, "sam2-box"
        return mask, score, "sam2-box"


def resolve_teacher(force_sam2: bool, token: str | None, device, require_sam3: bool = False):
    sam3_local = MODELS_DIR / "sam3"
    sam3_ckpt = sam3_local / "sam3.pt"
    sam2_local = MODELS_DIR / "sam2.1-hiera-tiny"
    errors = []

    if not force_sam2:
        try:
            print(f"Loading official SAM 3 from {sam3_ckpt} on {device} …", flush=True)
            return Sam3Teacher(str(sam3_ckpt), device, token)
        except Exception as exc:
            errors.append(f"SAM3 ({sam3_ckpt}): {exc}")
            print(f"SAM 3 unavailable ({exc})", flush=True)
            if require_sam3:
                raise RuntimeError("SAM 3 is required and failed to load:\n" + "\n".join(errors)) from exc

    candidates = [str(sam2_local)] if (sam2_local / "config.json").exists() else []
    candidates.append(SAM2_ID)
    for path in candidates:
        try:
            print(f"Loading SAM 2.1 from {path} on {device} …", flush=True)
            return Sam2Teacher(path, device, token)
        except Exception as exc:
            errors.append(f"SAM2 ({path}): {exc}")
            print(f"SAM 2.1 unavailable ({exc})", flush=True)

    raise RuntimeError("No teacher model could be loaded:\n" + "\n".join(errors))


def gt_box_from_norm(gt_norm: np.ndarray, width: int, height: int) -> list[float]:
    px = gt_norm * np.array([width, height], dtype=np.float32)
    x1, y1 = float(px[:, 0].min()), float(px[:, 1].min())
    x2, y2 = float(px[:, 0].max()), float(px[:, 1].max())
    pad_x = (x2 - x1) * 0.04
    pad_y = (y2 - y1) * 0.04
    return [
        max(x1 - pad_x, 0.0),
        max(y1 - pad_y, 0.0),
        min(x2 + pad_x, width - 1.0),
        min(y2 + pad_y, height - 1.0),
    ]


def draw_overlay(
    image: Image.Image,
    mask: np.ndarray | None,
    pred_quad: np.ndarray | None,
    gt_quad: np.ndarray | None,
) -> Image.Image:
    rgb = image.convert("RGB")
    overlay = rgb.copy()
    if mask is not None:
        mask_img = Image.fromarray((mask.astype(np.uint8) * 160).clip(0, 255).astype(np.uint8), mode="L")
        if mask_img.size != overlay.size:
            mask_img = mask_img.resize(overlay.size, Image.NEAREST)
        wash = Image.new("RGB", overlay.size, (180, 40, 160))
        overlay = Image.composite(wash, overlay, mask_img)
        overlay = Image.blend(rgb, overlay, 0.35)
    draw = ImageDraw.Draw(overlay)

    def stroke(quad: np.ndarray, color: tuple[int, int, int], width: int) -> None:
        pts = [(float(x), float(y)) for x, y in quad]
        for i in range(4):
            draw.line([pts[i], pts[(i + 1) % 4]], fill=color, width=width)
        for x, y in pts:
            r = 6
            draw.ellipse((x - r, y - r, x + r, y + r), fill=color)

    if gt_quad is not None:
        stroke(gt_quad, (124, 255, 142), 4)
    if pred_quad is not None:
        stroke(pred_quad, (92, 200, 255), 3)
    return overlay


def save_mask_png(path: Path, mask: np.ndarray, size: tuple[int, int]) -> None:
    arr = (np.asarray(mask) > 0).astype(np.uint8) * 255
    img = Image.fromarray(arr, mode="L")
    if img.size != size:
        img = img.resize(size, Image.NEAREST)
    img.save(path)


def main() -> int:
    args = parse_args()
    token = args.token or os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    review_dir = args.review_dir
    overlay_dir = review_dir / "overlays"
    mask_dir = review_dir / "masks"
    json_dir = review_dir / "quads"
    for path in (overlay_dir, mask_dir, json_dir):
        path.mkdir(parents=True, exist_ok=True)

    from datasets import load_dataset

    start = max(args.offset, 0)
    end = start + max(args.limit, 1)
    split_spec = f"{args.split}[{start}:{end}]"
    local_split_dir = {
        "train": LOCAL_DATASET / "train",
        "validation": LOCAL_DATASET / "val",
        "test": LOCAL_DATASET / "test",
    }[args.split]
    local_parquets = sorted(local_split_dir.glob("*.parquet"))
    print(f"Loading {DATASET_ID} {split_spec}", flush=True)
    if local_parquets:
        dataset = load_dataset(
            "parquet",
            data_files={args.split: [str(p) for p in local_parquets]},
            split=split_spec,
        )
    else:
        dataset = load_dataset(
            DATASET_ID,
            split=split_spec,
            cache_dir=str(DATA_CACHE),
        )

    device = pick_device()
    print(f"Device: {device}", flush=True)
    teacher = resolve_teacher(args.force_sam2, token, device, require_sam3=args.require_sam3)

    records = []
    for local_i, sample in enumerate(dataset):
        index = start + local_i
        image = to_pil(sample["image"])
        width, height = image.size
        filename = sample.get("filename") or f"{args.split}_{index:06d}.jpg"
        stem = Path(filename).stem

        gt_norm = gt_corners_from_sample(sample)
        gt_px = None
        if gt_norm is not None:
            gt_px = gt_norm * np.array([width, height], dtype=np.float32)

        prompt_box = None
        mask, score, prompt = teacher.segment(image, text=args.text, prompt_box=prompt_box)
        pred_quad = mask_to_convex_quad(mask) if mask is not None else None

        iou = None
        if pred_quad is not None and gt_px is not None:
            iou = quad_iou(pred_quad, gt_px, width, height)

        found = pred_quad is not None
        pred_payload = {
            "found": found,
            "score": None if score < 0 else score,
            "prompt": prompt,
            "model": teacher.name,
            "quad_norm": normalize_quad(pred_quad, width, height) if pred_quad is not None else None,
            "quad_px": quad_to_dict(pred_quad) if pred_quad is not None else None,
            "iou_vs_gt": iou,
            "is_convex": bool(found),
        }
        record = {
            "filename": filename,
            "split": args.split,
            "index": index,
            "image_width": width,
            "image_height": height,
            "is_negative_gt": bool(sample.get("is_negative")),
            "gt_quad": normalize_quad(gt_px, width, height) if gt_px is not None else None,
            "pred": pred_payload,
        }

        rel_overlay = f"overlays/{stem}.jpg"
        rel_mask = f"masks/{stem}.png"
        overlay = draw_overlay(image, mask, pred_quad, gt_px)
        overlay.save(overlay_dir / f"{stem}.jpg", quality=88)
        if mask is not None:
            save_mask_png(mask_dir / f"{stem}.png", mask, image.size)
            record["mask_path"] = rel_mask
        else:
            record["mask_path"] = ""
        record["overlay_path"] = rel_overlay
        (json_dir / f"{stem}.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
        records.append(record)
        print(
            f"[{local_i + 1}/{len(dataset)}] {filename} found={found} score={score:.3f} iou={iou}",
            flush=True,
        )

    index_path = write_review_index(review_dir, records)
    (review_dir / "summary.json").write_text(
        json.dumps(
            {
                "split": args.split,
                "offset": start,
                "limit": args.limit,
                "count": len(records),
                "found": sum(1 for r in records if r["pred"]["found"]),
                "mean_iou": float(
                    np.mean([r["pred"]["iou_vs_gt"] for r in records if r["pred"]["iou_vs_gt"] is not None] or [0.0])
                ),
                "model": teacher.name,
                "device": str(device),
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"Review gallery: {index_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
