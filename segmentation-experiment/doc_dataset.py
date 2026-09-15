"""DocCornerDataset as a torch Dataset of 256² images, masks, and quads."""

from __future__ import annotations

import io
import json
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image, ImageOps
from torch.utils.data import Dataset

from quad_geometry import dict_to_quad, gt_corners_from_sample, order_tl_tr_br_bl

ROOT = Path(__file__).resolve().parent
LOCAL_DATASET = ROOT / "data" / "DocCornerDataset"
SPLIT_DIRS = {
    "train": LOCAL_DATASET / "train",
    "validation": LOCAL_DATASET / "val",
    "test": LOCAL_DATASET / "test",
}
IMAGE_SIZE = 256


def decode_image(payload) -> Image.Image:
    if isinstance(payload, Image.Image):
        return payload.convert("RGB")
    if isinstance(payload, dict):
        raw = payload.get("bytes")
        if raw:
            return Image.open(io.BytesIO(raw)).convert("RGB")
        path = payload.get("path")
        if path:
            return Image.open(path).convert("RGB")
    raise TypeError(f"Unsupported image payload: {type(payload)}")


def rasterize_quad(quad_norm: np.ndarray | None, size: int) -> np.ndarray:
    mask = np.zeros((size, size), dtype=np.uint8)
    if quad_norm is None:
        return mask
    pts = order_tl_tr_br_bl(quad_norm) * np.float32(size)
    cv2.fillConvexPoly(mask, np.round(pts).astype(np.int32), 1)
    return mask


def rotate_90(image: Image.Image, quad: np.ndarray | None, k: int) -> tuple[Image.Image, np.ndarray | None]:
    k = k % 4
    if k == 0:
        return image, quad
    rotated = image.transpose(
        [Image.ROTATE_90, Image.ROTATE_180, Image.ROTATE_270][k - 1]
    )
    if quad is None:
        return rotated, None
    pts = quad.copy()
    for _ in range(k):
        x, y = pts[:, 0].copy(), pts[:, 1].copy()
        pts[:, 0] = y
        pts[:, 1] = 1.0 - x
    return rotated, order_tl_tr_br_bl(pts)


class DocCornerTorch(Dataset):
    def __init__(
        self,
        split: str,
        image_size: int = IMAGE_SIZE,
        augment: bool = False,
        limit: int | None = None,
        offset: int = 0,
        shuffle_seed: int | None = None,
    ) -> None:
        from datasets import load_dataset

        folder = SPLIT_DIRS[split]
        files = sorted(str(p) for p in folder.glob("*.parquet"))
        if not files:
            raise FileNotFoundError(f"No parquet files in {folder}")
        if shuffle_seed is None or limit is None:
            spec = split if limit is None else f"{split}[{offset}:{offset + limit}]"
            self.ds = load_dataset("parquet", data_files={split: files}, split=spec)
        else:
            # Seeded contiguous window: random row order across parquet files is
            # far slower on CPU than a sequential slice of the same size.
            probe = load_dataset("parquet", data_files={split: files}, split=split)
            n = len(probe)
            rng = np.random.default_rng(shuffle_seed)
            max_off = max(n - limit, 0)
            start = int(rng.integers(0, max_off + 1)) if max_off else 0
            spec = f"{split}[{start}:{start + limit}]"
            self.ds = load_dataset("parquet", data_files={split: files}, split=spec)
        self.image_size = image_size
        self.augment = augment

    def __len__(self) -> int:
        return len(self.ds)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        sample = self.ds[int(index)]
        image = decode_image(sample["image"])
        quad = gt_corners_from_sample(sample)
        if self.augment:
            if np.random.rand() < 0.5:
                image = image.transpose(Image.FLIP_LEFT_RIGHT)
                if quad is not None:
                    quad = quad.copy()
                    quad[:, 0] = 1.0 - quad[:, 0]
                    quad = order_tl_tr_br_bl(quad)
            k = int(np.random.randint(0, 4))
            image, quad = rotate_90(image, quad, k)
            if np.random.rand() < 0.8:
                image = _color_jitter(image)

        image = image.resize((self.image_size, self.image_size), Image.BILINEAR)
        rgb = np.asarray(image, dtype=np.float32) / 255.0
        mask = rasterize_quad(quad, self.image_size)
        presence = 0.0 if quad is None else 1.0
        quad_vec = np.zeros(8, dtype=np.float32)
        if quad is not None:
            quad_vec = order_tl_tr_br_bl(quad).reshape(-1).astype(np.float32)

        return {
            "image": torch.from_numpy(rgb.transpose(2, 0, 1).copy()),
            "mask": torch.from_numpy(mask.astype(np.float32)).unsqueeze(0),
            "presence": torch.tensor([presence], dtype=torch.float32),
            "quad": torch.from_numpy(quad_vec),
            "is_positive": torch.tensor(presence, dtype=torch.float32),
        }


