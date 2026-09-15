#!/usr/bin/env python3
"""Download SAM 3 locally. Falls back to SAM 2.1 tiny if the repo is gated."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MODELS_DIR = ROOT / "models"
# Image teacher: facebook/sam3. The official `sam3` package loads `sam3.pt`
# (keys like detector.*). Transformers `model.safetensors` uses a different
# layout and will not load into that package. facebook/sam3.1 is a later
# video-tracking checkpoint — skip it for still document photos.
SAM3_ID = "facebook/sam3"
SAM3_CKPT = "sam3.pt"
SAM2_ID = "facebook/sam2.1-hiera-tiny"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token", default=None, help="Hugging Face token with SAM 3 access")
    parser.add_argument("--skip-fallback", action="store_true")
    return parser.parse_args()


def snapshot(repo_id: str, dest: Path, token: str | None, ignore_patterns: list[str] | None = None) -> Path:
    from huggingface_hub import snapshot_download

    dest.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {repo_id} → {dest}", flush=True)
    snapshot_download(
        repo_id=repo_id,
        local_dir=str(dest),
        token=token,
        ignore_patterns=ignore_patterns,
    )
    return dest


def write_status(payload: dict) -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    path = MODELS_DIR / "download_status.json"
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps(payload, indent=2), flush=True)


def main() -> int:
    args = parse_args()
    token = args.token
    if not token:
        import os

        token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    sam3_dir = MODELS_DIR / "sam3"
    status: dict = {"sam3": None, "sam2": None}

    try:
        snapshot(
            SAM3_ID,
            sam3_dir,
            token,
            # Official `sam3` loads sam3.pt; keep it. Skip extra .pt dumps if any.
            ignore_patterns=None,
        )
        from huggingface_hub import hf_hub_download

        ckpt_path = hf_hub_download(
            repo_id=SAM3_ID,
            filename=SAM3_CKPT,
            local_dir=str(sam3_dir),
            token=token,
        )
        status["sam3"] = {
            "ok": True,
            "path": str(sam3_dir),
            "repo": SAM3_ID,
            "checkpoint": ckpt_path,
        }
    except Exception as exc:
        message = str(exc)
        status["sam3"] = {"ok": False, "error": message, "repo": SAM3_ID}
        print(
            "SAM 3 download failed. The checkpoint is gated: request access at "
            "https://huggingface.co/facebook/sam3 then re-run with HF_TOKEN or --token.",
            file=sys.stderr,
            flush=True,
        )
        print(message, file=sys.stderr, flush=True)
        if args.skip_fallback:
            write_status(status)
            return 1

        try:
            sam2_dir = MODELS_DIR / "sam2.1-hiera-tiny"
            snapshot(SAM2_ID, sam2_dir, token=None, ignore_patterns=["*.pt"])
            status["sam2"] = {"ok": True, "path": str(sam2_dir), "repo": SAM2_ID}
        except Exception as fallback_exc:
            status["sam2"] = {"ok": False, "error": str(fallback_exc), "repo": SAM2_ID}
            write_status(status)
            return 1

    write_status(status)
    return 0 if (status.get("sam3") or {}).get("ok") or (status.get("sam2") or {}).get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
