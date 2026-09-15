#!/usr/bin/env python3
"""Download DocCornerDataset parquet files into segmentation-experiment/data."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
LOCAL_DIR = DATA_DIR / "DocCornerDataset"
META_DIR = DATA_DIR / "metadata"
DATASET_ID = "mapo80/DocCornerDataset"
SPLITS = ("train", "validation", "test")
META_COLUMNS = [
    "filename",
    "is_negative",
    "corner_tl_x",
    "corner_tl_y",
    "corner_tr_x",
    "corner_tr_y",
    "corner_br_x",
    "corner_br_y",
    "corner_bl_x",
    "corner_bl_y",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--splits",
        nargs="+",
        default=list(SPLITS),
        choices=list(SPLITS),
        help="Which splits to write metadata for after download",
    )
    return parser.parse_args()


def write_metadata(splits: list[str]) -> dict[str, int]:
    import pyarrow.parquet as pq

    META_DIR.mkdir(parents=True, exist_ok=True)
    split_dirs = {
        "train": LOCAL_DIR / "train",
        "validation": LOCAL_DIR / "val",
        "test": LOCAL_DIR / "test",
    }
    summary: dict[str, int] = {}
    for split in splits:
        folder = split_dirs[split]
        files = sorted(folder.glob("*.parquet"))
        if not files:
            print(f"No parquet files for {split} in {folder}", file=sys.stderr)
            continue
        out = META_DIR / f"{split}.jsonl"
        count = 0
        with out.open("w", encoding="utf-8") as handle:
            global_index = 0
            for parquet_path in files:
                table = pq.read_table(parquet_path, columns=META_COLUMNS)
                for row in table.to_pylist():
                    row["index"] = global_index
                    handle.write(json.dumps(row) + "\n")
                    global_index += 1
                    count += 1
        summary[split] = count
        print(f"{split}: {count} samples → {out}", flush=True)
    return summary


def main() -> int:
    args = parse_args()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    from huggingface_hub import snapshot_download

    print(f"Downloading {DATASET_ID} (~18 GB) into {LOCAL_DIR}", flush=True)
    snapshot_download(
        repo_id=DATASET_ID,
        repo_type="dataset",
        local_dir=str(LOCAL_DIR),
        allow_patterns=["train/*.parquet", "val/*.parquet", "test/*.parquet", "README.md", "dataset_info.json"],
    )
    summary = write_metadata(args.splits)
    (DATA_DIR / "dataset_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("Done.", summary, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
