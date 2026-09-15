# Segmentation experiment

Teacher-model labeling for a **small on-device document segmenter**.

Pipeline:

1. Download [DocCornerDataset](https://huggingface.co/datasets/mapo80/DocCornerDataset) (~48k images, ~18 GB).
2. Download the teacher **`facebook/sam3`** (0.9B mask-generation model). Do not download the SACo-Gold/Silver/VEval or SA-FARI rows — those are datasets. **SAM 3.1** is a later video-tracking checkpoint; image text prompts for documents use `facebook/sam3`. Website access is not enough: this machine must be logged in (`hf auth login` or `HF_TOKEN`).
3. Convert each teacher mask to a **convex quadrilateral** (TL → TR → BR → BL, normalized 0–1) and write a review folder.

Those masks + quads are the labels for a later tiny iPhone/Core ML model.

## Layout

```
segmentation-experiment/
  Train/                   user JPEG+JSON pairs mixed into training
  data/DocCornerDataset/   parquet files (gitignored)
  models/sam2.1-hiera-tiny teacher weights
  review/                  overlays, masks, per-image JSON, index.html
  annotate.py
  finetune.py
  tiny_model.py            TinyDocumentNet (CNN) and TinyDocumentTransformer
```

## Setup

```bash
cd segmentation-experiment
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Commands

```bash
python download_dataset.py
hf auth login   # token with access to facebook/sam3
python download_sam3.py --skip-fallback
python annotate.py --split train --offset 0 --limit 200 --review-dir review_sam3 --require-sam3
open review_sam3/index.html
python train.py --epochs 6 --batch-size 16 --val-limit 400 --run-dir runs/tiny-document
python export_coreml.py --checkpoint runs/tiny-document/best.pt
python finetune.py --finetune-dir Train --checkpoint runs/tiny-document/best.pt
python train.py --arch transformer --epochs 6 --batch-size 16 --val-limit 400 --run-dir runs/tiny-transformer
python export_coreml.py --checkpoint runs/tiny-transformer/best.pt
```

`--offset 100` matches Hugging Face viewer `train?p=2` (100 rows per page).

Without SAM 3 access, `download_sam3.py` stores **SAM 2.1 Hiera Tiny**. `annotate.py` uses a coarse document box + center point, then fits a convex quad to the mask.

## Review overlay

- Green polygon: dataset ground-truth corners
- Cyan polygon: teacher convex quad
- Magenta wash: teacher mask

`review/quads/*.json` is the label format to train from after you approve the overlays.

## On-device models

Two students share the same 256×256 mask + presence + quad heads and the same labels (DocCorner ground-truth quads plus `Train/` JPEG+JSON pairs). SAM 3 matched DocCorner corners at 0.958 IoU, so those labels are usable without waiting for 48k teacher masks.

- **`TinyDocumentNet`** (~341k params): conv UNet. Core ML: `Scany/Detection/TinyDocumentSegmenter.mlpackage`.
- **`TinyDocumentTransformer`** (494,522 params): conv patch stem, 6-layer ViT encoder on a 16×16 token grid (SAM-style global self-attention; Core ML-friendly matmul attention, not `nn.MultiheadAttention`), CNN mask decoder. Core ML: `Scany/Detection/TinyDocumentTransformer.mlpackage`.

`train.py` mixes the full DocCorner train split with oversampled `Train/` photos unless `--no-manual` is set.

```bash
python train.py --epochs 6 --batch-size 16 --val-limit 400 --run-dir runs/tiny-document
python export_coreml.py --checkpoint runs/tiny-document/best.pt
python finetune.py --finetune-dir Train --checkpoint runs/tiny-document/best.pt --run-dir runs/finetune-manual
python export_coreml.py --checkpoint runs/finetune-manual/best.pt
python train.py --arch transformer --epochs 6 --batch-size 16 --val-limit 400 --run-dir runs/tiny-transformer
python export_coreml.py --checkpoint runs/tiny-transformer/best.pt
```

Drop more JPEG+JSON pairs into `Train/` (same format the app writes) and re-run `finetune.py` for the CNN, or re-run transformer training so the new photos are in the mix. Fine-tuning resumes from `best.pt`, oversamples the new photos, and mixes in a DocCorner replay subset so the head does not forget.

The iPhone detector can use Vision, the CNN, or the transformer.

## Current run (this machine)

- Teacher: official `facebook/sam3` (`sam3.pt`) on CPU. Review: `review_sam3/` (24 images, mean IoU **0.958**).
- CNN student: `TinyDocumentNet` (~341k params, 256×256) finished **6/6 epochs** on 32,968 train images.
- Best val: mask IoU **0.817**, quad IoU **0.965**, presence acc **1.00**.
- Fine-tune: **29** manual samples in `Train/` (top-left origin, not Vision-flipped). Resumed from `runs/tiny-document/best.pt`, 8 epochs, lr 1e-4, unfrozen, 800 DocCorner replay.
- Manual train-set fit: mask IoU **0.740 → 0.959**, quad IoU **0.729 → 0.943**, presence **0.83 → 1.00**.
- DocCorner val slice (128): mask IoU **0.855 → 0.852**, quad IoU **0.964 → 0.957** (no material forgetting).
- Core ML package: `Scany/Detection/TinyDocumentSegmenter.mlpackage` from `runs/finetune-manual/best.pt`.
- Transformer student: `TinyDocumentTransformer`, trained jointly on the full DocCorner train split plus the 29 `Train/` photos. Run dir: `runs/tiny-transformer`.

The first SAM 2.1 review remains at `review/index.html` (train 100–147).
