#!/usr/bin/env python3
"""Fine-tune a tiny document model from an existing checkpoint on JPEG+JSON manuals.

Resumes weights only (not optimizer). Mixes oversampled user samples with a
modest DocCorner replay subset so the head does not forget.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import ConcatDataset, DataLoader

from doc_dataset import IMAGE_SIZE, DocCornerTorch, ManualQuadFolder, RepeatedDataset
from tiny_model import (
    ARCH_CNN,
    arch_from_checkpoint,
    build_model,
    count_params,
    normalize_arch,
    pick_device,
)
from train import batch_loss, evaluate

ROOT = Path(__file__).resolve().parent
DEFAULT_TRAIN = ROOT / "Train"
DEFAULT_CKPT = ROOT / "runs" / "tiny-document" / "best.pt"
DEFAULT_RUN = ROOT / "runs" / "finetune-manual"
HEAD_PREFIXES = ("mask_head", "presence_head", "quad_head")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--finetune-dir", type=Path, default=DEFAULT_TRAIN)
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CKPT)
    parser.add_argument("--run-dir", type=Path, default=DEFAULT_RUN)
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--image-size", type=int, default=IMAGE_SIZE)
    parser.add_argument("--replay-limit", type=int, default=800)
    parser.add_argument("--val-limit", type=int, default=128)
    parser.add_argument("--manual-repeats", type=int, default=None, help="Default: match replay count")
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--arch", default=None, help="cnn or transformer; default: read from checkpoint")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--freeze-backbone", action="store_true")
    parser.add_argument("--no-export", action="store_true")
    return parser.parse_args()


def load_checkpoint(path: Path, model) -> None:
    if not path.exists():
        raise FileNotFoundError(f"Checkpoint not found: {path}")
    ckpt = torch.load(path, map_location="cpu")
    state = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
    model.load_state_dict(state)
    print(f"Loaded weights from {path}", flush=True)


def freeze_backbone(model) -> int:
    frozen = 0
    for name, param in model.named_parameters():
        if name.startswith(HEAD_PREFIXES):
            param.requires_grad = True
        else:
            param.requires_grad = False
            frozen += param.numel()
    return frozen


def combined_score(manual: dict, val: dict) -> float:
    return 0.55 * float(manual["mask_iou"]) + 0.45 * float(val["mask_iou"])


def main() -> int:
    args = parse_args()
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    run_dir = args.run_dir
    run_dir.mkdir(parents=True, exist_ok=True)
    device = pick_device()
    print(f"Run dir: {run_dir} device={device}", flush=True)

    manual_eval = ManualQuadFolder(args.finetune_dir, image_size=args.image_size, augment=False)
    n_manual = len(manual_eval)
    print(f"Manual samples: {n_manual} in {args.finetune_dir.resolve()}", flush=True)
    print(
        "Coordinate check: JSON quads are DocCorner / tiny-model space "
        "(normalized 0–1, top-left origin). App already flips Vision y in trainingQuadNorm().",
        flush=True,
    )

    freeze = args.freeze_backbone or n_manual < 10
    repeats = args.manual_repeats
    if repeats is None:
        repeats = max(8, int(round(args.replay_limit / max(n_manual, 1))))
    epochs = args.epochs
    if n_manual < 10 and args.epochs == 8:
        epochs = 12
        print(f"N={n_manual} < 10: freezing backbone and using {epochs} epochs", flush=True)

    manual_train = ManualQuadFolder(
        args.finetune_dir, image_size=args.image_size, augment=True, mild=True
    )
    oversampled = RepeatedDataset(manual_train, repeats)
    print("Loading DocCorner replay subset…", flush=True)
    replay = DocCornerTorch(
        "train",
        image_size=args.image_size,
        augment=True,
        limit=args.replay_limit,
        shuffle_seed=args.seed,
    )
    print("Loading DocCorner val slice…", flush=True)
    val_ds = DocCornerTorch("validation", image_size=args.image_size, augment=False, limit=args.val_limit)
    train_ds = ConcatDataset([oversampled, replay])
    train_loader = DataLoader(
        train_ds,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=args.workers,
        drop_last=True,
    )
    manual_loader = DataLoader(manual_eval, batch_size=args.batch_size, shuffle=False, num_workers=args.workers)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=args.workers)
    print(
        f"Mix per epoch: {len(oversampled)} manual presentations "
        f"({n_manual} x {repeats}) + {len(replay)} DocCorner replay = {len(train_ds)}",
        flush=True,
    )

    probe = torch.load(args.checkpoint, map_location="cpu")
    arch = normalize_arch(args.arch) if args.arch else arch_from_checkpoint(probe if isinstance(probe, dict) else None, ARCH_CNN)
    model = build_model(arch).to(device)
    load_checkpoint(args.checkpoint, model)
    frozen = freeze_backbone(model) if freeze else 0
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(
        f"Params: {count_params(model):,} arch={arch} trainable={trainable:,} frozen={frozen:,} freeze_backbone={freeze}",
        flush=True,
    )

    print("Evaluating before fine-tune…", flush=True)
    before_manual = evaluate(model, manual_loader, device, max_quad=n_manual)
    before_val = evaluate(model, val_loader, device, max_quad=min(args.val_limit, 128))
    before = {
        "manual": before_manual,
        "doccorner_val": before_val,
        "combined": combined_score(before_manual, before_val),
    }
    print(
        f"before manual mask_iou={before_manual['mask_iou']:.3f} quad_iou={before_manual['quad_iou']:.3f} "
        f"doccorner_val mask_iou={before_val['mask_iou']:.3f} quad_iou={before_val['quad_iou']:.3f}",
        flush=True,
    )

    optim = torch.optim.AdamW(filter(lambda p: p.requires_grad, model.parameters()), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(
        optim, T_max=max(epochs, 1), eta_min=max(args.lr * 0.05, 1e-6)
    )
    best_score = -1.0
    history = []

    for epoch in range(epochs):
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
            if step == 1 or step % 20 == 0:
                print(
                    f"epoch {epoch + 1}/{epochs} step {step}/{len(train_loader)} "
                    f"loss={metrics['loss']:.4f} bce={metrics['bce']:.3f} dice={metrics['dice']:.3f} "
                    f"pres={metrics['presence']:.3f} quad={metrics['quad']:.3f}",
                    flush=True,
                )
        sched.step()
        train_loss = float(np.mean(running) if running else 0.0)
        manual_metrics = evaluate(model, manual_loader, device, max_quad=n_manual)
        val_metrics = evaluate(model, val_loader, device, max_quad=min(args.val_limit, 128))
        score = combined_score(manual_metrics, val_metrics)
        row = {
            "epoch": epoch + 1,
            "train_loss": train_loss,
            "lr": float(optim.param_groups[0]["lr"]),
            "elapsed_s": time.time() - t0,
            "combined": score,
            **{f"manual_{k}": v for k, v in manual_metrics.items()},
            **{f"val_{k}": v for k, v in val_metrics.items()},
        }
        history.append(row)
        (run_dir / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
        print(
            f"epoch {epoch + 1} done train_loss={train_loss:.4f} "
            f"manual_mask_iou={manual_metrics['mask_iou']:.3f} manual_quad_iou={manual_metrics['quad_iou']:.3f} "
            f"val_mask_iou={val_metrics['mask_iou']:.3f} val_quad_iou={val_metrics['quad_iou']:.3f} "
            f"combined={score:.3f} time={row['elapsed_s']:.0f}s",
            flush=True,
        )
        ckpt = {
            "epoch": epoch + 1,
            "arch": arch,
            "model": model.state_dict(),
            "best_score": best_score,
            "manual": manual_metrics,
            "val": val_metrics,
            "source_checkpoint": str(args.checkpoint),
        }
        torch.save(ckpt, run_dir / "last.pt")
        if score > best_score:
            best_score = score
            ckpt["best_score"] = best_score
            torch.save(ckpt, run_dir / "best.pt")
            print(f"  saved best.pt combined={best_score:.3f}", flush=True)

    load_checkpoint(run_dir / "best.pt", model)
    after_manual = evaluate(model, manual_loader, device, max_quad=n_manual)
    after_val = evaluate(model, val_loader, device, max_quad=min(args.val_limit, 128))
    summary = {
        "n_manual": n_manual,
        "arch": arch,
        "finetune_dir": str(args.finetune_dir.resolve()),
        "source_checkpoint": str(args.checkpoint),
        "epochs": epochs,
        "lr": args.lr,
        "batch_size": args.batch_size,
        "replay_limit": args.replay_limit,
        "manual_repeats": repeats,
        "freeze_backbone": freeze,
        "params": count_params(model),
        "best_combined": best_score,
        "before": before,
        "after": {
            "manual": after_manual,
            "doccorner_val": after_val,
            "combined": combined_score(after_manual, after_val),
        },
        "coordinate_space": "top-left origin, normalized 0-1 (DocCorner / not Vision-flipped)",
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)

    if not args.no_export:
        import subprocess
        import sys

        from export_coreml import APP_MODELS

        print("Exporting Core ML…", flush=True)
        out = APP_MODELS[arch]
        subprocess.check_call(
            [
                sys.executable,
                str(ROOT / "export_coreml.py"),
                "--checkpoint",
                str(run_dir / "best.pt"),
                "--out",
                str(out),
            ]
        )
        summary["coreml"] = str(out)
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