def _color_jitter(image: Image.Image) -> Image.Image:
    arr = np.asarray(image).astype(np.float32)
    brightness = np.random.uniform(0.75, 1.25)
    contrast = np.random.uniform(0.75, 1.25)
    arr = arr * brightness
    mean = arr.mean(axis=(0, 1), keepdims=True)
    arr = (arr - mean) * contrast + mean
    arr = np.clip(arr, 0, 255).astype(np.uint8)
    return Image.fromarray(arr, mode="RGB")


def pair_image(json_path: Path) -> Path | None:
    for ext in (".jpg", ".jpeg", ".JPG", ".JPEG"):
        candidate = json_path.with_suffix(ext)
        if candidate.exists():
            return candidate
    return None


def mild_augment(image: Image.Image, quad: np.ndarray, mild: bool) -> tuple[Image.Image, np.ndarray]:
    if np.random.rand() < 0.5:
        image = image.transpose(Image.FLIP_LEFT_RIGHT)
        quad = quad.copy()
        quad[:, 0] = 1.0 - quad[:, 0]
        quad = order_tl_tr_br_bl(quad)
    rotate_p = 0.15 if mild else 0.75
    if np.random.rand() < rotate_p:
        k = int(np.random.randint(1, 4))
        image, quad = rotate_90(image, quad, k)
    jitter_p = 0.5 if mild else 0.8
    if np.random.rand() < jitter_p:
        image = _color_jitter(image)
    return image, quad


class ManualQuadFolder(Dataset):
    """JPEG + JSON pairs with DocCorner-style normalized TL-TR-BR-BL quads."""

    def __init__(
        self,
        folder: Path,
        image_size: int = IMAGE_SIZE,
        augment: bool = False,
        mild: bool = True,
    ) -> None:
        self.folder = Path(folder)
        self.image_size = image_size
        self.augment = augment
        self.mild = mild
        self.items: list[tuple[Image.Image, np.ndarray]] = []
        for json_path in sorted(self.folder.glob("*.json")):
            image_path = pair_image(json_path)
            if image_path is None:
                continue
            meta = json.loads(json_path.read_text(encoding="utf-8"))
            quad = dict_to_quad(meta.get("quad_norm") or {})
            if quad is None:
                print(f"skip {json_path.name}: missing quad_norm", flush=True)
                continue
            image = ImageOps.exif_transpose(Image.open(image_path)).convert("RGB")
            image = image.resize((image_size, image_size), Image.BILINEAR)
            self.items.append((image, order_tl_tr_br_bl(quad)))
        if not self.items:
            raise FileNotFoundError(f"No JPEG+JSON pairs in {self.folder}")

    def __len__(self) -> int:
        return len(self.items)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        image, quad = self.items[int(index)]
        image = image.copy()
        quad = quad.copy()
        if self.augment:
            image, quad = mild_augment(image, quad, self.mild)
        rgb = np.asarray(image, dtype=np.float32) / 255.0
        mask = rasterize_quad(quad, self.image_size)
        quad_vec = order_tl_tr_br_bl(quad).reshape(-1).astype(np.float32)
        return {
            "image": torch.from_numpy(rgb.transpose(2, 0, 1).copy()),
            "mask": torch.from_numpy(mask.astype(np.float32)).unsqueeze(0),
            "presence": torch.tensor([1.0], dtype=torch.float32),
            "quad": torch.from_numpy(quad_vec),
            "is_positive": torch.tensor(1.0, dtype=torch.float32),
        }


class RepeatedDataset(Dataset):
    def __init__(self, base: Dataset, repeats: int) -> None:
        self.base = base
        self.repeats = max(int(repeats), 1)

    def __len__(self) -> int:
        return len(self.base) * self.repeats

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        return self.base[int(index) % len(self.base)]
