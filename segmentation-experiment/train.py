#!/usr/bin/env python3
"""Train a tiny document segmenter on DocCorner plus optional manual JPEG+JSON pairs."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import ConcatDataset, DataLoader

from doc_dataset import IMAGE_SIZE, DocCornerTorch, ManualQuadFolder, RepeatedDataset
from quad_geometry import mask_to_convex_quad, quad_iou
from tiny_model import (
    ARCH_CHOICES,
    ARCH_CNN,
    arch_from_checkpoint,
    build_model,
    count_params,
    normalize_arch,
    pick_device,
)

ROOT = Path(__file__).resolve().parent
RUNS = ROOT / "runs"
DEFAULT_MANUAL = ROOT / "Train"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=ARCH_CHOICES, default=ARCH_CNN)
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--lr", type=float, default=1.5e-3)
    parser.add_argument("--image-size", type=int, default=IMAGE_SIZE)
    parser.add_argument("--train-limit", type=int, default=None)
    parser.add_argument("--val-limit", type=int, default=512)
    parser.add_argument("--manual-dir", type=Path, default=DEFAULT_MANUAL)
    parser.add_argument("--no-manual", action="store_true", help="Train on DocCorner only")
    parser.add_argument(
        "--manual-repeats",
        type=int,
        default=None,
        help="Repeat each Train/ sample per epoch (default: ~1024 presentations)",
    )
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--run-dir", type=Path, default=None)
    parser.add_argument("--resume", type=Path, default=None)
    return parser.parse_args()


def dice_loss(logits: torch.Tensor, targets: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    probs = torch.sigmoid(logits)
    dims = (2, 3)
    inter = (probs * targets).sum(dims)
    den = probs.sum(dims) + targets.sum(dims)
    return 1.0 - ((2.0 * inter + eps) / (den + eps)).mean()


def batch_loss(outputs, batch) -> tuple[torch.Tensor, dict[str, float]]:
    mask_logits, presence_logits, quad_pred = outputs
    bce = F.binary_cross_entropy_with_logits(mask_logits, batch["mask"])
    dice = dice_loss(mask_logits, batch["mask"])
    presence = F.binary_cross_entropy_with_logits(presence_logits, batch["presence"])
    pos = batch["is_positive"].view(-1) > 0.5
    if pos.any():
        quad = F.l1_loss(quad_pred[pos], batch["quad"][pos])
    else:
        quad = quad_pred.sum() * 0.0
    total = bce + dice + 0.4 * presence + 1.5 * quad
    return total, {
        "loss": float(total.detach()),
        "bce": float(bce.detach()),
        "dice": float(dice.detach()),
        "presence": float(presence.detach()),
        "quad": float(quad.detach()),
    }


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device, max_quad: int = 128) -> dict:
    model.eval()
    losses = []
    mask_ious = []
    quad_ious = []
    presence_ok = []
    seen_quad = 0
    for batch in loader:
        batch = {k: v.to(device) for k, v in batch.items()}
        outputs = model(batch["image"])
        _, metrics = batch_loss(outputs, batch)
        losses.append(metrics["loss"])
        mask_logits, presence_logits, _ = outputs
        pred_mask = (torch.sigmoid(mask_logits) > 0.5).float()
        tgt = batch["mask"]
        inter = (pred_mask * tgt).sum(dim=(1, 2, 3))
        union = ((pred_mask + tgt) > 0).float().sum(dim=(1, 2, 3)).clamp_min(1.0)
        mask_ious.extend((inter / union).cpu().tolist())
        pred_pos = (torch.sigmoid(presence_logits).view(-1) > 0.5).cpu()
        true_pos = (batch["is_positive"].view(-1) > 0.5).cpu()
        presence_ok.extend((pred_pos == true_pos).tolist())
        if seen_quad >= max_quad:
            continue
        pred_np = pred_mask.squeeze(1).cpu().numpy()
        tgt_np = tgt.squeeze(1).cpu().numpy()
        for i in range(pred_np.shape[0]):
            if seen_quad >= max_quad:
                break
            if float(true_pos[i]) < 0.5:
                continue
            pred_q = mask_to_convex_quad((pred_np[i] > 0.5).astype(np.uint8))
            tgt_q = mask_to_convex_quad((tgt_np[i] > 0.5).astype(np.uint8))
            if pred_q is None or tgt_q is None:
                quad_ious.append(0.0)
            else:
                size = pred_np.shape[-1]
                quad_ious.append(quad_iou(pred_q, tgt_q, size, size))
            seen_quad += 1
    return {
        "loss": float(np.mean(losses) if losses else 0.0),
        "mask_iou": float(np.mean(mask_ious) if mask_ious else 0.0),
        "quad_iou": float(np.mean(quad_ious) if quad_ious else 0.0),
        "presence_acc": float(np.mean(presence_ok) if presence_ok else 0.0),
    }


def combined_score(val: dict, manual: dict | None) -> float:
    if manual is None:
        return float(val["mask_iou"])
    return 0.6 * float(val["mask_iou"]) + 0.4 * float(manual["mask_iou"])


def maybe_load_manual(folder: Path | None, image_size: int, augment: bool) -> ManualQuadFolder | None:
    if folder is None or not folder.exists():
        return None
    try:
        return ManualQuadFolder(folder, image_size=image_size, augment=augment, mild=True)
    except FileNotFoundError:
        return None


def main() -> int:
    args = parse_args()
    device = pick_device()
    arch = normalize_arch(args.arch)
    run_dir = args.run_dir or (RUNS / f"{arch}-{time.strftime('%Y%m%d-%H%M%S')}")
    run_dir.mkdir(parents=True, exist_ok=True)
    print(f"Run dir: {run_dir} arch={arch} device={device}", flush=True)

    print("Loading train split…", flush=True)
    doc_train = DocCornerTorch("train", image_size=args.image_size, augment=True, limit=args.train_limit)
    parts: list = [doc_train]
    manual_eval = None
    n_manual = 0
    repeats = 0
    if not args.no_manual:
        manual_eval = maybe_load_manual(args.manual_dir, args.image_size, augment=False)
        if manual_eval is not None:
            n_manual = len(manual_eval)
            repeats = args.manual_repeats
            if repeats is None:
                repeats = max(16, int(round(1024 / max(n_manual, 1))))
            manual_train = ManualQuadFolder(
                args.manual_dir, image_size=args.image_size, augment=True, mild=True
            )
            parts.append(RepeatedDataset(manual_train, repeats))
            print(
                f"Mixing {n_manual} Train/ photos x {repeats} = {n_manual * repeats} "
                f"with {len(doc_train)} DocCorner train images",
                flush=True,
            )
        else:
            print(f"No manual JPEG+JSON pairs in {args.manual_dir}; DocCorner only", flush=True)
    train_ds = parts[0] if len(parts) == 1 else ConcatDataset(parts)

    print("Loading val split…", flush=True)
    val_ds = DocCornerTorch("validation", image_size=args.image_size, augment=False, limit=args.val_limit)
    train_loader = DataLoader(
        train_ds,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=args.workers,
        drop_last=True,
    )
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=args.workers)
    manual_loader = None
    if manual_eval is not None:
        manual_loader = DataLoader(
            manual_eval, batch_size=args.batch_size, shuffle=False, num_workers=args.workers
        )

    model = build_model(arch).to(device)
    print(f"Params: {count_params(model):,}", flush=True)
    optim = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(optim, T_max=max(args.epochs, 1))
    start_epoch = 0
    best_score = -1.0
    if args.resume and args.resume.exists():
        ckpt = torch.load(args.resume, map_location="cpu")
        arch = arch_from_checkpoint(ckpt, arch)
        if normalize_arch(args.arch) != arch:
            model = build_model(arch).to(device)
            optim = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
            sched = torch.optim.lr_scheduler.CosineAnnealingLR(optim, T_max=max(args.epochs, 1))
        model.load_state_dict(ckpt["model"])
        if "optim" in ckpt:
            optim.load_state_dict(ckpt["optim"])
        start_epoch = int(ckpt.get("epoch", 0))
        best_score = float(ckpt.get("best_score", ckpt.get("best_iou", -1.0)))
        print(f"Resumed {args.resume} epoch={start_epoch} arch={arch}", flush=True)

    history = []
    for epoch in range(start_epoch, args.epochs):
        model.train()
        t0 = time.time()
        running = []
        for step, batch in enumerate(train_loader, start=1):
            batch = {k: v.to(device) for k, v in batch.items()}
            optim.zero_grad(set_to_none=True)
            outputs = model(batch["image"])
            loss, metrics = batch_loss(outputs, batch)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optim.step()
            running.append(metrics["loss"])
            if step == 1 or step % 50 == 0:
                print(
                    f"epoch {epoch + 1}/{args.epochs} step {step}/{len(train_loader)} "
                    f"loss={metrics['loss']:.4f} bce={metrics['bce']:.3f} dice={metrics['dice']:.3f} "
                    f"pres={metrics['presence']:.3f} quad={metrics['quad']:.3f}",
                    flush=True,
                )
        sched.step()
        train_loss = float(np.mean(running) if running else 0.0)
        val_metrics = evaluate(model, val_loader, device)
        manual_metrics = None
        if manual_loader is not None:
            manual_metrics = evaluate(model, manual_loader, device, max_quad=n_manual)
        score = combined_score(val_metrics, manual_metrics)
        row = {
            "epoch": epoch + 1,
            "arch": arch,
            "train_loss": train_loss,
            "elapsed_s": time.time() - t0,
            "score": score,
            **{f"val_{k}": v for k, v in val_metrics.items()},
        }
        if manual_metrics is not None:
            row.update({f"manual_{k}": v for k, v in manual_metrics.items()})
        history.append(row)
        (run_dir / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
        extra = ""
        if manual_metrics is not None:
            extra = (
                f" manual_mask_iou={manual_metrics['mask_iou']:.3f} "
                f"manual_quad_iou={manual_metrics['quad_iou']:.3f}"
            )
        print(
            f"epoch {epoch + 1} done train_loss={train_loss:.4f} "
            f"val_mask_iou={val_metrics['mask_iou']:.3f} val_quad_iou={val_metrics['quad_iou']:.3f} "
            f"val_presence={val_metrics['presence_acc']:.3f}{extra} score={score:.3f} "
            f"time={row['elapsed_s']:.0f}s",
            flush=True,
        )
        ckpt = {
            "epoch": epoch + 1,
            "arch": arch,
            "model": model.state_dict(),
            "optim": optim.state_dict(),
            "best_score": best_score,
            "val": val_metrics,
            "manual": manual_metrics,
        }
        torch.save(ckpt, run_dir / "last.pt")
        if score > best_score:
            best_score = score
            ckpt["best_score"] = best_score
            torch.save(ckpt, run_dir / "best.pt")
            print(f"  saved best.pt score={best_score:.3f}", flush=True)

    summary = {
        "arch": arch,
        "best_score": best_score,
        "params": count_params(model),
        "epochs": args.epochs,
        "n_manual": n_manual,
        "manual_repeats": repeats,
        "device": str(device),
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
